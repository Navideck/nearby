import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import '../models/payload.dart';
import '../protocol/packet_framer.dart';
import '../transport/transport.dart';

const int kDefaultChunkSize = 64 * 1024; // 64 KB chunk size for TCP

/// Internal state for incoming payload reassembly.
class _IncomingPayloadState {
  final int payloadId;
  final String peerId;
  final PayloadType type;
  final int totalBytes;
  final String? fileName;
  final Completer<NearbyPayload> completer = Completer<NearbyPayload>();

  int bytesReceived = 0;
  BytesBuilder? bytesBuilder;
  IOSink? fileSink;
  File? tempFile;
  StreamController<List<int>>? streamController;

  _IncomingPayloadState({
    required this.payloadId,
    required this.peerId,
    required this.type,
    required this.totalBytes,
    this.fileName,
  }) {
    if (type == PayloadType.bytes) {
      bytesBuilder = BytesBuilder(copy: false);
    } else if (type == PayloadType.stream) {
      streamController = StreamController<List<int>>.broadcast();
    }
  }

  Future<void> cleanup() async {
    final sink = fileSink;
    fileSink = null;
    if (sink != null) {
      try {
        await sink.flush();
        await sink.close();
      } catch (_) {}
    }
    final sc = streamController;
    streamController = null;
    if (sc != null && !sc.isClosed) {
      try {
        await sc.close();
      } catch (_) {}
    }
    if (tempFile != null && tempFile!.existsSync() && !completer.isCompleted) {
      try {
        tempFile!.deleteSync();
      } catch (_) {}
    }
  }
}

/// Manages chunking, streaming, progress tracking, and reassembly for all payload types.
class PayloadManager {
  final Map<String, _IncomingPayloadState> _incomingPayloads = {};
  String _payloadKey(String peerId, int payloadId) => "$peerId:$payloadId";
  final Set<int> _cancelledOutgoingPayloads = {};

  final StreamController<NearbyPayload> _payloadReceivedController =
      StreamController<NearbyPayload>.broadcast();
  final StreamController<PayloadTransferUpdate> _progressController =
      StreamController<PayloadTransferUpdate>.broadcast();

  Stream<NearbyPayload> get onPayloadReceived => _payloadReceivedController.stream;
  Stream<PayloadTransferUpdate> get onProgressUpdate => _progressController.stream;

  _IncomingPayloadState? _findIncomingState(String peerId, int payloadId) {
    var state = _incomingPayloads[_payloadKey(peerId, payloadId)];
    if (state != null) return state;
    for (final s in _incomingPayloads.values) {
      if (s.payloadId == payloadId) return s;
    }
    return null;
  }

  /// Sends a raw byte array payload.
  Future<void> sendBytes({
    required NearbyTransport transport,
    required int payloadId,
    required Uint8List bytes,
    int chunkSize = kDefaultChunkSize,
  }) async {
    final int totalBytes = bytes.length;

    // Send payload header
    await transport.sendFrame(
      PacketFrame.payloadHeader(
        payloadId: payloadId,
        payloadType: PayloadType.bytes.name,
        totalBytes: totalBytes,
      ),
    );

    // Yield to allow receiver framer & radio packet queues to process header
    await Future<void>.delayed(const Duration(milliseconds: 30));

    int offset = 0;
    int sequence = 0;

    while (offset < totalBytes) {
      if (_cancelledOutgoingPayloads.remove(payloadId)) {
        await transport.sendFrame(PacketFrame.payloadCancel(payloadId: payloadId));
        _progressController.add(
          PayloadTransferUpdate(
            payloadId: payloadId,
            peerId: transport.peerId,
            bytesTransferred: offset,
            totalBytes: totalBytes,
            status: PayloadStatus.canceled,
          ),
        );
        return;
      }

      final int end = (offset + chunkSize < totalBytes) ? offset + chunkSize : totalBytes;
      final Uint8List chunk = bytes.sublist(offset, end);

      await transport.sendFrame(
        PacketFrame.payloadChunk(
          payloadId: payloadId,
          sequence: sequence,
          chunkData: chunk,
        ),
      );

      offset += chunk.length;
      sequence++;

      _progressController.add(
        PayloadTransferUpdate(
          payloadId: payloadId,
          peerId: transport.peerId,
          bytesTransferred: offset,
          totalBytes: totalBytes,
          status: offset >= totalBytes ? PayloadStatus.success : PayloadStatus.inProgress,
        ),
      );

      if (offset < totalBytes) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    }
  }

  /// Sends a disk file in chunks with live progress updates.
  Future<void> sendFile({
    required NearbyTransport transport,
    required int payloadId,
    required File file,
    String? customFileName,
    int chunkSize = kDefaultChunkSize,
  }) async {
    if (!file.existsSync()) {
      throw ArgumentError('File does not exist: ${file.path}');
    }

    final int totalBytes = file.lengthSync();
    final String fileName = customFileName ?? file.uri.pathSegments.last;

    // Send payload header
    await transport.sendFrame(
      PacketFrame.payloadHeader(
        payloadId: payloadId,
        payloadType: PayloadType.file.name,
        totalBytes: totalBytes,
        fileName: fileName,
      ),
    );

    // Yield to allow receiver framer & radio queues to process header
    await Future<void>.delayed(const Duration(milliseconds: 30));

    final stream = file.openRead();
    int bytesSent = 0;
    int sequence = 0;
    final BytesBuilder buffer = BytesBuilder(copy: false);

    await for (final block in stream) {
      if (_cancelledOutgoingPayloads.remove(payloadId)) {
        await transport.sendFrame(PacketFrame.payloadCancel(payloadId: payloadId));
        _progressController.add(
          PayloadTransferUpdate(
            payloadId: payloadId,
            peerId: transport.peerId,
            bytesTransferred: bytesSent,
            totalBytes: totalBytes,
            status: PayloadStatus.canceled,
          ),
        );
        return;
      }

      buffer.add(block);
      while (buffer.length >= chunkSize) {
        final Uint8List current = buffer.takeBytes();
        final Uint8List toSend = current.sublist(0, chunkSize);
        final Uint8List remaining = current.sublist(chunkSize);
        buffer.add(remaining);

        await transport.sendFrame(
          PacketFrame.payloadChunk(
            payloadId: payloadId,
            sequence: sequence,
            chunkData: toSend,
          ),
        );

        bytesSent += toSend.length;
        sequence++;

        _progressController.add(
          PayloadTransferUpdate(
            payloadId: payloadId,
            peerId: transport.peerId,
            bytesTransferred: bytesSent,
            totalBytes: totalBytes,
            status: PayloadStatus.inProgress,
          ),
        );

        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    }

    // Flush any remaining partial chunk in buffer
    if (buffer.length > 0) {
      final Uint8List lastChunk = buffer.toBytes();
      buffer.clear();

      await transport.sendFrame(
        PacketFrame.payloadChunk(
          payloadId: payloadId,
          sequence: sequence,
          chunkData: lastChunk,
        ),
      );

      bytesSent += lastChunk.length;
    }

    _progressController.add(
      PayloadTransferUpdate(
        payloadId: payloadId,
        peerId: transport.peerId,
        bytesTransferred: bytesSent,
        totalBytes: totalBytes,
        status: PayloadStatus.success,
      ),
    );
  }

  /// Sends a continuous byte stream.
  Future<void> sendStream({
    required NearbyTransport transport,
    required int payloadId,
    required Stream<List<int>> stream,
  }) async {
    // Send header for stream (-1 totalBytes)
    await transport.sendFrame(
      PacketFrame.payloadHeader(
        payloadId: payloadId,
        payloadType: PayloadType.stream.name,
        totalBytes: -1,
      ),
    );

    // Yield to allow receiver framer & radio queues to process header
    await Future<void>.delayed(const Duration(milliseconds: 30));

    int bytesSent = 0;
    int sequence = 0;

    await for (final block in stream) {
      if (_cancelledOutgoingPayloads.remove(payloadId)) {
        await transport.sendFrame(PacketFrame.payloadCancel(payloadId: payloadId));
        _progressController.add(
          PayloadTransferUpdate(
            payloadId: payloadId,
            peerId: transport.peerId,
            bytesTransferred: bytesSent,
            totalBytes: -1,
            status: PayloadStatus.canceled,
          ),
        );
        return;
      }

      final Uint8List chunk = Uint8List.fromList(block);
      await transport.sendFrame(
        PacketFrame.payloadChunk(
          payloadId: payloadId,
          sequence: sequence,
          chunkData: chunk,
        ),
      );

      bytesSent += chunk.length;
      sequence++;

      _progressController.add(
        PayloadTransferUpdate(
          payloadId: payloadId,
          peerId: transport.peerId,
          bytesTransferred: bytesSent,
          totalBytes: -1,
          status: PayloadStatus.inProgress,
        ),
      );

      await Future<void>.delayed(const Duration(milliseconds: 10));
    }

    // Notify stream completion with empty ACK chunk
    await transport.sendFrame(
      PacketFrame.payloadAck(payloadId: payloadId, sequence: sequence),
    );

    _progressController.add(
      PayloadTransferUpdate(
        payloadId: payloadId,
        peerId: transport.peerId,
        bytesTransferred: bytesSent,
        totalBytes: bytesSent,
        status: PayloadStatus.success,
      ),
    );
  }

  /// Handles incoming packet frames from any connected transport.
  Future<void> handleIncomingFrame({
    required String peerId,
    required PacketFrame frame,
    Directory? storageDirectory,
  }) async {
    switch (frame.type) {
      case FrameType.payloadHeader:
        final json = jsonDecode(utf8.decode(frame.body)) as Map<String, dynamic>;
        final String typeStr = json['type'] as String;
        final int totalBytes = json['totalBytes'] as int;
        final String? fileName = json['fileName'] as String?;

        final type = PayloadType.values.firstWhere(
          (t) => t.name == typeStr,
          orElse: () => PayloadType.bytes,
        );

        final state = _IncomingPayloadState(
          payloadId: frame.payloadId,
          peerId: peerId,
          type: type,
          totalBytes: totalBytes,
          fileName: fileName,
        );

        if (type == PayloadType.file) {
          final dir = storageDirectory ?? Directory.systemTemp;
          final rawName = fileName ?? 'incoming_${frame.payloadId}.bin';
          final safeName = rawName.replaceAll(RegExp(r'[/\\]'), '_').replaceAll('..', '_');
          state.tempFile = File('${dir.path}/$safeName');
          state.fileSink = state.tempFile!.openWrite();
        }

        _incomingPayloads[_payloadKey(peerId, frame.payloadId)] = state;

        // If it is a stream payload, emit it immediately so consumer can start listening
        if (type == PayloadType.stream && state.streamController != null) {
          final payload = NearbyPayload.fromStream(
            id: frame.payloadId,
            stream: state.streamController!.stream,
          );
          _payloadReceivedController.add(payload);
        }

        _progressController.add(
          PayloadTransferUpdate(
            payloadId: frame.payloadId,
            peerId: peerId,
            bytesTransferred: 0,
            totalBytes: totalBytes,
            status: PayloadStatus.inProgress,
          ),
        );
        break;

      case FrameType.payloadChunk:
        final state = _findIncomingState(peerId, frame.payloadId);
        if (state == null) return;

        state.bytesReceived += frame.body.length;

        if (state.type == PayloadType.bytes) {
          state.bytesBuilder?.add(frame.body);
        } else if (state.type == PayloadType.file) {
          state.fileSink?.add(frame.body);
        } else if (state.type == PayloadType.stream) {
          state.streamController?.add(frame.body);
        }

        final isCompleted =
            state.totalBytes > 0 && state.bytesReceived >= state.totalBytes;

        _progressController.add(
          PayloadTransferUpdate(
            payloadId: frame.payloadId,
            peerId: state.peerId,
            bytesTransferred: state.bytesReceived,
            totalBytes: state.totalBytes,
            status: isCompleted ? PayloadStatus.success : PayloadStatus.inProgress,
          ),
        );

        if (isCompleted) {
          await _finishIncomingPayload(state.peerId, frame.payloadId);
        }
        break;

      case FrameType.payloadAck:
        // End of stream signal
        final state = _findIncomingState(peerId, frame.payloadId);
        if (state != null && state.type == PayloadType.stream) {
          await _finishIncomingPayload(state.peerId, frame.payloadId);
        }
        break;

      case FrameType.payloadCancel:
        final state = _incomingPayloads.remove(_payloadKey(peerId, frame.payloadId)) ??
            _findIncomingState(peerId, frame.payloadId);
        if (state != null) {
          _incomingPayloads.remove(_payloadKey(state.peerId, frame.payloadId));
          unawaited(state.cleanup());
          _progressController.add(
            PayloadTransferUpdate(
              payloadId: frame.payloadId,
              peerId: state.peerId,
              bytesTransferred: state.bytesReceived,
              totalBytes: state.totalBytes,
              status: PayloadStatus.canceled,
            ),
          );
        }
        break;

      default:
        break;
    }
  }

  Future<void> _finishIncomingPayload(String peerId, int payloadId) async {
    _IncomingPayloadState? state =
        _incomingPayloads.remove(_payloadKey(peerId, payloadId));
    if (state == null) {
      final matchingKey = _incomingPayloads.keys.firstWhere(
        (k) => k.endsWith(':$payloadId'),
        orElse: () => '',
      );
      if (matchingKey.isNotEmpty) {
        state = _incomingPayloads.remove(matchingKey);
      }
    }
    if (state == null) return;

    if (state.type == PayloadType.bytes) {
      final bytes = state.bytesBuilder?.toBytes() ?? Uint8List(0);
      final payload = NearbyPayload.fromBytes(
        id: payloadId,
        bytes: bytes,
      );
      _payloadReceivedController.add(payload);
    } else if (state.type == PayloadType.file) {
      await state.fileSink?.flush();
      await state.fileSink?.close();
      if (state.tempFile != null) {
        final payload = NearbyPayload.fromFile(
          id: payloadId,
          file: state.tempFile!,
          customFileName: state.fileName,
        );
        _payloadReceivedController.add(payload);
      }
    } else if (state.type == PayloadType.stream) {
      await state.streamController?.close();
    }
  }

  /// Cancels an active incoming or outgoing payload transfer.
  void cancelPayload(int payloadId, {String? peerId}) {
    _cancelledOutgoingPayloads.add(payloadId);
    if (peerId != null) {
      final incoming = _incomingPayloads.remove(_payloadKey(peerId, payloadId));
      if (incoming != null) {
        unawaited(incoming.cleanup());
        _progressController.add(
          PayloadTransferUpdate(
            payloadId: payloadId,
            peerId: incoming.peerId,
            bytesTransferred: incoming.bytesReceived,
            totalBytes: incoming.totalBytes,
            status: PayloadStatus.canceled,
          ),
        );
      }
      return;
    }

    final matchingKeys = _incomingPayloads.keys
        .where((k) => k.endsWith(':$payloadId'))
        .toList();
    for (final key in matchingKeys) {
      final incoming = _incomingPayloads.remove(key);
      if (incoming != null) {
        unawaited(incoming.cleanup());
        _progressController.add(
          PayloadTransferUpdate(
            payloadId: payloadId,
            peerId: incoming.peerId,
            bytesTransferred: incoming.bytesReceived,
            totalBytes: incoming.totalBytes,
            status: PayloadStatus.canceled,
          ),
        );
      }
    }
  }

  /// Cleans up active transfers for a disconnected peer.
  void handlePeerDisconnected(String peerId) {
    final toRemove = <String>[];
    for (final entry in _incomingPayloads.entries) {
      if (entry.value.peerId == peerId) {
        unawaited(entry.value.cleanup());
        toRemove.add(entry.key);
      }
    }
    for (final key in toRemove) {
      _incomingPayloads.remove(key);
    }
  }

  /// Disposes manager.
  Future<void> dispose() async {
    for (final state in _incomingPayloads.values) {
      await state.cleanup();
    }
    _incomingPayloads.clear();
    await _payloadReceivedController.close();
    await _progressController.close();
  }
}
