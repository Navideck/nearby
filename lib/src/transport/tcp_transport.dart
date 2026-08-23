import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import '../protocol/packet_framer.dart';
import 'transport.dart';

/// TCP Socket implementation of [NearbyTransport] for high-bandwidth LAN data transfer.
class TcpTransport implements NearbyTransport {
  final Socket _socket;
  final String _peerId;
  final PacketFramer _framer = PacketFramer();
  final Completer<void> _doneCompleter = Completer<void>();
  bool _closed = false;

  TcpTransport._(this._socket, this._peerId) {
    _socket.listen(
      (data) {
        _framer.addBytes(data);
      },
      onError: (error) {
        close();
      },
      onDone: () {
        close();
      },
      cancelOnError: true,
    );
  }

  /// Wraps an established TCP socket.
  static TcpTransport wrap(Socket socket, {required String peerId}) {
    socket.setOption(SocketOption.tcpNoDelay, true);
    return TcpTransport._(socket, peerId);
  }

  /// Connects to a remote peer's TCP server socket.
  static Future<TcpTransport> connect({
    required String host,
    required int port,
    required String peerId,
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final socket = await Socket.connect(host, port, timeout: timeout);
    socket.setOption(SocketOption.tcpNoDelay, true);
    return TcpTransport._(socket, peerId);
  }

  @override
  String get peerId => _peerId;

  @override
  Stream<PacketFrame> get incomingFrames => _framer.frames;

  @override
  bool get isConnected => !_closed;

  /// Completer that resolves when the socket is closed or disconnected.
  Future<void> get done => _doneCompleter.future;

  @override
  Future<void> sendFrame(PacketFrame frame) async {
    if (_closed) {
      throw StateError('Cannot send frame on closed TCP transport');
    }
    final bytes = frame.toBytes();
    _socket.add(bytes);
    await _socket.flush();
  }

  @override
  Future<void> sendRaw(Uint8List data) async {
    if (_closed) {
      throw StateError('Cannot send raw data on closed TCP transport');
    }
    _socket.add(data);
    await _socket.flush();
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;

    try {
      await _socket.flush();
    } catch (_) {}

    try {
      await _socket.close();
      _socket.destroy();
    } catch (_) {}

    await _framer.close();

    if (!_doneCompleter.isCompleted) {
      _doneCompleter.complete();
    }
  }
}

/// TCP Server that listens for incoming socket connections from nearby peers.
class TcpServer {
  final ServerSocket _serverSocket;
  final StreamController<Socket> _incomingConnections =
      StreamController<Socket>.broadcast();

  TcpServer._(this._serverSocket) {
    _serverSocket.listen(
      (socket) {
        _incomingConnections.add(socket);
      },
      onError: (error) {
        // Log or handle server socket error
      },
      cancelOnError: false,
    );
  }

  /// Binds a server socket to any IPv4 interface on the specified or dynamic port.
  static Future<TcpServer> bind({int port = 0}) async {
    final serverSocket = await ServerSocket.bind(
      InternetAddress.anyIPv4,
      port,
      shared: true,
    );
    return TcpServer._(serverSocket);
  }

  /// The local TCP port assigned to this server.
  int get port => _serverSocket.port;

  /// The local IP address this server is bound to.
  InternetAddress get address => _serverSocket.address;

  /// Stream of incoming client socket connections.
  Stream<Socket> get incomingConnections => _incomingConnections.stream;

  /// Closes the server socket.
  Future<void> close() async {
    await _incomingConnections.close();
    await _serverSocket.close();
  }
}
