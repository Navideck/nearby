import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:universal_ble/universal_ble.dart';

import '../protocol/packet_framer.dart';
import 'ble/ble_chunk_sender.dart';
import 'ble/ble_constants.dart';
import 'ble/ble_scan_dispatcher.dart';
import 'ble/ble_transport_registry.dart';
import 'transport.dart';

// Re-export constants for backwards compatibility
export 'ble/ble_constants.dart';

/// BLE GATT Central (Client) implementation of [NearbyTransport].
/// Connects to a remote BLE GATT peripheral (server).
class BleTransport implements NearbyTransport {
  final String _deviceId;
  String _peerId;
  final String _serviceUuid;
  final PacketFramer _framer = PacketFramer();
  final Completer<void> _doneCompleter = Completer<void>();
  final BleChunkSender _chunkSender = BleChunkSender();
  bool _closed = false;
  int _mtu = kBleDefaultMtu;

  BleTransport._(
    this._deviceId,
    this._peerId, [
    this._serviceUuid = kNearbyBleServiceUuid,
  ]) {
    BleTransportRegistry.instance.registerCentral(_deviceId, this);
  }

  /// Indicates if this transport is closed.
  bool get isClosed => _closed;

  /// Underlying packet framer instance.
  PacketFramer get framer => _framer;

  /// Connects to a remote BLE peripheral and discovers nearby GATT characteristics.
  static Future<BleTransport> connect({
    required String deviceId,
    required String peerId,
    String? serviceUuid,
    Duration timeout = const Duration(seconds: 15),
  }) async {
    final targetServiceUuid = serviceUuid ?? kNearbyBleServiceUuid;

    // 1. Explicitly suspend BLE scanning before connecting to prevent Android GATT error 133
    await BleScanDispatcher.instance.suspendScan();
    try {
      // 2. Connect with overall deadline retry
      final deadline = DateTime.now().add(timeout);
      int attempts = 0;
      while (true) {
        attempts++;
        final remaining = deadline.difference(DateTime.now());
        if (remaining <= Duration.zero) {
          throw TimeoutException('BLE connect timed out after $timeout', timeout);
        }
        try {
          final connectRemaining = deadline.difference(DateTime.now());
          if (connectRemaining <= Duration.zero) {
            throw TimeoutException(
              'BLE connect timed out after $timeout',
              timeout,
            );
          }

          await UniversalBle.connect(deviceId).timeout(connectRemaining);
          break;
        } catch (e) {
          if (attempts >= 3 ||
              deadline.difference(DateTime.now()) <= Duration.zero) {
            rethrow;
          }
          await UniversalBle.disconnect(deviceId);
        }
      }

      // 3. Register active transport instance ONLY after connection is established
      final transport = BleTransport._(deviceId, peerId, targetServiceUuid);

      try {
        // Discover services
        await UniversalBle.discoverServices(deviceId);

        // Subscribe to RX characteristic notifications
        await UniversalBle.subscribeNotifications(
          deviceId,
          targetServiceUuid,
          kNearbyBleRxCharUuid,
        );

        // Request MTU if possible
        try {
          final negotiatedMtu = await UniversalBle.requestMtu(deviceId, 512);
          if (negotiatedMtu >= kBleMinMtu) {
            transport._mtu = min(negotiatedMtu - 3, kBleMaxChunkSize);
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
    } finally {
      await BleScanDispatcher.instance.resumeScan();
    }
  }

  @override
  String get peerId => _peerId;

  /// Updates the peer ID associated with this transport.
  void updatePeerId(String peerId) {
    _peerId = peerId;
  }

  Uint8List? _sessionKey;

  @override
  Uint8List? get sessionKey => _sessionKey;

  @override
  set sessionKey(Uint8List? key) {
    _sessionKey = key;
  }

  /// The remote peripheral device identifier.
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
    final bytes = frame.toBytes(sessionKey: _sessionKey);
    await sendRaw(bytes);
  }

  @override
  Future<void> sendRaw(Uint8List data) {
    return _chunkSender.sendChunks(
      data: data,
      mtu: _mtu,
      isClosed: () => _closed,
      writeChunk: (chunk) => UniversalBle.write(
        _deviceId,
        _serviceUuid,
        kNearbyBleTxCharUuid,
        chunk,
        withoutResponse: false,
      ),
    );
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;

    BleTransportRegistry.instance.unregisterCentral(_deviceId);

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
  final String _deviceId;
  String _peerId;
  final PacketFramer _framer = PacketFramer();
  final Completer<void> _doneCompleter = Completer<void>();
  final BleChunkSender _chunkSender = BleChunkSender();
  bool _closed = false;
  int _mtu = kBleDefaultMtu;

  BlePeripheralTransport._(this._deviceId, this._peerId);

  /// Internal factory for [BleTransportRegistry].
  static BlePeripheralTransport create(String deviceId, String peerId) =>
      BlePeripheralTransport._(deviceId, peerId);

  /// Stream of newly connected incoming BLE central transports.
  static Stream<BlePeripheralTransport> get incomingTransports =>
      BleTransportRegistry.instance.incomingPeripheralTransports;

  /// Gets or creates a peripheral transport for a given remote central device ID.
  static BlePeripheralTransport getOrCreate(
    String deviceId, [
    String? peerId,
  ]) => BleTransportRegistry.instance.getOrCreatePeripheral(deviceId, peerId);

  /// Handles incoming data written by a remote central device.
  static void handleIncomingWrite(String deviceId, Uint8List data) =>
      BleTransportRegistry.instance.handlePeripheralIncomingWrite(
        deviceId,
        data,
      );

  /// Handles MTU update for a connected central device.
  static void handleMtuChanged(String deviceId, int mtu) =>
      BleTransportRegistry.instance.handlePeripheralMtuChanged(deviceId, mtu);

  /// Handles disconnection of a remote central device.
  static void handleDisconnected(String deviceId) =>
      BleTransportRegistry.instance.handlePeripheralDisconnected(deviceId);

  /// Indicates if this transport is closed.
  bool get isClosed => _closed;

  /// Underlying packet framer instance.
  PacketFramer get framer => _framer;

  /// Marks this peripheral transport as closed from external event.
  void markClosed() {
    if (_closed) return;
    _closed = true;
    BleTransportRegistry.instance.unregisterPeripheral(_deviceId);
    _framer.close();
    if (!_doneCompleter.isCompleted) {
      _doneCompleter.complete();
    }
  }

  /// Sets the negotiated MTU for this peripheral connection.
  void setMtu(int mtu) {
    _mtu = min(mtu - 3, kBleMaxChunkSize);
  }

  @override
  String get peerId => _peerId;

  /// Updates the peer ID associated with this transport.
  void updatePeerId(String peerId) {
    _peerId = peerId;
  }

  Uint8List? _sessionKey;

  @override
  Uint8List? get sessionKey => _sessionKey;

  @override
  set sessionKey(Uint8List? key) {
    _sessionKey = key;
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
    final bytes = frame.toBytes(sessionKey: _sessionKey);
    await sendRaw(bytes);
  }

  @override
  Future<void> sendRaw(Uint8List data) {
    // Windows WinRT GATT server does not support targeting a specific client device ID
    // when sending characteristic notifications/indications, returning a 'not-supported'
    // error if deviceId is provided. Passing null targets all subscribed centrals.
    final targetDeviceId =
        defaultTargetPlatform == TargetPlatform.windows ? null : _deviceId;

    return _chunkSender.sendChunks(
      data: data,
      mtu: _mtu,
      isClosed: () => _closed,
      writeChunk: (chunk) async {
        try {
          await UniversalBlePeripheral.updateCharacteristicValue(
            characteristicId: kNearbyBleRxCharUuid,
            value: chunk,
            deviceId: targetDeviceId,
          );
        } on PlatformException catch (e) {
          if (e.code == 'not-supported') {
            await UniversalBlePeripheral.updateCharacteristicValue(
              characteristicId: kNearbyBleRxCharUuid,
              value: chunk,
              deviceId: null,
            );
          } else {
            rethrow;
          }
        }
      },
    );
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;

    BleTransportRegistry.instance.unregisterPeripheral(_deviceId);

    try {
      await UniversalBle.disconnect(_deviceId);
    } catch (_) {}

    await _framer.close();

    if (!_doneCompleter.isCompleted) {
      _doneCompleter.complete();
    }
  }
}
