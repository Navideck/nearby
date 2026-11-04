import 'dart:async';
import 'dart:typed_data';

import 'package:universal_ble/universal_ble.dart';

import '../ble_transport.dart';

typedef _CentralBleSubscriptions = ({
  StreamSubscription<Uint8List> valueSub,
  StreamSubscription<BleConnectionChange> connectionSub,
});

/// Centralized registry and event dispatcher for active BLE transports.
///
/// Subscribes to per-device [UniversalBle] broadcast streams rather than
/// mutating global `UniversalBle.onValueChange` or
/// `UniversalBle.onConnectionChange` callbacks so host applications can
/// coexist on the same Bluetooth stack without losing events.
class BleTransportRegistry {
  BleTransportRegistry._();

  static final BleTransportRegistry instance = BleTransportRegistry._();

  final Map<String, BleTransport> _centralTransports = {};
  final Map<String, _CentralBleSubscriptions> _centralSubscriptions = {};
  final Map<String, BlePeripheralTransport> _peripheralTransports = {};
  final StreamController<BlePeripheralTransport> _incomingTransportsController =
      StreamController<BlePeripheralTransport>.broadcast();

  /// Stream of newly connected incoming BLE central transports.
  Stream<BlePeripheralTransport> get incomingPeripheralTransports =>
      _incomingTransportsController.stream;

  // --- Central Management ---

  void registerCentral(String deviceId, BleTransport transport) {
    final key = normalizeDeviceId(deviceId);
    _cancelCentralSubscriptions(key);
    _centralTransports[key] = transport;

    final valueSub = UniversalBle.characteristicValueStream(
      deviceId,
      kNearbyBleRxCharUuid,
    ).listen((value) {
      if (!transport.isClosed) {
        transport.framer.addBytes(value);
      }
    });

    final connectionSub = UniversalBle.connectionChangeStream(deviceId).listen((
      update,
    ) {
      if (!update.isConnected) {
        final removed = _centralTransports.remove(key);
        _cancelCentralSubscriptions(key);
        unawaited(removed?.close());
      }
    });

    _centralSubscriptions[key] = (
      valueSub: valueSub,
      connectionSub: connectionSub,
    );
  }

  void unregisterCentral(String deviceId) {
    final key = normalizeDeviceId(deviceId);
    _centralTransports.remove(key);
    _cancelCentralSubscriptions(key);
  }

  void _cancelCentralSubscriptions(String key) {
    final subs = _centralSubscriptions.remove(key);
    if (subs != null) {
      unawaited(subs.valueSub.cancel());
      unawaited(subs.connectionSub.cancel());
    }
  }

  BleTransport? getCentral(String deviceId) =>
      _centralTransports[normalizeDeviceId(deviceId)];

  // --- Peripheral Management ---

  BlePeripheralTransport getOrCreatePeripheral(
    String deviceId, [
    String? peerId,
  ]) {
    final key = normalizeDeviceId(deviceId);
    var transport = _peripheralTransports[key];

    if (transport == null || transport.isClosed) {
      transport = BlePeripheralTransport.create(deviceId, peerId ?? deviceId);
      _peripheralTransports[key] = transport;
      _incomingTransportsController.add(transport);
    } else if (peerId != null && peerId.isNotEmpty) {
      transport.updatePeerId(peerId);
    }

    return transport;
  }

  void unregisterPeripheral(String deviceId) {
    _peripheralTransports.remove(normalizeDeviceId(deviceId));
  }

  BlePeripheralTransport? getPeripheral(String deviceId) =>
      _peripheralTransports[normalizeDeviceId(deviceId)];

  void handlePeripheralIncomingWrite(String deviceId, Uint8List data) {
    final transport = getOrCreatePeripheral(deviceId);
    transport.framer.addBytes(data);
  }

  void handlePeripheralDisconnected(String deviceId) {
    final key = normalizeDeviceId(deviceId);
    final transport = _peripheralTransports.remove(key);
    transport?.markClosed();
  }

  void handlePeripheralMtuChanged(String deviceId, int mtu) {
    final transport = getPeripheral(deviceId);
    if (transport != null && mtu >= kBleMinMtu) {
      transport.setMtu(mtu);
    }
  }

  /// Clears all registered transports (useful for teardown/tests).
  void clear() {
    for (final key in _centralSubscriptions.keys.toList()) {
      _cancelCentralSubscriptions(key);
    }
    _centralTransports.clear();
    _peripheralTransports.clear();
  }
}
