import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'discovery/discovery_coordinator.dart';
import 'models/connection_request.dart';
import 'models/nearby_options.dart';
import 'models/payload.dart';
import 'models/peer.dart';
import 'nearby_session.dart';
import 'payload/payload_manager.dart';
import 'protocol/packet_framer.dart';
import 'transport/ble_transport.dart';
import 'transport/tcp_transport.dart';
import 'transport/transport.dart';

/// Event representing a state change for a peer connection.
class PeerConnectionStateUpdate {
  final Peer peer;
  final PeerConnectionState state;
  final String? sasPin;

  const PeerConnectionStateUpdate({
    required this.peer,
    required this.state,
    this.sasPin,
  });

  @override
  String toString() =>
      'PeerConnectionStateUpdate(peer: ${peer.displayName} (${peer.id}), state: ${state.name}, pin: $sasPin)';
}

/// The primary facade API for cross-platform peer-to-peer discovery and data communication.
class NearbyService {
  final String localPeerId;
  final String localDisplayName;
  final Directory? storageDirectory;

  final DiscoveryCoordinator _discoveryCoordinator = DiscoveryCoordinator();
  final PayloadManager _payloadManager = PayloadManager();

  TcpServer? _tcpServer;
  StreamSubscription<Socket>? _serverSubscription;

  final Map<String, NearbySession> _activeSessions = {};

  final StreamController<ConnectionRequest> _connectionRequestController =
      StreamController<ConnectionRequest>.broadcast();
  final StreamController<PeerConnectionStateUpdate> _peerStateController =
      StreamController<PeerConnectionStateUpdate>.broadcast();

  bool _isAdvertising = false;
  bool _isDiscovering = false;
  AdvertisingOptions? _currentAdvertisingOptions;

  NearbyService({
    String? localPeerId,
    String? localDisplayName,
    this.storageDirectory,
  })  : localPeerId = localPeerId ?? _generateRandomId(),
        localDisplayName = localDisplayName ?? Platform.localHostname;

  static String _generateRandomId() {
    final rand = Random.secure();
    final bytes = List<int>.generate(8, (_) => rand.nextInt(256));
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  // --- Status Getters ---

  bool get isAdvertising => _isAdvertising;
  bool get isDiscovering => _isDiscovering;

  /// Current list of discovered peers.
  List<Peer> get discoveredPeers => _discoveryCoordinator.currentPeers;

  /// Current list of connected peers.
  List<Peer> get connectedPeers => _activeSessions.values
      .where((s) => s.state == PeerConnectionState.connected)
      .map((s) => s.peer)
      .toList();

  // --- Streams ---

  /// Stream of currently discovered nearby peers.
  Stream<List<Peer>> get discoveredPeersStream =>
      _discoveryCoordinator.peersStream;

  /// Stream of incoming connection requests from remote peers.
  Stream<ConnectionRequest> get connectionRequestsStream =>
      _connectionRequestController.stream;

  /// Stream of peer connection state updates (connecting, authenticating, connected, disconnected).
  Stream<PeerConnectionStateUpdate> get peerStateStream =>
      _peerStateController.stream;

  /// Stream of received payloads (Bytes, File, or Stream).
  Stream<NearbyPayload> get payloadReceivedStream =>
      _payloadManager.onPayloadReceived;

  /// Stream of payload progress updates for outgoing and incoming transfers.
  Stream<PayloadTransferUpdate> get payloadProgressStream =>
      _payloadManager.onProgressUpdate;

  // --- Advertising & Discovery ---

  /// Starts advertising this device to nearby peers.
  Future<void> startAdvertising({
    required AdvertisingOptions options,
  }) async {
    await stopAdvertising();
    _currentAdvertisingOptions = options;

    // Start TCP server
    _tcpServer = await TcpServer.bind(port: options.port ?? 0);
    _serverSubscription = _tcpServer!.incomingConnections.listen(_handleIncomingSocket);

    // Start discovery broadcast
    await _discoveryCoordinator.startAdvertising(
      peerId: localPeerId,
      displayName: localDisplayName,
      options: options,
      tcpPort: _tcpServer!.port,
    );

    _isAdvertising = true;
  }

  /// Stops advertising this device.
  Future<void> stopAdvertising() async {
    if (_isAdvertising) {
      _isAdvertising = false;
      _currentAdvertisingOptions = null;
      await _discoveryCoordinator.stopAdvertising();
      await _serverSubscription?.cancel();
      _serverSubscription = null;
      await _tcpServer?.close();
      _tcpServer = null;
    }
  }

  /// Starts discovering nearby advertising peers.
  Future<void> startDiscovery({
    required DiscoveryOptions options,
  }) async {
    await stopDiscovery();
    await _discoveryCoordinator.startDiscovery(options: options);
    _isDiscovering = true;
  }

  /// Stops discovering nearby peers.
  Future<void> stopDiscovery() async {
    if (_isDiscovering) {
      _isDiscovering = false;
      await _discoveryCoordinator.stopDiscovery();
    }
  }

  // --- Connection Management ---

  /// Initiates a connection request to a discovered peer.
  Future<bool> requestConnection(
    Peer peer, {
    Map<String, String> metadata = const {},
    Duration timeout = const Duration(seconds: 15),
  }) async {
    NearbyTransport transport;

    // Attempt TCP connection first if peer has IP/Port
    if (peer.ipAddress != null && peer.port != null) {
      try {
        transport = await TcpTransport.connect(
          host: peer.ipAddress!,
          port: peer.port!,
          peerId: peer.id,
          timeout: timeout,
        );
      } catch (_) {
        // Fallback to BLE if available
        if (peer.bleDeviceId != null) {
          transport = await BleTransport.connect(
            deviceId: peer.bleDeviceId!,
            peerId: peer.id,
            timeout: timeout,
          );
        } else {
          rethrow;
        }
      }
    } else if (peer.bleDeviceId != null) {
      // Connect via BLE
      transport = await BleTransport.connect(
        deviceId: peer.bleDeviceId!,
        peerId: peer.id,
        timeout: timeout,
      );
    } else {
      throw ArgumentError('Peer does not have IP/port or BLE device ID');
    }

    final session = NearbySession(
      peer: peer,
      transport: transport,
      localPeerId: localPeerId,
      localDisplayName: localDisplayName,
      payloadManager: _payloadManager,
      storageDirectory: storageDirectory,
    );

    _activeSessions[peer.id] = session;

    session.stateStream.listen((state) {
      _peerStateController.add(
        PeerConnectionStateUpdate(
          peer: peer,
          state: state,
          sasPin: session.sasPin,
        ),
      );
      if (state == PeerConnectionState.disconnected) {
        _activeSessions.remove(peer.id);
      }
    });

    return await session.initiateHandshake(metadata: metadata, timeout: timeout);
  }

  void _handleIncomingSocket(Socket socket) {
    if (_activeSessions.length >= 32) {
      socket.destroy();
      return;
    }

    final transport = TcpTransport.wrap(socket, peerId: 'pending');

    late StreamSubscription sub;
    final handshakeTimer = Timer(const Duration(seconds: 15), () {
      sub.cancel();
      transport.close();
      socket.destroy();
    });

    sub = transport.incomingFrames.listen((frame) async {
      if (frame.type == FrameType.handshakeInit) {
        handshakeTimer.cancel();
        await sub.cancel();

        // Extract remote peer info
        final json = jsonDecode(utf8.decode(frame.body)) as Map<String, dynamic>;
        final String remotePeerId = json['peerId'] as String;
        transport.updatePeerId(remotePeerId);
        final String remoteDisplayName = json['displayName'] as String;
        final Map<String, String> metadata =
            (json['metadata'] as Map<dynamic, dynamic>?)?.map(
                  (k, v) => MapEntry(k.toString(), v.toString()),
                ) ??
                {};

        final peer = Peer(
          id: remotePeerId,
          displayName: remoteDisplayName,
          metadata: metadata,
          discoveredVia: DiscoveryMedium.mdns,
          ipAddress: socket.remoteAddress.address,
          port: socket.remotePort,
          lastSeen: DateTime.now(),
        );

        final session = NearbySession(
          peer: peer,
          transport: transport,
          localPeerId: localPeerId,
          localDisplayName: localDisplayName,
          payloadManager: _payloadManager,
          storageDirectory: storageDirectory,
        );

        _activeSessions[peer.id] = session;

        session.stateStream.listen((state) {
          _peerStateController.add(
            PeerConnectionStateUpdate(
              peer: peer,
              state: state,
              sasPin: session.sasPin,
            ),
          );
          if (state == PeerConnectionState.disconnected) {
            _activeSessions.remove(peer.id);
          }
        });

        // Feed HandshakeInit frame into session
        await session.handleFrame(frame);

        final request = ConnectionRequest(
          peer: peer,
          authenticationPin: session.sasPin ?? '0000',
          metadata: metadata,
          timestamp: DateTime.now(),
        );

        // Auto-accept if configured
        if (_currentAdvertisingOptions?.securityMode == SecurityMode.autoAccept) {
          await session.respondToHandshake(accept: true);
        } else {
          _connectionRequestController.add(request);
        }
      } else {
        // Unexpected frame prior to handshakeInit; terminate connection
        handshakeTimer.cancel();
        await sub.cancel();
        await transport.close();
        socket.destroy();
      }
    }, onError: (_) {
      handshakeTimer.cancel();
      sub.cancel();
      transport.close();
      socket.destroy();
    }, onDone: () {
      handshakeTimer.cancel();
    });
  }

  /// Accepts an incoming connection request from a peer.
  Future<void> acceptConnection(String peerId) async {
    final session = _activeSessions[peerId];
    if (session != null) {
      await session.respondToHandshake(accept: true);
    }
  }

  /// Rejects an incoming connection request from a peer.
  Future<void> rejectConnection(String peerId, {String? reason}) async {
    final session = _activeSessions[peerId];
    if (session != null) {
      await session.respondToHandshake(accept: false, reason: reason);
      _activeSessions.remove(peerId);
    }
  }

  /// Disconnects from a connected peer.
  Future<void> disconnect(String peerId, {String? reason}) async {
    final session = _activeSessions.remove(peerId);
    if (session != null) {
      await session.disconnect(reason: reason);
    }
  }

  /// Disconnects from all connected peers.
  Future<void> disconnectAll({String? reason}) async {
    final sessions = _activeSessions.values.toList();
    _activeSessions.clear();
    for (final session in sessions) {
      await session.disconnect(reason: reason);
    }
  }

  // --- Data Transmission ---

  /// Sends a raw byte array payload to a specific connected peer.
  Future<void> sendBytes(String peerId, Uint8List bytes, {int? payloadId}) async {
    final session = _activeSessions[peerId];
    if (session == null) {
      throw StateError('Peer $peerId is not connected');
    }
    await session.sendBytes(bytes, payloadId: payloadId);
  }

  /// Broadcasts a raw byte array to all currently connected peers.
  Future<void> sendBytesToAll(Uint8List bytes) async {
    for (final session in _activeSessions.values) {
      if (session.state == PeerConnectionState.connected) {
        await session.sendBytes(bytes);
      }
    }
  }

  /// Sends a file to a specific connected peer.
  Future<void> sendFile(
    String peerId,
    File file, {
    int? payloadId,
    String? customFileName,
  }) async {
    final session = _activeSessions[peerId];
    if (session == null) {
      throw StateError('Peer $peerId is not connected');
    }
    await session.sendFile(file, payloadId: payloadId, customFileName: customFileName);
  }

  /// Sends a continuous byte stream to a specific connected peer.
  Future<void> sendStream(
    String peerId,
    Stream<List<int>> stream, {
    int? payloadId,
  }) async {
    final session = _activeSessions[peerId];
    if (session == null) {
      throw StateError('Peer $peerId is not connected');
    }
    await session.sendStream(stream, payloadId: payloadId);
  }

  /// Cancels an in-progress payload transfer.
  void cancelPayload(int payloadId) {
    _payloadManager.cancelPayload(payloadId);
  }

  /// Disposes and shuts down all services, servers, and sessions.
  Future<void> dispose() async {
    await stopAdvertising();
    await stopDiscovery();
    await disconnectAll();
    await _discoveryCoordinator.dispose();
    await _payloadManager.dispose();
    await _connectionRequestController.close();
    await _peerStateController.close();
  }
}
