import 'dart:async';
import 'dart:typed_data';
import 'package:universal_ble/universal_ble.dart';
import '../ble_transport.dart';

/// Centralized registry and event dispatcher for active BLE transports.
class BleTransportRegistry {
  BleTransportRegistry._();

  static final BleTransportRegistry instance = BleTransportRegistry._();

  final Map<String, BleTransport> _centralTransports = {};
  final Map<String, BlePeripheralTransport> _peripheralTransports = {};
  final StreamController<BlePeripheralTransport> _incomingTransportsController =
      StreamController<BlePeripheralTransport>.broadcast();

  bool _callbacksInitialized = false;

  /// Stream of newly connected incoming BLE central transports.
  Stream<BlePeripheralTransport> get incomingPeripheralTransports =>
      _incomingTransportsController.stream;

  /// Ensures global UniversalBle callbacks are hooked to route incoming frames and disconnects.
  void ensureCallbacksInitialized() {
    if (_callbacksInitialized) return;
    _callbacksInitialized = true;

    UniversalBle.onValueChange = (
      String deviceId,
      String characteristicId,
      Uint8List value,
      dynamic _,
    ) {
      final key = normalizeDeviceId(deviceId);
      final transport = _centralTransports[key] ??
          (_centralTransports.length == 1 ? _centralTransports.values.first : null);

      if (transport != null && !transport.isClosed) {
        if (BleUuidParser.compareStrings(characteristicId, kNearbyBleRxCharUuid)) {
          transport.framer.addBytes(value);
        }
      }
    };

    UniversalBle.onConnectionChange = (
      String deviceId,
      bool isConnected,
      String? error,
    ) {
      if (!isConnected) {
        final key = normalizeDeviceId(deviceId);
        final transport = _centralTransports.remove(key);
        transport?.close();
      }
    };
  }

  // --- Central Management ---

  void registerCentral(String deviceId, BleTransport transport) {
    ensureCallbacksInitialized();
    _centralTransports[normalizeDeviceId(deviceId)] = transport;
  }

  void unregisterCentral(String deviceId) {
    _centralTransports.remove(normalizeDeviceId(deviceId));
  }

  BleTransport? getCentral(String deviceId) =>
      _centralTransports[normalizeDeviceId(deviceId)];

  // --- Peripheral Management ---

  BlePeripheralTransport getOrCreatePeripheral(String deviceId, [String? peerId]) {
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
    _centralTransports.clear();
    _peripheralTransports.clear();
  }
}
