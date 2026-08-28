import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:universal_ble/universal_ble.dart';
import '../models/peer.dart';
import '../transport/ble/ble_scan_dispatcher.dart';
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

  String? _currentTargetUuid;
  String? _currentServiceId;

  bool get isScanning => _isScanning;
  bool get isAdvertising => _isAdvertising;

  Stream<Peer> get onPeerFound => _peerFoundController.stream;
  Stream<String> get onPeerLost => _peerLostController.stream;

  /// Stream of incoming client transports connected to our GATT Server.
  Stream<BlePeripheralTransport> get incomingTransports =>
      BlePeripheralTransport.incomingTransports;

  /// Starts BLE scanning for devices advertising the nearby service UUID.
  Future<void> startScanning({
    String? serviceUuid,
    String? serviceId,
  }) async {
    await stopScanning();
    _isScanning = true;
    _currentServiceId = serviceId;

    _currentTargetUuid = serviceUuid ??
        (serviceId != null
            ? generateServiceUuid(serviceId)
            : kNearbyBleServiceUuid);

    await BleScanDispatcher.instance.addListener(
      _handleScanResult,
    );
  }

  void _handleScanResult(BleDevice device) {
    if (!_isScanning || _currentTargetUuid == null) return;
    final targetUuid = _currentTargetUuid!;
    final serviceId = _currentServiceId;

    // Check if device matches target service UUID or has manufacturer data with Nearby company ID (0xFFFF)
    final hasService = device.services.any(
      (s) => BleUuidParser.compareStrings(s, targetUuid),
    );
    final hasMfg =
        device.manufacturerDataList.any((m) => m.companyId == 0xFFFF);

    // Filter out unrelated BLE devices in the environment
    if (!hasService && !hasMfg) return;

    String? peerId;
    String? advertisedSid;
    Map<String, String> metadata = const {};
    final mfgList = device.manufacturerDataList;
    if (mfgList.isNotEmpty) {
      for (final mfg in mfgList) {
        if (mfg.payload.isNotEmpty) {
          try {
            final decoded = utf8.decode(mfg.payload, allowMalformed: true);
            if (decoded.startsWith('{')) {
              final map = jsonDecode(decoded) as Map<String, dynamic>;
              peerId = map['id']?.toString();
              advertisedSid = map['sid']?.toString();
              if (map['meta'] is Map) {
                metadata = (map['meta'] as Map).map(
                  (k, v) => MapEntry(k.toString(), v.toString()),
                );
              }
            } else if (mfg.payload[0] == 0x01 && mfg.payload.length > 1) {
              peerId = utf8.decode(mfg.payload.sublist(1), allowMalformed: true);
            } else if (decoded.trim().isNotEmpty) {
              peerId = decoded.trim();
            }
          } catch (_) {}
        }
      }
    }

    // Enforce serviceId filtering if configured
    if (serviceId != null && advertisedSid != null && advertisedSid != serviceId) {
      return;
    }

    peerId ??= device.deviceId;
    final name = device.name;
    final displayName = (name != null && name.trim().isNotEmpty)
        ? name.trim()
        : 'BLE Device (${device.deviceId.substring(0, min(6, device.deviceId.length))})';

    final peer = Peer(
      id: peerId,
      displayName: displayName,
      metadata: metadata,
      discoveredVia: DiscoveryMedium.ble,
      bleDeviceId: device.deviceId,
      serviceUuid: targetUuid,
      rssi: device.rssi,
      lastSeen: DateTime.now(),
    );

    if (!_peerFoundController.isClosed) {
      _peerFoundController.add(peer);
    }
  }

  /// Stops BLE scanning.
  Future<void> stopScanning() async {
    if (_isScanning) {
      _isScanning = false;
      await BleScanDispatcher.instance.removeListener(_handleScanResult);
    }
  }

  /// Generates a deterministic 128-bit UUID from a service namespace string.
  static String generateServiceUuid(String serviceId) {
    if (serviceId == 'nearby-default' || serviceId.isEmpty) {
      return kNearbyBleServiceUuid;
    }
    final digest = sha256.convert(utf8.encode(serviceId)).bytes;
    final hex = digest.take(16).map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20, 32)}'.toLowerCase();
  }

  StreamSubscription? _advertisingStateSub;

  /// Encodes manufacturer data payload for BLE advertising.
  /// Uses JSON if it fits within the 27-byte limit (31 bytes max legacy scan response - 4 bytes header),
  /// preserving serviceId and metadata for discovery filtering.
  /// Falls back to a compact binary payload (`0x01` + bounded peerId) if the JSON exceeds 27 bytes.
  static Uint8List createManufacturerPayload({
    required String peerId,
    String? serviceId,
    Map<String, String> metadata = const {},
  }) {
    final payloadMap = {
      'id': peerId,
      if (serviceId != null && serviceId.isNotEmpty) 'sid': serviceId,
      if (metadata.isNotEmpty) 'meta': metadata,
    };
    final jsonBytes = Uint8List.fromList(utf8.encode(jsonEncode(payloadMap)));
    if (jsonBytes.length <= 27) {
      return jsonBytes;
    }

    final boundedPeerId =
        peerId.length > 26 ? peerId.substring(0, 26) : peerId;
    return Uint8List.fromList([0x01, ...utf8.encode(boundedPeerId)]);
  }

  /// Starts BLE peripheral advertising and sets up GATT server characteristics.
  Future<void> startAdvertising({
    required String peerId,
    required String displayName,
    String? serviceUuid,
    String? serviceId,
    Map<String, String> metadata = const {},
  }) async {
    await stopAdvertising();
    _isAdvertising = true;

    final targetUuid = serviceUuid ??
        (serviceId != null
            ? generateServiceUuid(serviceId)
            : kNearbyBleServiceUuid);

    // Manufacturer payload capped at 27 bytes to strictly avoid BLE scan response overflow
    final mfgData = createManufacturerPayload(
      peerId: peerId,
      serviceId: serviceId,
      metadata: metadata,
    );

    // Truncate name if necessary to fit BLE advertising packet limits
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

      _advertisingStateSub =
          UniversalBlePeripheral.advertisingStateStream.listen((event) {
        if (event.state == PeripheralAdvertisingState.error) {
          debugPrint('UniversalBle BLE Advertising Error: ${event.error}');
        }
      });

      // Set up GATT Server service and characteristics
      final service = BlePeripheralService(
        uuid: targetUuid,
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

      await UniversalBlePeripheral.clearServices();
      await UniversalBlePeripheral.addService(service);

      final advertiseLocalName =
          defaultTargetPlatform == TargetPlatform.android ? null : truncatedName;

      await UniversalBlePeripheral.startAdvertising(
        services: [targetUuid],
        localName: advertiseLocalName,
        manufacturerData: ManufacturerData(0xFFFF, mfgData),
        platformConfig: PeripheralPlatformConfig(
          android: PeripheralAndroidOptions(
            addManufacturerDataInScanResponse: true,
          ),
        ),
      );
    } catch (e) {
      await stopAdvertising();
      rethrow;
    }
  }

  /// Stops BLE peripheral advertising.
  Future<void> stopAdvertising() async {
    _isAdvertising = false;
    await _connectionStateSub?.cancel();
    _connectionStateSub = null;
    await _mtuSub?.cancel();
    _mtuSub = null;
    await _advertisingStateSub?.cancel();
    _advertisingStateSub = null;

    try {
      await UniversalBlePeripheral.stopAdvertising();
      await UniversalBlePeripheral.clearServices();
    } catch (_) {}
  }

  /// Disposes resources.
  Future<void> dispose() async {
    await stopScanning();
    await stopAdvertising();
    await _peerFoundController.close();
    await _peerLostController.close();
  }
}
