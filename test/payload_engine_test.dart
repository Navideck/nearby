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
  });
}
