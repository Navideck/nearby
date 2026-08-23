import 'dart:async';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:nearby/nearby.dart';

class MockSessionTransport implements NearbyTransport {
  @override
  final String peerId;
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
    // Asynchronously dispatch to paired transport
    scheduleMicrotask(() {
      if (paired != null && !paired!._closed) {
        paired!._incoming.add(frame);
      }
    });
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

    test('Successful handshake completes and matches SAS PIN symmetrically', () async {
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

      // Both sides must have computed identical SAS PINs
      expect(sessionA.sasPin, isNotNull);
      expect(sessionB.sasPin, isNotNull);
      expect(sessionA.sasPin, equals(sessionB.sasPin));
    });

    test('Rejected handshake disconnects gracefully', () async {
      final handshakeFuture = sessionA.initiateHandshake();

      await Future.delayed(const Duration(milliseconds: 50));
      expect(sessionB.state, equals(PeerConnectionState.authenticating));

      // B declines connection
      await sessionB.respondToHandshake(accept: false, reason: 'Declined by user');

      final result = await handshakeFuture;
      expect(result, isFalse);

      expect(sessionA.state, equals(PeerConnectionState.disconnected));
      expect(sessionB.state, equals(PeerConnectionState.disconnected));
    });

    test('Transfers bidirectional byte payload across connected sessions', () async {
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

      final receivedPayload =
          await receivedAtBCompleter.future.timeout(const Duration(seconds: 3));

      expect(receivedPayload.type, equals(PayloadType.bytes));
      expect(receivedPayload.bytes, equals(messageFromA));
    });
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
}
