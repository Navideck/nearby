import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'broadcast/broadcast_channel.dart';
import 'broadcast/broadcast_packet.dart';
import 'discovery/ble_discovery.dart';
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
  Directory? storageDirectory;

  final DiscoveryCoordinator _discoveryCoordinator = DiscoveryCoordinator();
  final PayloadManager _payloadManager = PayloadManager();

  TcpServer? _tcpServer;
  StreamSubscription<Socket>? _serverSubscription;
  StreamSubscription<BlePeripheralTransport>? _bleServerSubscription;

  final Map<String, NearbySession> _activeSessions = {};

  final StreamController<ConnectionRequest> _connectionRequestController =
      StreamController<ConnectionRequest>.broadcast();
  final StreamController<PeerConnectionStateUpdate> _peerStateController =
      StreamController<PeerConnectionStateUpdate>.broadcast();

  bool _isAdvertising = false;
  bool _isDiscovering = false;
  int _pendingHandshakeCount = 0;
  AdvertisingOptions? _currentAdvertisingOptions;
  DiscoveryOptions? _currentDiscoveryOptions;
  final List<BroadcastChannel> _broadcastChannels = [];
  BroadcastChannel? _defaultBroadcastChannel;

  NearbyService({
    String? localPeerId,
    String? localDisplayName,
    this.storageDirectory,
  }) : localPeerId = localPeerId ?? _generateRandomId(),
       localDisplayName = localDisplayName ?? Platform.localHostname {
    _discoveryCoordinator.localPeerId = this.localPeerId;
  }

  static String _generateRandomId() {
    final rand = Random.secure();
    final bytes = List<int>.generate(8, (_) => rand.nextInt(256));
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  // --- Broadcast Channels (Connectionless 1:Many) ---

  /// List of currently active broadcast channels created via [createBroadcastChannel].
  List<BroadcastChannel> get activeBroadcastChannels =>
      List.unmodifiable(_broadcastChannels);

  /// Default broadcast channel for convenience broadcast operations.
  BroadcastChannel get defaultBroadcastChannel =>
      _defaultBroadcastChannel ??= createBroadcastChannel(
        const BroadcastChannelConfig(
          channelId: 'nearby-default',
          strategy: DiscoveryStrategy.hybrid,
        ),
      );

  /// Creates and registers a dedicated [BroadcastChannel] managed by this service.
  BroadcastChannel createBroadcastChannel(BroadcastChannelConfig config) {
    final channel = BroadcastChannel(
      config: config,
      senderId: localPeerId,
      displayName: localDisplayName,
    );
    _broadcastChannels.add(channel);
    return channel;
  }

  /// Broadcasts a raw datagram to all listeners on the default or specified channel.
  Future<void> broadcast(
    Uint8List data, {
    String? channelId,
    String? localName,
  }) async {
    final channel = channelId != null
        ? _broadcastChannels.firstWhere(
            (c) => c.config.channelId == channelId,
            orElse: () => createBroadcastChannel(
              BroadcastChannelConfig(channelId: channelId),
            ),
          )
        : defaultBroadcastChannel;
    await channel.send(data, localName: localName);
  }

  /// Stream of broadcast packets received on the default broadcast channel.
  Stream<BroadcastPacket> get onBroadcastReceived =>
      defaultBroadcastChannel.stream;

  // --- Status Getters ---

  bool get isAdvertising => _isAdvertising;
  bool get isDiscovering => _isDiscovering;

  /// TCP port currently accepting connected sessions, if network advertising is active.
  int? get advertisingPort => _tcpServer?.port;

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
  Future<void> startAdvertising({required AdvertisingOptions options}) async {
    if (options.securityMode == SecurityMode.preSharedKey &&
        (options.preSharedKey == null || options.preSharedKey!.isEmpty)) {
      throw ArgumentError(
        'preSharedKey must not be empty when using preSharedKey security',
      );
    }
    await stopAdvertising();
    _currentAdvertisingOptions = options;

    try {
      // Start TCP server only for strategies requiring LAN socket communication
      if (options.strategy == DiscoveryStrategy.hybrid ||
          options.strategy == DiscoveryStrategy.networkOnly) {
        try {
          _tcpServer = await TcpServer.bind(port: options.port ?? 0);
        } on SocketException {
          if (!options.fallbackToDynamicPort ||
              options.port == null ||
              options.port == 0) {
            rethrow;
          }
          _tcpServer = await TcpServer.bind();
        }
        _serverSubscription = _tcpServer!.incomingConnections.listen(
          _handleIncomingSocket,
        );
      }

      // Listen for incoming BLE peripheral connections
      if (options.strategy == DiscoveryStrategy.hybrid ||
          options.strategy == DiscoveryStrategy.bleOnly) {
        _bleServerSubscription = _discoveryCoordinator.incomingBleTransports
            .listen(_handleIncomingBleTransport);
      }

      // Start discovery broadcast
      await _discoveryCoordinator.startAdvertising(
        peerId: localPeerId,
        displayName: localDisplayName,
        options: options,
        tcpPort: _tcpServer?.port ?? 0,
      );

      _isAdvertising = true;
    } catch (e) {
      await stopAdvertising();
      rethrow;
    }
  }

  /// Stops advertising this device.
  Future<void> stopAdvertising() async {
    _isAdvertising = false;
    _currentAdvertisingOptions = null;
    await _discoveryCoordinator.stopAdvertising();
    await _serverSubscription?.cancel();
    _serverSubscription = null;
    await _bleServerSubscription?.cancel();
    _bleServerSubscription = null;
    await _tcpServer?.close();
    _tcpServer = null;
  }

  /// Starts discovering nearby advertising peers.
  Future<void> startDiscovery({required DiscoveryOptions options}) async {
    await stopDiscovery();
    _currentDiscoveryOptions = options;
    try {
      await _discoveryCoordinator.startDiscovery(
        options: options,
        localPeerId: localPeerId,
      );
      _isDiscovering = true;
    } catch (e) {
      await stopDiscovery();
      rethrow;
    }
  }

  /// Stops discovering nearby peers.
  Future<void> stopDiscovery() async {
    _isDiscovering = false;
    _currentDiscoveryOptions = null;
    await _discoveryCoordinator.stopDiscovery();
  }

  // --- Connection Management ---

  /// Initiates a connection request to a discovered peer.
  Future<bool> requestConnection(
    Peer peer, {
    Map<String, String> metadata = const {},
    String? preSharedKey,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    if (preSharedKey != null && preSharedKey.isEmpty) {
      throw ArgumentError('preSharedKey must not be empty');
    }
    NearbyTransport transport;

    final String? bleServiceUuid =
        peer.serviceUuid ??
        (_currentDiscoveryOptions?.serviceId != null
            ? BleDiscoveryService.generateServiceUuid(
                _currentDiscoveryOptions!.serviceId,
              )
            : (_currentAdvertisingOptions?.serviceId != null
                  ? BleDiscoveryService.generateServiceUuid(
                      _currentAdvertisingOptions!.serviceId,
                    )
                  : null));

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
            serviceUuid: bleServiceUuid,
            timeout: timeout,
          );
        } else {
          rethrow;
        }
      }
    } else if (peer.bleDeviceId != null) {
      // Connect via BLE (BleTransport internally stops BLE scanning to avoid GATT 133)
      transport = await BleTransport.connect(
        deviceId: peer.bleDeviceId!,
        peerId: peer.id,
        serviceUuid: bleServiceUuid,
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
      preSharedKey: preSharedKey,
    );

    _activeSessions[peer.id] = session;

    session.stateStream.listen((state) {
      if (session.peer.id != peer.id) {
        _activeSessions.remove(peer.id);
        _activeSessions[session.peer.id] = session;
      }

      _peerStateController.add(
        PeerConnectionStateUpdate(
          peer: session.peer,
          state: state,
          sasPin: session.sasPin,
        ),
      );
      if (state == PeerConnectionState.disconnected) {
        _activeSessions.remove(peer.id);
        _activeSessions.remove(session.peer.id);
      }
    });

    return await session.initiateHandshake(
      metadata: metadata,
      timeout: timeout,
    );
  }

  void _handleIncomingSocket(Socket socket) {
    if (_activeSessions.length + _pendingHandshakeCount >= 32) {
      socket.destroy();
      return;
    }

    final transport = TcpTransport.wrap(socket, peerId: 'pending');
    _setupIncomingSession(
      transport: transport,
      medium: DiscoveryMedium.network,
      ipAddress: socket.remoteAddress.address,
      port: socket.remotePort,
      onCleanup: () => socket.destroy(),
    );
  }

  void _handleIncomingBleTransport(BlePeripheralTransport transport) {
    if (_activeSessions.length + _pendingHandshakeCount >= 32) {
      transport.close();
      return;
    }

    _setupIncomingSession(
      transport: transport,
      medium: DiscoveryMedium.ble,
      bleDeviceId: transport.deviceId,
    );
  }

  void _setupIncomingSession({
    required NearbyTransport transport,
    required DiscoveryMedium medium,
    String? ipAddress,
    int? port,
    String? bleDeviceId,
    void Function()? onCleanup,
  }) {
    _pendingHandshakeCount++;
    bool cleanedUp = false;
    void cleanupPending() {
      if (!cleanedUp) {
        cleanedUp = true;
        _pendingHandshakeCount = max(0, _pendingHandshakeCount - 1);
      }
    }

    late StreamSubscription sub;
    final handshakeTimer = Timer(const Duration(seconds: 15), () {
      cleanupPending();
      sub.cancel();
      transport.close();
      onCleanup?.call();
    });

    sub = transport.incomingFrames.listen(
      (frame) async {
        if (frame.type == FrameType.handshakeInit) {
          try {
            // Extract remote peer info
            final json =
                jsonDecode(utf8.decode(frame.body)) as Map<String, dynamic>;
            final String remotePeerId = json['peerId'] as String;
            final String remoteDisplayName = json['displayName'] as String;
            final Map<String, String> metadata =
                (json['metadata'] as Map<dynamic, dynamic>?)?.map(
                  (k, v) => MapEntry(k.toString(), v.toString()),
                ) ??
                {};

            handshakeTimer.cancel();
            cleanupPending();
            await sub.cancel();

            if (transport is TcpTransport) {
              transport.updatePeerId(remotePeerId);
            } else if (transport is BlePeripheralTransport) {
              transport.updatePeerId(remotePeerId);
            }

            // Check for existing active session with identical peer ID
            if (_activeSessions.containsKey(remotePeerId)) {
              final existingSession = _activeSessions[remotePeerId];
              if (existingSession != null &&
                  existingSession.state != PeerConnectionState.disconnected) {
                // Reject duplicate connection request to prevent unmanaged orphaned sessions
                await transport.sendFrame(
                  PacketFrame.handshakeAck(
                    accepted: false,
                    peerId: localPeerId,
                    displayName: localDisplayName,
                    token: '',
                    reason:
                        'Duplicate active session exists for peer $remotePeerId',
                  ),
                );
                await transport.close();
                onCleanup?.call();
                return;
              } else {
                await existingSession?.disconnect();
                _activeSessions.remove(remotePeerId);
              }
            }

            final peer = Peer(
              id: remotePeerId,
              displayName: remoteDisplayName,
              metadata: metadata,
              discoveredVia: medium,
              ipAddress: ipAddress,
              port: port,
              bleDeviceId: bleDeviceId,
              lastSeen: DateTime.now(),
            );

            final session = NearbySession(
              peer: peer,
              transport: transport,
              localPeerId: localPeerId,
              localDisplayName: localDisplayName,
              payloadManager: _payloadManager,
              storageDirectory: storageDirectory,
              preSharedKey:
                  _currentAdvertisingOptions?.securityMode ==
                      SecurityMode.preSharedKey
                  ? _currentAdvertisingOptions?.preSharedKey
                  : null,
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

            if (!session.authenticationMatches) {
              await session.respondToHandshake(
                accept: false,
                reason: 'Connection authentication mode mismatch',
              );
              await transport.close();
              onCleanup?.call();
              return;
            }

            if (session.sasPin == null) {
              // Key exchange failed or invalid token: reject handshake
              await session.respondToHandshake(
                accept: false,
                reason: 'Authentication failed: invalid handshake key exchange',
              );
              await transport.close();
              onCleanup?.call();
              return;
            }

            final request = ConnectionRequest(
              peer: peer,
              authenticationPin: session.sasPin!,
              metadata: metadata,
              timestamp: DateTime.now(),
            );

            // Auto-accept if configured
            if (_currentAdvertisingOptions?.securityMode !=
                SecurityMode.pinVerification) {
              await session.respondToHandshake(accept: true);
            } else {
              _connectionRequestController.add(request);
            }
          } catch (e) {
            handshakeTimer.cancel();
            cleanupPending();
            await sub.cancel();
            await transport.close();
            onCleanup?.call();
          }
        } else {
          // Unexpected frame prior to handshakeInit; terminate connection
          handshakeTimer.cancel();
          cleanupPending();
          await sub.cancel();
          await transport.close();
          onCleanup?.call();
        }
      },
      onError: (_) {
        handshakeTimer.cancel();
        cleanupPending();
        sub.cancel();
        transport.close();
        onCleanup?.call();
      },
      onDone: () {
        handshakeTimer.cancel();
        cleanupPending();
      },
    );
  }

  /// Accepts an incoming connection request from a peer.
  Future<void> acceptConnection(String peerId) async {
    final session = _activeSessions[peerId];
    if (session == null) {
      throw StateError('No pending connection request for peer $peerId');
    }
    await session.respondToHandshake(accept: true);
  }

  /// Rejects an incoming connection request from a peer.
  Future<void> rejectConnection(
    String peerId, {
    String reason = 'Connection rejected by user',
  }) async {
    final session = _activeSessions[peerId];
    if (session == null) {
      throw StateError('No pending connection request for peer $peerId');
    }
    await session.respondToHandshake(accept: false, reason: reason);
  }

  /// Disconnects an active session with a peer.
  Future<void> disconnectPeer(String peerId, {String? reason}) async {
    final session = _activeSessions[peerId];
    if (session != null) {
      await session.disconnect(reason: reason);
      _activeSessions.remove(peerId);
    }
  }

  /// Alias for [disconnectPeer].
  Future<void> disconnect(String peerId, {String? reason}) =>
      disconnectPeer(peerId, reason: reason);

  /// Disconnects all active peer sessions.
  Future<void> disconnectAll({String? reason}) async {
    final sessions = _activeSessions.values.toList();
    _activeSessions.clear();
    for (final session in sessions) {
      await session.disconnect(reason: reason);
    }
  }

  // --- Payload Transmission ---

  /// Sends a raw byte array payload to a specific connected peer.
  Future<void> sendBytes(
    String peerId,
    Uint8List bytes, {
    int? payloadId,
  }) async {
    final session = _activeSessions[peerId];
    if (session == null) {
      throw StateError('Peer $peerId is not connected');
    }
    await session.sendBytes(bytes, payloadId: payloadId);
  }

  /// Broadcasts a raw byte array payload to all currently connected peers.
  Future<void> sendBytesToAll(Uint8List bytes) async {
    final sessions = _activeSessions.values
        .where((session) => session.state == PeerConnectionState.connected)
        .toList();
    await Future.wait(sessions.map((session) => session.sendBytes(bytes)));
  }

  /// Sends a local file payload to a specific connected peer.
  Future<void> sendFile(
    String peerId,
    File file, {
    String? customFileName,
    int? payloadId,
  }) async {
    final session = _activeSessions[peerId];
    if (session == null) {
      throw StateError('Peer $peerId is not connected');
    }
    await session.sendFile(
      file,
      customFileName: customFileName,
      payloadId: payloadId,
    );
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
  void cancelPayload(int payloadId, {String? peerId}) {
    _payloadManager.cancelPayload(payloadId, peerId: peerId);
  }

  /// Disposes and shuts down all services, servers, and sessions.
  Future<void> dispose() async {
    await stopAdvertising();
    await stopDiscovery();
    await disconnectAll();
    for (final channel in List.of(_broadcastChannels)) {
      await channel.dispose();
    }
    _broadcastChannels.clear();
    _defaultBroadcastChannel = null;
    await _discoveryCoordinator.dispose();
    await _payloadManager.dispose();
    await _connectionRequestController.close();
    await _peerStateController.close();
  }
}
