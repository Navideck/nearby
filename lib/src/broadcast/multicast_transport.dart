import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'multicast_lock.dart';

/// IPv4 multicast with broadcast fallback and per-interface send sockets.
class MulticastTransport {
  final InternetAddress group;
  final int port;
  final _senders = <RawDatagramSocket>[];
  RawDatagramSocket? _listener;
  StreamSubscription<RawSocketEvent>? _subscription;
  Timer? _refresh;
  bool _sending = false;
  bool _listening = false;
  bool _lockHeld = false;
  Future<void>? _refreshing;

  MulticastTransport(String address, this.port)
    : group = InternetAddress(address);

  Future<void> startSending() async {
    _sending = true;
    await _refreshInterfaces();
    _startRefresh();
    if (_senders.isEmpty) {
      throw const SocketException('No multicast sender available');
    }
  }

  void _startRefresh() {
    _refresh ??= Timer.periodic(const Duration(seconds: 5), (_) {
      unawaited(_refreshInterfaces());
    });
  }

  Future<void> _refreshInterfaces() => _refreshing ??= _updateInterfaces()
      .whenComplete(() => _refreshing = null);

  Future<void> _updateInterfaces() async {
    List<NetworkInterface> interfaces;
    try {
      interfaces = await NetworkInterface.list(
        includeLoopback: true,
        type: InternetAddressType.IPv4,
      );
    } catch (_) {
      interfaces = [];
    }
    if (_listening && _listener != null) {
      for (final interface in interfaces) {
        try {
          _listener!.joinMulticast(group, interface);
        } catch (_) {
          /* Already joined or unavailable. */
        }
      }
      try {
        _listener!.joinMulticast(group);
      } catch (_) {
        /* Already joined or unavailable. */
      }
    }
    if (!_sending) return;
    final next = <RawDatagramSocket>[];
    for (final address in [
      InternetAddress.anyIPv4,
      for (final interface in interfaces) ...interface.addresses,
    ]) {
      RawDatagramSocket? socket;
      try {
        socket = await RawDatagramSocket.bind(address, 0);
        socket.broadcastEnabled = true;
        socket.multicastLoopback = true;
        socket.multicastHops = 1;
        if (address != InternetAddress.anyIPv4) {
          try {
            socket.setRawOption(
              RawSocketOption(
                RawSocketOption.levelIPv4,
                RawSocketOption.IPv4MulticastInterface,
                address.rawAddress,
              ),
            );
          } catch (_) {
            /* The bound address still selects this interface. */
          }
        }
        next.add(socket);
      } catch (_) {
        socket?.close();
      }
    }
    if (!_sending) {
      for (final socket in next) {
        socket.close();
      }
      return;
    }
    if (next.isEmpty) {
      return; // Keep working sockets during transient route changes.
    }
    for (final socket in _senders) {
      socket.close();
    }
    _senders
      ..clear()
      ..addAll(next);
  }

  bool send(Uint8List bytes) {
    var sent = false;
    for (final socket in _senders) {
      for (final target in [group, InternetAddress('255.255.255.255')]) {
        try {
          sent = socket.send(bytes, target, port) > 0 || sent;
        } catch (_) {
          /* Another interface/carrier may still succeed. */
        }
      }
    }
    return sent;
  }

  Future<void> startListening(
    void Function(Datagram, DateTime) onPacket,
  ) async {
    _listening = true;
    _lockHeld = await MulticastLock.instance.acquire();
    try {
      _listener = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        port,
        reuseAddress: true,
        reusePort: Platform.isMacOS || Platform.isLinux,
      );
      _listener!.multicastLoopback = true;
      _subscription = _listener!.listen((event) {
        if (event != RawSocketEvent.read || !_listening) return;
        Datagram? packet;
        while ((packet = _listener?.receive()) != null) {
          onPacket(packet!, DateTime.now());
        }
      });
      await _refreshInterfaces();
      _startRefresh();
    } catch (_) {
      await stopListening();
      rethrow;
    }
  }

  Future<void> stopSending() async {
    _sending = false;
    await _refreshing;
    for (final socket in _senders) {
      socket.close();
    }
    _senders.clear();
    _stopRefreshIfIdle();
  }

  Future<void> stopListening() async {
    _listening = false;
    await _subscription?.cancel();
    _subscription = null;
    _listener?.close();
    _listener = null;
    if (_lockHeld) {
      _lockHeld = false;
      await MulticastLock.instance.release();
    }
    _stopRefreshIfIdle();
  }

  void _stopRefreshIfIdle() {
    if (!_sending && !_listening) {
      _refresh?.cancel();
      _refresh = null;
    }
  }

  /// Returns true if at least one non-loopback IPv4 network interface is available
  /// for multicast transmission (excluding non-multicast cellular interfaces).
  static Future<bool> isNetworkAvailable() async {
    try {
      final interfaces = await NetworkInterface.list(
        includeLoopback: false,
        type: InternetAddressType.IPv4,
      );
      return interfaces.any((i) {
        final name = i.name.toLowerCase();
        return !name.startsWith('rmnet') &&
            !name.startsWith('ccmni') &&
            !name.startsWith('pdp_ip') &&
            !name.startsWith('dummy');
      });
    } catch (_) {
      return false;
    }
  }
}
