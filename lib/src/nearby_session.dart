import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'models/peer.dart';
import 'payload/payload_manager.dart';
import 'protocol/packet_framer.dart';
import 'protocol/security_manager.dart';
import 'transport/ble_transport.dart';
import 'transport/tcp_transport.dart';
import 'transport/transport.dart';

/// Manages active peer session, protocol handshakes, SAS verification, and data transport.
class NearbySession {
  Peer peer;
  final NearbyTransport transport;
  final String localPeerId;
  final String localDisplayName;
  final PayloadManager payloadManager;
  final Directory? storageDirectory;

  final SecurityKeyPair _keyPair = SecurityManager.generateKeyPair();
  String get _localToken => _keyPair.publicKeyHex;
  String? _remoteToken;
  String? _sharedSecret;
  String? _sasPin;
  DateTime _lastTxTime = DateTime.fromMillisecondsSinceEpoch(0);
  Map<String, String> _handshakeMetadata = const {};
  Uint8List? _sessionKey;

  PeerConnectionState _state = PeerConnectionState.connecting;
  final Completer<bool> _handshakeCompleter = Completer<bool>();
  final StreamController<PeerConnectionState> _stateController =
      StreamController<PeerConnectionState>.broadcast();
  StreamSubscription<PacketFrame>? _frameSubscription;
  Timer? _heartbeatTimer;

  NearbySession({
    required this.peer,
    required this.transport,
    required this.localPeerId,
    required this.localDisplayName,
    required this.payloadManager,
    this.storageDirectory,
  }) {
    _init();
  }

  PeerConnectionState get state => _state;
  String? get sasPin => _sasPin;
  Uint8List? get sessionKey => _sessionKey;
  Stream<PeerConnectionState> get stateStream => _stateController.stream;

  void _setState(PeerConnectionState newState) {
    if (_state != newState) {
      _state = newState;
      _stateController.add(_state);
    }
  }

  void _init() {
    _frameSubscription = transport.incomingFrames.listen(
      (frame) async {
        try {
          await handleFrame(frame);
        } catch (error) {
          disconnect(reason: 'Frame processing error: $error');
        }
      },
      onError: (error) {
        disconnect(reason: 'Transport error: $error');
      },
      onDone: () {
        disconnect(reason: 'Transport closed');
      },
      cancelOnError: false,
    );
  }

  /// Initiates the handshake as the client/caller.
  Future<bool> initiateHandshake({
    Map<String, String> metadata = const {},
    Duration timeout = const Duration(seconds: 30),
  }) async {
    _setState(PeerConnectionState.connecting);
    _handshakeMetadata = Map<String, String>.unmodifiable(metadata);

    // Send HandshakeInit
    await transport.sendFrame(
      PacketFrame.handshakeInit(
        peerId: localPeerId,
        displayName: localDisplayName,
        token: _localToken,
        metadata: _handshakeMetadata,
      ),
    );

    try {
      return await _handshakeCompleter.future.timeout(timeout);
    } catch (_) {
      disconnect(reason: 'Handshake timeout');
      return false;
    }
  }

  /// Responds to an incoming HandshakeInit as the server/advertiser.
  Future<void> respondToHandshake({
    required bool accept,
    String? reason,
  }) async {
    await transport.sendFrame(
      PacketFrame.handshakeAck(
        peerId: localPeerId,
        displayName: localDisplayName,
        token: _localToken,
        accepted: accept,
        reason: reason,
      ),
    );

    if (accept) {
      if (_sharedSecret != null && _remoteToken != null) {
        final transcript = SecurityManager.computeTranscriptDigest(
          localPeerId: localPeerId,
          localToken: _localToken,
          remotePeerId: peer.id,
          remoteToken: _remoteToken!,
          sharedSecretHex: _sharedSecret,
          metadata: _handshakeMetadata,
        );
        _sessionKey = SecurityManager.deriveSessionKey(
          sharedSecretHex: _sharedSecret!,
          transcriptDigest: transcript,
        );
        transport.sessionKey = _sessionKey;
      }
      _setState(PeerConnectionState.connected);
      _startHeartbeat();
      if (!_handshakeCompleter.isCompleted) {
        _handshakeCompleter.complete(true);
      }
    } else {
      disconnect(reason: reason ?? 'Connection rejected');
      if (!_handshakeCompleter.isCompleted) {
        _handshakeCompleter.complete(false);
      }
    }
  }

  /// Processes an incoming frame from transport.
  Future<void> handleFrame(PacketFrame frame) async {
    switch (frame.type) {
      case FrameType.handshakeInit:
        final json =
            jsonDecode(utf8.decode(frame.body)) as Map<String, dynamic>;
        _remoteToken = json['token'] as String?;
        final String remotePeerId = json['peerId'] as String? ?? peer.id;
        final String remoteDisplayName =
            json['displayName'] as String? ?? peer.displayName;
        final Map<String, String> metadata =
            (json['metadata'] as Map<dynamic, dynamic>?)?.map(
              (k, v) => MapEntry(k.toString(), v.toString()),
            ) ??
            {};
        _handshakeMetadata = Map<String, String>.unmodifiable(metadata);
        peer = peer.copyWith(id: remotePeerId, displayName: remoteDisplayName);

        if (_remoteToken != null) {
          _sharedSecret = SecurityManager.computeSharedSecret(
            privateKey: _keyPair.privateKey,
            remotePublicKeyHex: _remoteToken!,
          );
          _sasPin = SecurityManager.calculateSasPin(
            localPeerId: localPeerId,
            localToken: _localToken,
            remotePeerId: remotePeerId,
            remoteToken: _remoteToken!,
            sharedSecretHex: _sharedSecret,
            metadata: _handshakeMetadata,
          );
        }
        _setState(PeerConnectionState.authenticating);
        break;

      case FrameType.handshakeAck:
        final json =
            jsonDecode(utf8.decode(frame.body)) as Map<String, dynamic>;
        final bool accepted = json['accepted'] == true;
        _remoteToken = json['token'] as String?;

        if (accepted && _remoteToken != null) {
          final String remotePeerId = json['peerId'] as String? ?? peer.id;
          final String remoteDisplayName =
              json['displayName'] as String? ?? peer.displayName;
          peer = peer.copyWith(
            id: remotePeerId,
            displayName: remoteDisplayName,
          );
          if (transport is TcpTransport) {
            (transport as TcpTransport).updatePeerId(remotePeerId);
          } else if (transport is BleTransport) {
            (transport as BleTransport).updatePeerId(remotePeerId);
          }

          _sharedSecret = SecurityManager.computeSharedSecret(
            privateKey: _keyPair.privateKey,
            remotePublicKeyHex: _remoteToken!,
          );
          _sasPin = SecurityManager.calculateSasPin(
            localPeerId: localPeerId,
            localToken: _localToken,
            remotePeerId: remotePeerId,
            remoteToken: _remoteToken!,
            sharedSecretHex: _sharedSecret,
            metadata: _handshakeMetadata,
          );
          final transcript = SecurityManager.computeTranscriptDigest(
            localPeerId: localPeerId,
            localToken: _localToken,
            remotePeerId: remotePeerId,
            remoteToken: _remoteToken!,
            sharedSecretHex: _sharedSecret,
            metadata: _handshakeMetadata,
          );
          _sessionKey = SecurityManager.deriveSessionKey(
            sharedSecretHex: _sharedSecret!,
            transcriptDigest: transcript,
          );
          transport.sessionKey = _sessionKey;
          _setState(PeerConnectionState.connected);
          _startHeartbeat();
          if (!_handshakeCompleter.isCompleted) {
            _handshakeCompleter.complete(true);
          }
        } else {
          final reason = json['reason'] as String? ?? 'Rejected by peer';
          disconnect(reason: reason);
          if (!_handshakeCompleter.isCompleted) {
            _handshakeCompleter.complete(false);
          }
        }
        break;

      case FrameType.handshakeReject:
        disconnect(reason: 'Rejected by remote peer');
        if (!_handshakeCompleter.isCompleted) {
          _handshakeCompleter.complete(false);
        }
        break;

      case FrameType.heartbeat:
      case FrameType.disconnect:
      case FrameType.payloadHeader:
      case FrameType.payloadChunk:
      case FrameType.payloadAck:
      case FrameType.payloadCancel:
        final sessionKey = _sessionKey;
        if (_state != PeerConnectionState.connected || sessionKey == null) {
          disconnect(reason: 'Rejected frame before session authentication');
          return;
        }

        late final PacketFrame clearFrame;
        try {
          clearFrame = frame.decrypt(sessionKey);
        } on FormatException {
          disconnect(reason: 'Rejected invalid encrypted session frame');
          return;
        }

        if (clearFrame.type == FrameType.heartbeat) {
          // Keepalive pulse acknowledged
          break;
        } else if (clearFrame.type == FrameType.disconnect) {
          final json =
              jsonDecode(utf8.decode(clearFrame.body)) as Map<String, dynamic>;
          final reason = json['reason'] as String? ?? 'Peer disconnected';
          disconnect(reason: reason, notifyRemote: false);
          break;
        }

        await payloadManager.handleIncomingFrame(
          peerId: peer.id,
          frame: clearFrame,
          storageDirectory: storageDirectory,
          transport: transport,
        );
        break;
    }
  }

  void _startHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(const Duration(seconds: 5), (_) async {
      if (_state == PeerConnectionState.connected && transport.isConnected) {
        // Only send heartbeat if no payload/control traffic was sent recently
        if (DateTime.now().difference(_lastTxTime) <
            const Duration(seconds: 4)) {
          return;
        }
        try {
          _lastTxTime = DateTime.now();
          await transport.sendFrame(PacketFrame.heartbeat());
        } catch (_) {
          disconnect(reason: 'Heartbeat send failed');
        }
      }
    });
  }

  bool get _isBleTransport =>
      transport is BleTransport || transport is BlePeripheralTransport;

  /// Sends a raw byte array payload.
  Future<void> sendBytes(Uint8List bytes, {int? payloadId}) async {
    if (_state != PeerConnectionState.connected) {
      throw StateError('Cannot send data; peer is not connected');
    }
    _lastTxTime = DateTime.now();
    final id = payloadId ?? DateTime.now().microsecondsSinceEpoch;
    await payloadManager.sendBytes(
      transport: transport,
      payloadId: id,
      bytes: bytes,
      chunkSize: _isBleTransport ? 16 * 1024 : kDefaultChunkSize,
    );
  }

  /// Sends a file.
  Future<void> sendFile(
    File file, {
    int? payloadId,
    String? customFileName,
  }) async {
    if (_state != PeerConnectionState.connected) {
      throw StateError('Cannot send data; peer is not connected');
    }
    _lastTxTime = DateTime.now();
    final id = payloadId ?? DateTime.now().microsecondsSinceEpoch;
    await payloadManager.sendFile(
      transport: transport,
      payloadId: id,
      file: file,
      customFileName: customFileName,
      chunkSize: _isBleTransport ? 16 * 1024 : kDefaultChunkSize,
    );
  }

  /// Sends a byte stream.
  Future<void> sendStream(Stream<List<int>> stream, {int? payloadId}) async {
    if (_state != PeerConnectionState.connected) {
      throw StateError('Cannot send data; peer is not connected');
    }
    _lastTxTime = DateTime.now();
    final id = payloadId ?? DateTime.now().microsecondsSinceEpoch;
    await payloadManager.sendStream(
      transport: transport,
      payloadId: id,
      stream: stream,
    );
  }

  /// Disconnects this session.
  Future<void> disconnect({String? reason, bool notifyRemote = true}) async {
    if (_state == PeerConnectionState.disconnected) return;
    _setState(PeerConnectionState.disconnected);

    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;

    if (notifyRemote && transport.isConnected) {
      try {
        await transport.sendFrame(PacketFrame.disconnect(reason: reason));
      } catch (_) {}
    }

    await _frameSubscription?.cancel();
    _frameSubscription = null;

    payloadManager.handlePeerDisconnected(peer.id);
    await transport.close();

    if (!_handshakeCompleter.isCompleted) {
      _handshakeCompleter.complete(false);
    }
  }

  /// Disposes session resources.
  Future<void> dispose() async {
    await disconnect();
    await _stateController.close();
  }
}
