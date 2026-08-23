import 'dart:async';
import 'dart:typed_data';
import 'package:universal_ble/universal_ble.dart';
import '../protocol/packet_framer.dart';
import 'transport.dart';

/// Standard Nearby Bluetooth GATT Service and Characteristic UUIDs (dedicated 128-bit).
const String kNearbyBleServiceUuid = 'fa5a0001-9a3b-4654-8fe2-8a96d11f81d1';
const String kNearbyBleTxCharUuid = 'fa5a0002-9a3b-4654-8fe2-8a96d11f81d1';
const String kNearbyBleRxCharUuid = 'fa5a0003-9a3b-4654-8fe2-8a96d11f81d1';

/// BLE GATT Central (Client) implementation of [NearbyTransport].
/// Connects to a remote BLE GATT peripheral (server).
class BleTransport implements NearbyTransport {
  static final Map<String, BleTransport> _activeTransports = {};
  static bool _callbacksInitialized = false;

  final String _deviceId;
  String _peerId;
  final String _serviceUuid;
  final PacketFramer _framer = PacketFramer();
  final Completer<void> _doneCompleter = Completer<void>();
  bool _closed = false;
  int _mtu = 240;

  BleTransport._(this._deviceId, this._peerId, [this._serviceUuid = kNearbyBleServiceUuid]) {
    _ensureInitialized();
    _activeTransports[_deviceId.toLowerCase()] = this;
  }

  /// Factory registration to handle incoming characteristic value changes for this device.
  static void _ensureInitialized() {
    if (_callbacksInitialized) return;
    _callbacksInitialized = true;

    UniversalBle.onValueChange = (
      String deviceId,
      String characteristicId,
      Uint8List value,
      dynamic _,
    ) {
      final transport = _activeTransports[deviceId.toLowerCase()];
      if (transport != null && !transport._closed) {
        if (BleUuidParser.compareStrings(characteristicId, kNearbyBleRxCharUuid)) {
          transport._framer.addBytes(value);
        }
      }
    };

    UniversalBle.onConnectionChange = (
      String deviceId,
      bool isConnected,
      String? error,
    ) {
      if (!isConnected) {
        final transport = _activeTransports.remove(deviceId.toLowerCase());
        transport?.close();
      }
    };
  }

  /// Connects to a remote BLE peripheral and discovers nearby GATT characteristics.
  static Future<BleTransport> connect({
    required String deviceId,
    required String peerId,
    String? serviceUuid,
    Duration timeout = const Duration(seconds: 15),
  }) async {
    final targetServiceUuid = serviceUuid ?? kNearbyBleServiceUuid;

    // 1. Explicitly stop BLE scanning before connecting to prevent Android GATT error 133
    try {
      await UniversalBle.stopScan();
    } catch (_) {}

    // Give Bluetooth controller time to transition from scanning to connecting mode
    await Future.delayed(const Duration(milliseconds: 200));

    // 2. Connect with overall deadline retry and stale handle cleanup
    final deadline = DateTime.now().add(timeout);
    int attempts = 0;
    while (true) {
      attempts++;
      final remaining = deadline.difference(DateTime.now());
      if (remaining <= Duration.zero) {
        throw TimeoutException('BLE connect timed out after $timeout', timeout);
      }
      try {
        // Disconnect first to ensure stale native GATT client is cleared
        try {
          await UniversalBle.disconnect(deviceId);
        } catch (_) {}
        await Future.delayed(const Duration(milliseconds: 100));

        final connectRemaining = deadline.difference(DateTime.now());
        if (connectRemaining <= Duration.zero) {
          throw TimeoutException('BLE connect timed out after $timeout', timeout);
        }

        await UniversalBle.connect(deviceId).timeout(connectRemaining);
        break;
      } catch (e) {
        if (attempts >= 3 || deadline.difference(DateTime.now()) <= Duration.zero) {
          rethrow;
        }
        await Future.delayed(Duration(milliseconds: 200 * attempts));
      }
    }

    // 3. Register active transport instance ONLY after connection is established
    final transport = BleTransport._(deviceId, peerId, targetServiceUuid);

    try {
      // Allow GATT connection link to stabilize across platforms
      await Future.delayed(const Duration(milliseconds: 200));

      // Discover services
      await UniversalBle.discoverServices(deviceId);

      await Future.delayed(const Duration(milliseconds: 150));

      // Subscribe to RX characteristic notifications
      await UniversalBle.subscribeNotifications(
        deviceId,
        targetServiceUuid,
        kNearbyBleRxCharUuid,
      );

      // Request MTU if possible
      try {
        final negotiatedMtu = await UniversalBle.requestMtu(deviceId, 512);
        if (negotiatedMtu > 20) {
          transport._mtu = negotiatedMtu - 3;
        }
      } catch (_) {}

      // Request high performance connection priority on Android if possible
      try {
        await UniversalBle.requestConnectionPriority(
          deviceId,
          BleConnectionPriority.highPerformance,
        );
      } catch (_) {}

      return transport;
    } catch (e) {
      await transport.close();
      rethrow;
    }
  }

  Future<void> _writeQueue = Future.value();

  Future<T> _synchronizedWrite<T>(Future<T> Function() operation) {
    final next = _writeQueue.then((_) => operation(), onError: (_) => operation());
    _writeQueue = next.then((_) {}, onError: (_) {});
    return next;
  }

  @override
  String get peerId => _peerId;

  /// Updates the peer ID associated with this transport.
  void updatePeerId(String peerId) {
    _peerId = peerId;
  }

  /// The underlying BLE peripheral device ID.
  String get deviceId => _deviceId;

  /// The service UUID used for GATT communication.
  String get serviceUuid => _serviceUuid;

  @override
  Stream<PacketFrame> get incomingFrames => _framer.frames;

  @override
  bool get isConnected => !_closed;

  /// Completer that resolves when the BLE connection is closed.
  Future<void> get done => _doneCompleter.future;

  @override
  Future<void> sendFrame(PacketFrame frame) async {
    if (_closed) {
      throw StateError('Cannot send frame on closed BLE transport');
    }
    final bytes = frame.toBytes();
    await sendRaw(bytes);
  }

  @override
  Future<void> sendRaw(Uint8List data) {
    return _synchronizedWrite(() async {
      if (_closed) {
        throw StateError('Cannot send raw data on closed BLE transport');
      }

      // Chunk the data according to BLE MTU size
      int offset = 0;
      while (offset < data.length) {
        if (_closed) break;
        final int chunkSize =
            (data.length - offset < _mtu) ? (data.length - offset) : _mtu;
        final Uint8List chunk = data.sublist(offset, offset + chunkSize);

        int attempts = 0;
        bool sent = false;
        while (!sent && attempts < 8 && !_closed) {
          attempts++;
          try {
            await UniversalBle.write(
              _deviceId,
              _serviceUuid,
              kNearbyBleTxCharUuid,
              chunk,
              withoutResponse: false,
            );
            sent = true;
          } catch (e) {
            if (attempts >= 8) rethrow;
            await Future<void>.delayed(Duration(milliseconds: 15 * attempts));
          }
        }

        offset += chunkSize;
        if (offset < data.length) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
      }
    });
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;

    _activeTransports.remove(_deviceId.toLowerCase());

    try {
      await UniversalBle.disconnect(_deviceId);
    } catch (_) {}

    await _framer.close();

    if (!_doneCompleter.isCompleted) {
      _doneCompleter.complete();
    }
  }
}

/// BLE GATT Peripheral (Server) implementation of [NearbyTransport].
/// Represents an active incoming connection from a remote BLE central (client).
class BlePeripheralTransport implements NearbyTransport {
  static final Map<String, BlePeripheralTransport> _activeTransports = {};
  static final StreamController<BlePeripheralTransport> _incomingTransportsController =
      StreamController<BlePeripheralTransport>.broadcast();

  /// Stream of newly connected incoming BLE central transports.
  static Stream<BlePeripheralTransport> get incomingTransports =>
      _incomingTransportsController.stream;

  final String _deviceId;
  String _peerId;
  final PacketFramer _framer = PacketFramer();
  final Completer<void> _doneCompleter = Completer<void>();
  bool _closed = false;
  int _mtu = 240;

  BlePeripheralTransport._(this._deviceId, this._peerId);

  /// Retrieves or creates an active peripheral transport for an incoming central device.
  static BlePeripheralTransport getOrCreate(String deviceId) {
    final key = deviceId.toLowerCase();
    var transport = _activeTransports[key];
    if (transport == null || !transport.isConnected) {
      transport = BlePeripheralTransport._(deviceId, 'pending');
      _activeTransports[key] = transport;
      _incomingTransportsController.add(transport);
    }
    return transport;
  }

  /// Handles incoming bytes written to the TX characteristic by a remote central.
  static void handleIncomingWrite(String deviceId, Uint8List data) {
    final transport = getOrCreate(deviceId);
    transport._framer.addBytes(data);
  }

  /// Handles MTU update for a connected central device.
  static void handleMtuChanged(String deviceId, int mtu) {
    final transport = _activeTransports[deviceId.toLowerCase()];
    if (transport != null && mtu > 20) {
      transport._mtu = mtu - 3;
    }
  }

  /// Handles disconnection of a remote central device.
  static void handleDisconnected(String deviceId) {
    final transport = _activeTransports.remove(deviceId.toLowerCase());
    transport?._markClosed();
  }

  Future<void> _writeQueue = Future.value();

  Future<T> _synchronizedWrite<T>(Future<T> Function() operation) {
    final next = _writeQueue.then((_) => operation(), onError: (_) => operation());
    _writeQueue = next.then((_) {}, onError: (_) {});
    return next;
  }

  @override
  String get peerId => _peerId;

  /// Updates the peer ID associated with this transport.
  void updatePeerId(String peerId) {
    _peerId = peerId;
  }

  /// The remote central device identifier.
  String get deviceId => _deviceId;

  @override
  Stream<PacketFrame> get incomingFrames => _framer.frames;

  @override
  bool get isConnected => !_closed;

  /// Completer that resolves when the BLE connection is closed.
  Future<void> get done => _doneCompleter.future;

  @override
  Future<void> sendFrame(PacketFrame frame) async {
    if (_closed) {
      throw StateError('Cannot send frame on closed BLE peripheral transport');
    }
    final bytes = frame.toBytes();
    await sendRaw(bytes);
  }

  @override
  Future<void> sendRaw(Uint8List data) {
    return _synchronizedWrite(() async {
      if (_closed) {
        throw StateError('Cannot send raw data on closed BLE peripheral transport');
      }

      // Chunk data according to MTU size and notify subscribed central on RX characteristic
      int offset = 0;
      while (offset < data.length) {
        if (_closed) break;
        final int chunkSize =
            (data.length - offset < _mtu) ? (data.length - offset) : _mtu;
        final Uint8List chunk = data.sublist(offset, offset + chunkSize);

        int attempts = 0;
        bool sent = false;
        while (!sent && attempts < 8 && !_closed) {
          attempts++;
          try {
            await UniversalBlePeripheral.updateCharacteristicValue(
              characteristicId: kNearbyBleRxCharUuid,
              value: chunk,
              deviceId: _deviceId,
            );
            sent = true;
          } catch (e) {
            if (attempts >= 8) rethrow;
            await Future<void>.delayed(Duration(milliseconds: 15 * attempts));
          }
        }

        offset += chunkSize;
        if (offset < data.length) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
      }
    });
  }

  void _markClosed() {
    if (_closed) return;
    _closed = true;
    _activeTransports.remove(_deviceId.toLowerCase());
    unawaited(_framer.close());
    if (!_doneCompleter.isCompleted) {
      _doneCompleter.complete();
    }
  }

  @override
  Future<void> close() async {
    _markClosed();
  }
}

