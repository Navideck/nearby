import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:nearby/nearby.dart';

/// In-memory mock transport connecting two endpoints.
class MockLoopbackTransport implements NearbyTransport {
  @override
  final String peerId;
  final StreamController<PacketFrame> _incoming =
      StreamController<PacketFrame>.broadcast();
  MockLoopbackTransport? paired;
  bool _closed = false;

  MockLoopbackTransport({required this.peerId});

  @override
  Stream<PacketFrame> get incomingFrames => _incoming.stream;

  @override
  bool get isConnected => !_closed;

  @override
  Future<void> sendFrame(PacketFrame frame) async {
    if (_closed) throw StateError('Closed transport');
    paired?._incoming.add(frame);
  }

  @override
  Future<void> sendRaw(Uint8List data) async {
    if (_closed) throw StateError('Closed transport');
    final frame = PacketFrame.fromBytes(data);
    if (frame != null) {
      paired?._incoming.add(frame);
    }
  }

  @override
  Future<void> close() async {
    _closed = true;
    await _incoming.close();
  }
}

void main() {
  group('PayloadManager', () {
    late PayloadManager senderPayloadManager;
    late PayloadManager receiverPayloadManager;
    late MockLoopbackTransport senderTransport;
    late MockLoopbackTransport receiverTransport;
    late Directory tempDir;

    setUp(() {
      senderPayloadManager = PayloadManager();
      receiverPayloadManager = PayloadManager();

      senderTransport = MockLoopbackTransport(peerId: 'receiver_peer');
      receiverTransport = MockLoopbackTransport(peerId: 'sender_peer');

      senderTransport.paired = receiverTransport;
      receiverTransport.paired = senderTransport;

      tempDir = Directory.systemTemp.createTempSync('nearby_test_');

      // Pipe receiverTransport frames into receiverPayloadManager
      receiverTransport.incomingFrames.listen((frame) {
        receiverPayloadManager.handleIncomingFrame(
          peerId: receiverTransport.peerId,
          frame: frame,
          storageDirectory: tempDir,
          transport: receiverTransport,
        );
      });

      // Pipe senderTransport frames into senderPayloadManager (e.g. ACKs)
      senderTransport.incomingFrames.listen((frame) {
        senderPayloadManager.handleIncomingFrame(
          peerId: senderTransport.peerId,
          frame: frame,
          storageDirectory: tempDir,
          transport: senderTransport,
        );
      });
    });

    tearDown(() async {
      await senderPayloadManager.dispose();
      await receiverPayloadManager.dispose();
      await senderTransport.close();
      await receiverTransport.close();
      if (tempDir.existsSync()) {
        try {
          tempDir.deleteSync(recursive: true);
        } catch (_) {}
      }
    });

    test('Transfers byte array payload with progress updates and reassembly', () async {
      final payloadData = Uint8List.fromList(List.generate(1000, (i) => i % 256));
      final progressList = <PayloadTransferUpdate>[];

      senderPayloadManager.onProgressUpdate.listen(progressList.add);

      final receivedCompleter = Completer<NearbyPayload>();
      receiverPayloadManager.onPayloadReceived.listen((payload) {
        if (!receivedCompleter.isCompleted) {
          receivedCompleter.complete(payload);
        }
      });

      await senderPayloadManager.sendBytes(
        transport: senderTransport,
        payloadId: 1001,
        bytes: payloadData,
        chunkSize: 200, // Force 5 chunks
      );

      final received = await receivedCompleter.future.timeout(const Duration(seconds: 5));

      expect(received.type, equals(PayloadType.bytes));
      expect(received.bytes, isNotNull);
      expect(received.bytes!.length, equals(1000));
      expect(received.bytes, equals(payloadData));

      expect(progressList.isNotEmpty, isTrue);
      expect(progressList.last.status, equals(PayloadStatus.success));
      expect(progressList.last.bytesTransferred, equals(1000));
    });

    test('Transfers disk file with progress updates and verified file content', () async {
      final testFile = File('${tempDir.path}/sample_source.txt');
      final originalText = 'Hello Nearby World!' * 100;
      testFile.writeAsStringSync(originalText);

      final progressList = <PayloadTransferUpdate>[];
      senderPayloadManager.onProgressUpdate.listen(progressList.add);

      final receivedCompleter = Completer<NearbyPayload>();
      receiverPayloadManager.onPayloadReceived.listen((payload) {
        if (!receivedCompleter.isCompleted) {
          receivedCompleter.complete(payload);
        }
      });

      await senderPayloadManager.sendFile(
        transport: senderTransport,
        payloadId: 2002,
        file: testFile,
        customFileName: 'received_doc.txt',
        chunkSize: 128,
      );

      final received = await receivedCompleter.future.timeout(const Duration(seconds: 5));

      expect(received.type, equals(PayloadType.file));
      expect(received.file, isNotNull);
      expect(received.file!.existsSync(), isTrue);
      expect(received.fileName, equals('received_doc.txt'));
      expect(received.file!.readAsStringSync(), equals(originalText));

      expect(progressList.any((p) => p.status == PayloadStatus.success), isTrue);
    });

    test('Transfers continuous byte stream', () async {
      final streamController = StreamController<List<int>>();

      final receivedCompleter = Completer<NearbyPayload>();
      receiverPayloadManager.onPayloadReceived.listen((payload) {
        if (!receivedCompleter.isCompleted) {
          receivedCompleter.complete(payload);
        }
      });

      final sendFuture = senderPayloadManager.sendStream(
        transport: senderTransport,
        payloadId: 3003,
        stream: streamController.stream,
      );

      // Wait for receiver to get stream payload
      final received = await receivedCompleter.future.timeout(const Duration(seconds: 5));
      expect(received.type, equals(PayloadType.stream));
      expect(received.stream, isNotNull);

      final receivedChunks = <List<int>>[];
      final streamSub = received.stream!.listen(receivedChunks.add);

      // Yield data
      streamController.add([1, 2, 3]);
      streamController.add([4, 5, 6]);
      await streamController.close();
      await sendFuture;

      await Future.delayed(const Duration(milliseconds: 50));

      final allBytes = receivedChunks.expand((c) => c).toList();
      expect(allBytes, equals([1, 2, 3, 4, 5, 6]));

      await streamSub.cancel();
    });

    test('Cancels outgoing payload during transfer', () async {
      final largeBytes = Uint8List(50000);
      final progressList = <PayloadTransferUpdate>[];

      senderPayloadManager.onProgressUpdate.listen((update) {
        progressList.add(update);
        if (update.payloadId == 4004 &&
            update.bytesTransferred > 0 &&
            update.status == PayloadStatus.inProgress) {
          senderPayloadManager.cancelPayload(4004);
        }
      });

      await senderPayloadManager.sendBytes(
        transport: senderTransport,
        payloadId: 4004,
        bytes: largeBytes,
        chunkSize: 100,
      );

      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(progressList.any((p) => p.status == PayloadStatus.canceled), isTrue);
    });

    test('Transfers file successfully with interleaved concurrent frames without hanging', () async {
      final senderFile = File('${tempDir.path}/large_sender_test.bin');
      final payloadData = Uint8List.fromList(List.generate(256 * 1024, (i) => (i * 7) % 256));
      senderFile.writeAsBytesSync(payloadData);

      final receivedCompleter = Completer<NearbyPayload>();
      receiverPayloadManager.onPayloadReceived.listen((payload) {
        if (!receivedCompleter.isCompleted) {
          receivedCompleter.complete(payload);
        }
      });

      final sendFuture = senderPayloadManager.sendFile(
        transport: senderTransport,
        payloadId: 5005,
        file: senderFile,
        customFileName: 'large_received_test.bin',
        chunkSize: 16 * 1024,
      );

      // Concurrently send separate frames while file transfer is in progress
      unawaited(Future.microtask(() async {
        for (int i = 0; i < 5; i++) {
          await Future.delayed(const Duration(milliseconds: 15));
          if (senderTransport.isConnected) {
            await senderTransport.sendFrame(PacketFrame.heartbeat());
          }
        }
      }));

      await sendFuture;
      final received = await receivedCompleter.future.timeout(const Duration(seconds: 5));

      expect(received.type, equals(PayloadType.file));
      expect(received.file, isNotNull);
      expect(received.file!.existsSync(), isTrue);
      expect(received.file!.lengthSync(), equals(256 * 1024));
      expect(received.fileName, equals('large_received_test.bin'));
    });

    test('Transfers zero-byte byte payload and finalizes immediately with peerId populated', () async {
      final receivedCompleter = Completer<NearbyPayload>();
      receiverPayloadManager.onPayloadReceived.listen((payload) {
        if (!receivedCompleter.isCompleted) {
          receivedCompleter.complete(payload);
        }
      });

      await senderPayloadManager.sendBytes(
        transport: senderTransport,
        payloadId: 6006,
        bytes: Uint8List(0),
      );

      final received = await receivedCompleter.future.timeout(const Duration(seconds: 5));
      expect(received.type, equals(PayloadType.bytes));
      expect(received.peerId, equals(receiverTransport.peerId));
      expect(received.bytes, isNotNull);
      expect(received.bytes!.isEmpty, isTrue);
    });

    test('Rejects non-positive chunk sizes with ArgumentError', () async {
      expect(
        () => senderPayloadManager.sendBytes(
          transport: senderTransport,
          payloadId: 7001,
          bytes: Uint8List(10),
          chunkSize: 0,
        ),
        throwsArgumentError,
      );

      final testFile = File('${tempDir.path}/test_chunk.bin')..writeAsBytesSync([1, 2, 3]);
      expect(
        () => senderPayloadManager.sendFile(
          transport: senderTransport,
          payloadId: 7002,
          file: testFile,
          chunkSize: -10,
        ),
        throwsArgumentError,
      );
    });

    test('Rejects oversized payload chunks and fails gracefully', () async {
      final progressList = <PayloadTransferUpdate>[];
      receiverPayloadManager.onProgressUpdate.listen(progressList.add);

      // Declare a 10-byte payload
      await receiverPayloadManager.handleIncomingFrame(
        peerId: receiverTransport.peerId,
        frame: PacketFrame.payloadHeader(
          payloadId: 8001,
          payloadType: PayloadType.bytes.name,
          totalBytes: 10,
        ),
      );

      // Send a 20-byte chunk exceeding declared 10 bytes
      await receiverPayloadManager.handleIncomingFrame(
        peerId: receiverTransport.peerId,
        frame: PacketFrame.payloadChunk(
          payloadId: 8001,
          sequence: 0,
          chunkData: Uint8List(20),
        ),
      );

      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(progressList.any((p) => p.status == PayloadStatus.failure), isTrue);
    });

    test('Cancels outgoing payload scoped strictly to target peer', () async {
      final peer2Transport = MockLoopbackTransport(peerId: 'other_peer');
      final updates = <PayloadTransferUpdate>[];
      senderPayloadManager.onProgressUpdate.listen(updates.add);

      senderPayloadManager.cancelPayload(9001, peerId: 'receiver_peer');

      // Transfer to receiver_peer will be cancelled
      await senderPayloadManager.sendBytes(
        transport: senderTransport,
        payloadId: 9001,
        bytes: Uint8List(100),
        chunkSize: 10,
      );

      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(
        updates.any((u) => u.payloadId == 9001 && u.peerId == 'receiver_peer' && u.status == PayloadStatus.canceled),
        isTrue,
      );

      await peer2Transport.close();
    });
  });
}
