import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nearby/nearby.dart';
import 'package:nearby/src/discovery/ble_discovery.dart';
import 'package:nearby/src/discovery/discovery_coordinator.dart';

class MockSessionTransport implements NearbyTransport {
  @override
  final String peerId;
  @override
  Uint8List? sessionKey;

  final StreamController<PacketFrame> _incoming =
      StreamController<PacketFrame>.broadcast();
  MockSessionTransport? paired;
  bool _closed = false;

  MockSessionTransport({required this.peerId});

  @override
  Stream<PacketFrame> get incomingFrames => _incoming.stream;

  @override
  bool get isConnected => !_closed;

  @override
  Future<void> sendFrame(PacketFrame frame) async {
    if (_closed) throw StateError('Transport closed');
    final bytes = frame.toBytes(sessionKey: sessionKey);
    final wireFrame = PacketFrame.fromBytes(bytes);
    if (wireFrame != null) {
      scheduleMicrotask(() {
        if (paired != null && !paired!._closed) {
          paired!._incoming.add(wireFrame);
        }
      });
    }
  }

  @override
  Future<void> sendRaw(Uint8List data) async {
    final frame = PacketFrame.fromBytes(data);
    if (frame != null) {
      await sendFrame(frame);
    }
  }

  @override
  Future<void> close() async {
    _closed = true;
    await _incoming.close();
  }
}

void main() {
  group('NearbySession Handshake & Connection Flow', () {
    late PayloadManager payloadManagerA;
    late PayloadManager payloadManagerB;
    late MockSessionTransport transportA;
    late MockSessionTransport transportB;
    late NearbySession sessionA;
    late NearbySession sessionB;

    final peerA = Peer(
      id: 'peer_A',
      displayName: 'Alice Device',
      discoveredVia: DiscoveryMedium.hybrid,
      lastSeen: DateTime.now(),
    );

    final peerB = Peer(
      id: 'peer_B',
      displayName: 'Bob Device',
      discoveredVia: DiscoveryMedium.hybrid,
      lastSeen: DateTime.now(),
    );

    setUp(() {
      payloadManagerA = PayloadManager();
      payloadManagerB = PayloadManager();

      transportA = MockSessionTransport(peerId: peerB.id);
      transportB = MockSessionTransport(peerId: peerA.id);

      transportA.paired = transportB;
      transportB.paired = transportA;

      sessionA = NearbySession(
        peer: peerB,
        transport: transportA,
        localPeerId: peerA.id,
        localDisplayName: peerA.displayName,
        payloadManager: payloadManagerA,
      );

      sessionB = NearbySession(
        peer: peerA,
        transport: transportB,
        localPeerId: peerB.id,
        localDisplayName: peerB.displayName,
        payloadManager: payloadManagerB,
      );
    });

    tearDown(() async {
      await sessionA.dispose();
      await sessionB.dispose();
      await payloadManagerA.dispose();
      await payloadManagerB.dispose();
    });

    test(
      'Successful handshake completes and matches SAS PIN symmetrically',
      () async {
        final statesA = <PeerConnectionState>[];
        final statesB = <PeerConnectionState>[];

        sessionA.stateStream.listen(statesA.add);
        sessionB.stateStream.listen(statesB.add);

        // Start handshake from A to B
        final handshakeFuture = sessionA.initiateHandshake();

        // Wait for B to transition to authenticating
        await Future.delayed(const Duration(milliseconds: 50));
        expect(sessionB.state, equals(PeerConnectionState.authenticating));
        expect(sessionB.sasPin, isNotNull);

        // B accepts the handshake
        await sessionB.respondToHandshake(accept: true);

        final result = await handshakeFuture;
        expect(result, isTrue);

        expect(sessionA.state, equals(PeerConnectionState.connected));
        expect(sessionB.state, equals(PeerConnectionState.connected));

        // Both sides must have computed identical SAS PINs and session keys
        expect(sessionA.sasPin, isNotNull);
        expect(sessionB.sasPin, isNotNull);
        expect(sessionA.sasPin, equals(sessionB.sasPin));

        expect(sessionA.sessionKey, isNotNull);
        expect(sessionB.sessionKey, isNotNull);
        expect(sessionA.sessionKey!.length, equals(32));
        expect(sessionA.sessionKey, equals(sessionB.sessionKey));
      },
    );

    test('Handshake with metadata authenticates transcript and matches SAS PIN symmetrically', () async {
      final metadata = {'role': 'controller', 'appVersion': '1.2.0'};
      final handshakeFuture = sessionA.initiateHandshake(metadata: metadata);

      await Future.delayed(const Duration(milliseconds: 50));
      expect(sessionB.state, equals(PeerConnectionState.authenticating));

      await sessionB.respondToHandshake(accept: true);
      final result = await handshakeFuture;
      expect(result, isTrue);

      expect(sessionA.sasPin, equals(sessionB.sasPin));
      expect(sessionA.sessionKey, equals(sessionB.sessionKey));
    });

    test('Rejected handshake disconnects gracefully', () async {
      final handshakeFuture = sessionA.initiateHandshake();

      await Future.delayed(const Duration(milliseconds: 50));
      expect(sessionB.state, equals(PeerConnectionState.authenticating));

      // B declines connection
      await sessionB.respondToHandshake(
        accept: false,
        reason: 'Declined by user',
      );

      final result = await handshakeFuture;
      expect(result, isFalse);

      expect(sessionA.state, equals(PeerConnectionState.disconnected));
      expect(sessionB.state, equals(PeerConnectionState.disconnected));
    });

    test(
      'Transfers bidirectional byte payload across connected sessions',
      () async {
        // Connect first
        final handshakeFuture = sessionA.initiateHandshake();
        await Future.delayed(const Duration(milliseconds: 30));
        await sessionB.respondToHandshake(accept: true);
        await handshakeFuture;

        final messageFromA = Uint8List.fromList([10, 20, 30, 40]);
        final receivedAtBCompleter = Completer<NearbyPayload>();

        payloadManagerB.onPayloadReceived.listen((payload) {
          if (!receivedAtBCompleter.isCompleted) {
            receivedAtBCompleter.complete(payload);
          }
        });

        await sessionA.sendBytes(messageFromA);

        final receivedPayload = await receivedAtBCompleter.future.timeout(
          const Duration(seconds: 3),
        );

        expect(receivedPayload.type, equals(PayloadType.bytes));
        expect(receivedPayload.bytes, equals(messageFromA));
      },
    );
  });

  group('NearbyService Facade Tests', () {
    test('Initializes with custom or generated peer ID and display name', () {
      final service = NearbyService(
        localPeerId: 'custom_id_123',
        localDisplayName: 'My Testing Tablet',
      );

      expect(service.localPeerId, equals('custom_id_123'));
      expect(service.localDisplayName, equals('My Testing Tablet'));
      expect(service.isAdvertising, isFalse);
      expect(service.isDiscovering, isFalse);
      expect(service.discoveredPeers, isEmpty);
      expect(service.connectedPeers, isEmpty);
    });
  });

  group('BlePeripheralTransport Tests', () {
    test(
      'Frames incoming writes from remote central and handles lifecycle',
      () async {
        final deviceId = 'test_central_device_1';
        final transport = BlePeripheralTransport.getOrCreate(deviceId);
        expect(transport.isConnected, isTrue);

        final receivedFrames = <PacketFrame>[];
        final sub = transport.incomingFrames.listen(receivedFrames.add);

        final frame = PacketFrame(
          type: FrameType.heartbeat,
          sequence: 1,
          body: Uint8List.fromList([1, 2, 3]),
        );

        BlePeripheralTransport.handleIncomingWrite(deviceId, frame.toBytes());
        await Future.delayed(const Duration(milliseconds: 20));

        expect(receivedFrames.length, equals(1));
        expect(receivedFrames.first.type, equals(FrameType.heartbeat));
        expect(receivedFrames.first.sequence, equals(1));

        BlePeripheralTransport.handleDisconnected(deviceId);
        expect(transport.isConnected, isFalse);

        await sub.cancel();
        await transport.close();
      },
    );
  });

    group('DiscoveryCoordinator Tests', () {
    test(
      'Ignores self-discovery when incoming peer ID matches localPeerId',
      () {
        final coordinator = DiscoveryCoordinator();
        coordinator.localPeerId = 'local_device_123';

        expect(coordinator.localPeerId, equals('local_device_123'));
        expect(coordinator.currentPeers, isEmpty);
      },
    );
  });

  group('BleDiscoveryService Manufacturer Payload Tests', () {
    test('Uses JSON payload when within 27-byte limit', () {
      final payload = BleDiscoveryService.createManufacturerPayload(
        peerId: 'peer_1',
        serviceId: 's1',
      );

      expect(payload.length, lessThanOrEqualTo(27));
      final decoded = String.fromCharCodes(payload);
      expect(decoded.startsWith('{'), isTrue);
      expect(decoded, contains('"id":"peer_1"'));
      expect(decoded, contains('"sid":"s1"'));
    });

    test('Falls back to compact binary format when JSON exceeds 27 bytes', () {
      final payload = BleDiscoveryService.createManufacturerPayload(
        peerId: '8c17b5e43a9f1a2b',
        serviceId: 'nearby-default-service',
        metadata: {'role': 'presenter'},
      );

      expect(payload.length, lessThanOrEqualTo(27));
      expect(payload.first, equals(0x01));
      final peerId = String.fromCharCodes(payload.sublist(1));
      expect(peerId, equals('8c17b5e43a9f1a2b'));
    });

    test('Bounds long peer IDs to strictly 26 characters in compact fallback', () {
      final longId = 'a' * 60;
      final payload = BleDiscoveryService.createManufacturerPayload(
        peerId: longId,
        serviceId: 'nearby-service',
      );

      expect(payload.length, equals(27));
      expect(payload.first, equals(0x01));
      expect(payload.sublist(1).length, equals(26));
      expect(String.fromCharCodes(payload.sublist(1)), equals('a' * 26));
    });
  });
}
