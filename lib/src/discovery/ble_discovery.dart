import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:universal_ble/universal_ble.dart';
import '../models/peer.dart';
import '../transport/ble_transport.dart';

/// Bluetooth Low Energy (BLE) discovery service using UniversalBle.
class BleDiscoveryService {
  final StreamController<Peer> _peerFoundController =
      StreamController<Peer>.broadcast();
  final StreamController<String> _peerLostController =
      StreamController<String>.broadcast();

  bool _isScanning = false;
  bool _isAdvertising = false;

  Stream<Peer> get onPeerFound => _peerFoundController.stream;
  Stream<String> get onPeerLost => _peerLostController.stream;

  /// Starts BLE scanning for devices advertising the nearby service UUID.
  Future<void> startScanning({
    String? serviceUuid,
  }) async {
    await stopScanning();
    _isScanning = true;

    final targetUuid = serviceUuid ?? kNearbyBleServiceUuid;

    UniversalBle.onScanResult = (BleDevice device) {
      if (!_isScanning) return;

      // Extract device name or metadata from advertisement
      final String? name = device.name;
      if (name == null || name.trim().isEmpty) return;

      // Parse metadata if available in manufacturer data
      Map<String, String> metadata = {};
      final mfgList = device.manufacturerDataList;
      if (mfgList.isNotEmpty) {
        for (final mfg in mfgList) {
          try {
            final decoded = utf8.decode(mfg.payload, allowMalformed: true);
            final map = jsonDecode(decoded) as Map<String, dynamic>;
            metadata.addAll(map.map((k, v) => MapEntry(k.toString(), v.toString())));
          } catch (_) {}
        }
      }

      final peerId = metadata['id'] ?? device.deviceId;
      final displayName = metadata['name'] ?? name;

      final peer = Peer(
        id: peerId,
        displayName: displayName,
        metadata: metadata,
        discoveredVia: DiscoveryMedium.ble,
        bleDeviceId: device.deviceId,
        rssi: device.rssi,
        lastSeen: DateTime.now(),
      );

      _peerFoundController.add(peer);
    };

    final scanFilter = ScanFilter(
      withServices: [targetUuid],
    );

    try {
      await UniversalBle.startScan(scanFilter: scanFilter);
    } catch (_) {
      // Fallback to unscoped scan if service filter fails on certain platforms
      await UniversalBle.startScan();
    }
  }

  /// Stops BLE scanning.
  Future<void> stopScanning() async {
    if (_isScanning) {
      _isScanning = false;
      try {
        await UniversalBle.stopScan();
      } catch (_) {}
    }
  }

  /// Starts BLE peripheral advertising if supported by the platform.
  Future<void> startAdvertising({
    required String peerId,
    required String displayName,
    Map<String, String> metadata = const {},
  }) async {
    await stopAdvertising();
    _isAdvertising = true;

    final Map<String, dynamic> payload = {
      'id': peerId,
      'name': displayName,
      ...metadata,
    };

    final Uint8List mfgData = Uint8List.fromList(utf8.encode(jsonEncode(payload)));

    try {
      // Peripheral advertising via universal_ble
      await UniversalBlePeripheral.startAdvertising(
        services: [kNearbyBleServiceUuid],
        manufacturerData: ManufacturerData(0xFFFF, mfgData),
      );
    } catch (_) {
      // Platform may not support BLE peripheral advertising; mDNS is primary
    }
  }

  /// Stops BLE peripheral advertising.
  Future<void> stopAdvertising() async {
    if (_isAdvertising) {
      _isAdvertising = false;
      try {
        await UniversalBlePeripheral.stopAdvertising();
      } catch (_) {}
    }
  }

  /// Disposes resources.
  Future<void> dispose() async {
    await stopScanning();
    await stopAdvertising();
    await _peerFoundController.close();
    await _peerLostController.close();
  }
}
