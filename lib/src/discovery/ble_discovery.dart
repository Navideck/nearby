import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:universal_ble/universal_ble.dart';
import '../models/peer.dart';
import '../transport/ble_transport.dart';

/// Bluetooth Low Energy (BLE) discovery and GATT service host using UniversalBle.
class BleDiscoveryService {
  final StreamController<Peer> _peerFoundController =
      StreamController<Peer>.broadcast();
  final StreamController<String> _peerLostController =
      StreamController<String>.broadcast();

  bool _isScanning = false;
  bool _isAdvertising = false;
  StreamSubscription? _connectionStateSub;
  StreamSubscription? _mtuSub;

  Stream<Peer> get onPeerFound => _peerFoundController.stream;
  Stream<String> get onPeerLost => _peerLostController.stream;

  /// Stream of incoming client transports connected to our GATT Server.
  Stream<BlePeripheralTransport> get incomingTransports =>
      BlePeripheralTransport.incomingTransports;

  /// Starts BLE scanning for devices advertising the nearby service UUID.
  Future<void> startScanning({
    String? serviceUuid,
  }) async {
    await stopScanning();
    _isScanning = true;

    final targetUuid = serviceUuid ?? kNearbyBleServiceUuid;

    UniversalBle.onScanResult = (BleDevice device) {
      if (!_isScanning) return;

      // Check if device matches target service UUID or has manufacturer data with Nearby company ID (0xFFFF)
      final hasService = device.services.any(
        (s) => BleUuidParser.compareStrings(s, targetUuid),
      );
      final hasMfg =
          device.manufacturerDataList.any((m) => m.companyId == 0xFFFF);

      // Filter out unrelated BLE devices in the environment
      if (!hasService && !hasMfg) return;

      String? peerId;
      final mfgList = device.manufacturerDataList;
      if (mfgList.isNotEmpty) {
        for (final mfg in mfgList) {
          if (mfg.payload.isNotEmpty) {
            if (mfg.payload[0] == 0x01 && mfg.payload.length > 1) {
              try {
                peerId = utf8.decode(mfg.payload.sublist(1), allowMalformed: true);
              } catch (_) {}
            } else {
              try {
                final decoded = utf8.decode(mfg.payload, allowMalformed: true);
                if (decoded.startsWith('{')) {
                  final map = jsonDecode(decoded) as Map<String, dynamic>;
                  peerId = map['id']?.toString();
                } else if (decoded.trim().isNotEmpty) {
                  peerId = decoded.trim();
                }
              } catch (_) {}
            }
          }
        }
      }

      peerId ??= device.deviceId;
      final name = device.name;
      final displayName = (name != null && name.trim().isNotEmpty)
          ? name.trim()
          : 'BLE Device (${device.deviceId.substring(0, min(6, device.deviceId.length))})';

      final peer = Peer(
        id: peerId,
        displayName: displayName,
        metadata: const {},
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

  /// Starts BLE peripheral advertising and sets up GATT server characteristics.
  Future<void> startAdvertising({
    required String peerId,
    required String displayName,
    Map<String, String> metadata = const {},
  }) async {
    await stopAdvertising();
    _isAdvertising = true;

    // Compact payload format: 1 byte version prefix (0x01) + utf8 peerId bytes
    final List<int> mfgPayload = [0x01, ...utf8.encode(peerId)];
    final Uint8List mfgData = Uint8List.fromList(mfgPayload);

    // Truncate name if necessary to fit legacy BLE advertising packet limits (31 bytes)
    final truncatedName = displayName.length > 14
        ? displayName.substring(0, 14)
        : displayName;

    try {
      // Ensure peripheral manager readiness state is ready before advertising
      int attempts = 0;
      while (attempts < 20) {
        final state = await UniversalBlePeripheral.getAvailabilityState();
        if (state == PeripheralReadinessState.ready) break;
        if (state == PeripheralReadinessState.unsupported ||
            state == PeripheralReadinessState.unauthorized) {
          break;
        }
        await Future.delayed(const Duration(milliseconds: 100));
        attempts++;
      }

      // Setup GATT Server handlers
      UniversalBlePeripheral.setWriteRequestHandlers((
        String deviceId,
        String characteristicId,
        int offset,
        Uint8List? value,
      ) {
        if (value != null && value.isNotEmpty) {
          if (BleUuidParser.compareStrings(characteristicId, kNearbyBleTxCharUuid)) {
            BlePeripheralTransport.handleIncomingWrite(deviceId, value);
          }
        }
        return PeripheralWriteRequestResult(status: 0);
      });

      UniversalBlePeripheral.setReadRequestHandlers((
        String deviceId,
        String characteristicId,
        int offset,
        Uint8List? value,
      ) {
        return PeripheralReadRequestResult(value: Uint8List(0), status: 0);
      });

      _connectionStateSub =
          UniversalBlePeripheral.connectionStateStream.listen((event) {
        if (!event.connected) {
          BlePeripheralTransport.handleDisconnected(event.deviceId);
        }
      });

      _mtuSub = UniversalBlePeripheral.mtuChangedStream.listen((event) {
        BlePeripheralTransport.handleMtuChanged(event.deviceId, event.mtu.toInt());
      });

      // Set up GATT Server service and characteristics
      final service = BlePeripheralService(
        uuid: kNearbyBleServiceUuid,
        characteristics: [
          BlePeripheralCharacteristic(
            uuid: kNearbyBleTxCharUuid,
            properties: [
              CharacteristicProperty.write,
              CharacteristicProperty.writeWithoutResponse,
            ],
            permissions: [
              PeripheralAttributePermission.writeable,
            ],
          ),
          BlePeripheralCharacteristic(
            uuid: kNearbyBleRxCharUuid,
            properties: [
              CharacteristicProperty.notify,
              CharacteristicProperty.read,
            ],
            permissions: [
              PeripheralAttributePermission.readable,
            ],
          ),
        ],
      );

      try {
        await UniversalBlePeripheral.clearServices();
        await UniversalBlePeripheral.addService(service);
      } catch (e) {
        debugPrint('UniversalBlePeripheral addService: $e');
      }

      // Peripheral advertising via universal_ble
      await UniversalBlePeripheral.startAdvertising(
        services: [kNearbyBleServiceUuid],
        localName: truncatedName,
        manufacturerData: ManufacturerData(0xFFFF, mfgData),
        platformConfig: PeripheralPlatformConfig(
          android: PeripheralAndroidOptions(
            addManufacturerDataInScanResponse: true,
          ),
        ),
      );
    } catch (e) {
      debugPrint('UniversalBlePeripheral startAdvertising error: $e');
    }
  }

  /// Stops BLE peripheral advertising.
  Future<void> stopAdvertising() async {
    if (_isAdvertising) {
      _isAdvertising = false;
      await _connectionStateSub?.cancel();
      _connectionStateSub = null;
      await _mtuSub?.cancel();
      _mtuSub = null;

      try {
        await UniversalBlePeripheral.stopAdvertising();
        await UniversalBlePeripheral.clearServices();
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

