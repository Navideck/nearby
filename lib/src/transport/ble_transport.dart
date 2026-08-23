import 'dart:async';
import 'dart:typed_data';
import 'package:universal_ble/universal_ble.dart';
import '../protocol/packet_framer.dart';
import 'transport.dart';

/// Standard Nearby Bluetooth GATT Service and Characteristic UUIDs.
const String kNearbyBleServiceUuid = '0000fe20-0000-1000-8000-00805f9b34fb';
const String kNearbyBleTxCharUuid = '0000fe21-0000-1000-8000-00805f9b34fb';
const String kNearbyBleRxCharUuid = '0000fe22-0000-1000-8000-00805f9b34fb';

/// BLE GATT Characteristic implementation of [NearbyTransport] for fallback connections.
class BleTransport implements NearbyTransport {
  static final Map<String, BleTransport> _activeTransports = {};
  static bool _callbacksInitialized = false;

  final String _deviceId;
  final String _peerId;
  final PacketFramer _framer = PacketFramer();
  final Completer<void> _doneCompleter = Completer<void>();
  bool _closed = false;
  int _mtu = 240;

  BleTransport._(this._deviceId, this._peerId) {
    _ensureGlobalCallbacks();
    _activeTransports[_deviceId.toLowerCase()] = this;
  }

  static void _ensureGlobalCallbacks() {
    if (_callbacksInitialized) return;
    _callbacksInitialized = true;

    UniversalBle.onValueChange = (
      String deviceId,
      String characteristicId,
      Uint8List value,
      dynamic _,
    ) {
      final transport = _activeTransports[deviceId.toLowerCase()];
      transport?._framer.addBytes(value);
    };

    UniversalBle.onConnectionChange = (
      String deviceId,
      bool isConnected,
      String? error,
    ) {
      if (!isConnected) {
        final transport = _activeTransports[deviceId.toLowerCase()];
        transport?.close();
      }
    };
  }

  /// Connects to a remote BLE peripheral and discovers nearby GATT characteristics.
  static Future<BleTransport> connect({
    required String deviceId,
    required String peerId,
    Duration timeout = const Duration(seconds: 10),
  }) async {
    await UniversalBle.connect(deviceId).timeout(timeout);

    // Discover services
    await UniversalBle.discoverServices(deviceId);

    // Subscribe to RX characteristic notifications
    await UniversalBle.subscribeNotifications(
      deviceId,
      kNearbyBleServiceUuid,
      kNearbyBleRxCharUuid,
    );

    // Request MTU if possible
    try {
      final mtu = await UniversalBle.requestMtu(deviceId, 512);
      final transport = BleTransport._(deviceId, peerId);
      transport._mtu = (mtu > 20) ? mtu - 3 : 240;
      return transport;
    } catch (_) {
      return BleTransport._(deviceId, peerId);
    }
  }

  @override
  String get peerId => _peerId;

  /// The underlying BLE peripheral device ID.
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
      throw StateError('Cannot send frame on closed BLE transport');
    }
    final bytes = frame.toBytes();
    await sendRaw(bytes);
  }

  @override
  Future<void> sendRaw(Uint8List data) async {
    if (_closed) {
      throw StateError('Cannot send raw data on closed BLE transport');
    }

    // Chunk the data according to BLE MTU size
    int offset = 0;
    while (offset < data.length) {
      final int chunkSize = (data.length - offset < _mtu) ? (data.length - offset) : _mtu;
      final Uint8List chunk = data.sublist(offset, offset + chunkSize);

      await UniversalBle.write(
        _deviceId,
        kNearbyBleServiceUuid,
        kNearbyBleTxCharUuid,
        chunk,
      );

      offset += chunkSize;
    }
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
