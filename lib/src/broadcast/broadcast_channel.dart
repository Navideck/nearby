import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:universal_ble/universal_ble.dart';

import '../models/nearby_options.dart';
import '../models/peer.dart';
import '../transport/ble/ble_scan_dispatcher.dart';
import 'broadcast_packet.dart';
import 'broadcast_wire.dart';
import 'multicast_transport.dart';

class BroadcastChannelConfig {
  final String channelId;
  final DiscoveryStrategy strategy;
  final String multicastAddress;
  final int multicastPort;
  final int bleCompanyId;
  const BroadcastChannelConfig({
    required this.channelId,
    this.strategy = DiscoveryStrategy.hybrid,
    this.multicastAddress = '239.255.0.128',
    this.multicastPort = 53210,
    this.bleCompanyId = 0xFFFF,
  });
}

class BroadcastFailure {
  final DiscoveryMedium medium;
  final Object error;
  const BroadcastFailure(this.medium, this.error);
}

/// Opaque connectionless bytes, with identical logical identity on both media.
/// BLE supports at most 10 application bytes across advertising platforms.
class BroadcastChannel {
  final BroadcastChannelConfig config;
  final String senderId;
  final String? displayName;
  late final _wire = BroadcastWire(config.channelId);
  late final _network = MulticastTransport(
    config.multicastAddress,
    config.multicastPort,
  );
  final _packets = StreamController<BroadcastPacket>.broadcast();
  final _errors = StreamController<BroadcastFailure>.broadcast();
  bool _isBroadcasting = false, _isListening = false, _disposed = false;
  bool _bleScanning = false, _bleAdvertising = false, _bleUnavailable = false;
  Future<void>? _startingBroadcast, _startingListen, _bleSending;
  StreamSubscription<BlePeripheralAdvertisingStateChanged>? _advertisingState;

  BroadcastChannel({required this.config, String? senderId, this.displayName})
    : senderId =
          senderId ??
          List.generate(
            16,
            (_) => Random.secure().nextInt(256),
          ).map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  static String fingerprint(String senderId) =>
      BroadcastWire.senderFingerprint(senderId);
  bool get isBroadcasting => _isBroadcasting;
  bool get isListening => _isListening;
  Stream<BroadcastPacket> get stream => _packets.stream;
  Stream<BroadcastFailure> get errors => _errors.stream;
  bool get _networkEnabled => config.strategy != DiscoveryStrategy.bleOnly;
  bool get _bleEnabled => config.strategy != DiscoveryStrategy.mdnsOnly;

  void _fail(DiscoveryMedium medium, Object error) {
    if (!_errors.isClosed) _errors.add(BroadcastFailure(medium, error));
  }

  Future<void> startBroadcasting() async {
    if (_disposed) throw StateError('BroadcastChannel is disposed');
    if (_isBroadcasting) return _startingBroadcast;
    _isBroadcasting = true;
    _bleUnavailable = false;
    _startingBroadcast = _startBroadcasting();
    await _startingBroadcast;
  }

  Future<void> _startBroadcasting() async {
    if (_bleEnabled) {
      _advertisingState = UniversalBlePeripheral.advertisingStateStream.listen((
        event,
      ) {
        if (event.state == PeripheralAdvertisingState.error) {
          _fail(
            DiscoveryMedium.ble,
            StateError(event.error ?? 'BLE advertising failed'),
          );
        }
      });
    }
    if (_networkEnabled) {
      try {
        await _network.startSending();
      } catch (e) {
        _fail(DiscoveryMedium.mdns, e);
      }
    }
  }

  /// Attributes and localName are network metadata, not BLE carrier bytes.
  /// A busy BLE radio skips a tick instead of queuing stale payloads.
  Future<void> send(
    Uint8List data, {
    String? localName,
    Map<String, String>? attributes,
  }) async {
    if (!_isBroadcasting) await startBroadcasting();
    await _startingBroadcast;
    if (!_isBroadcasting) return;
    if (_networkEnabled) {
      final bytes = _wire.encodeNetwork(
        data,
        senderId,
        localName ?? displayName,
        attributes ?? {},
      );
      if (!_network.send(bytes)) {
        _fail(DiscoveryMedium.mdns, StateError('No datagram sent'));
      }
    }
    if (!_bleEnabled || _bleUnavailable || _bleSending != null) return;
    _bleSending = _sendBle(_wire.encode(data, senderId));
    try {
      await _bleSending;
    } finally {
      _bleSending = null;
    }
  }

  Future<void> _sendBle(Uint8List bytes) async {
    try {
      final name = _wire.localName(bytes);
      final readiness = await UniversalBlePeripheral.getAvailabilityState();
      if (!_isBroadcasting) return;
      if (readiness == PeripheralReadinessState.unsupported ||
          readiness == PeripheralReadinessState.unauthorized) {
        _bleUnavailable = true;
        throw StateError('BLE advertising $readiness');
      }
      if (readiness != PeripheralReadinessState.ready) return;
      if (_bleAdvertising) await UniversalBlePeripheral.stopAdvertising();
      _bleAdvertising = false;
      if (!_isBroadcasting) return;
      final apple =
          defaultTargetPlatform == TargetPlatform.iOS ||
          defaultTargetPlatform == TargetPlatform.macOS;
      await UniversalBlePeripheral.startAdvertising(
        services: const [],
        localName: apple ? name : null,
        manufacturerData: apple
            ? null
            : ManufacturerData(config.bleCompanyId, bytes),
        platformConfig: PeripheralPlatformConfig(
          android: PeripheralAndroidOptions(
            addManufacturerDataInScanResponse: false,
          ),
        ),
      );
      _bleAdvertising = true;
    } catch (e) {
      _fail(DiscoveryMedium.ble, e);
    }
  }

  Future<void> stopBroadcasting() async {
    _isBroadcasting = false;
    await _startingBroadcast;
    await _bleSending;
    await _network.stopSending();
    if (_bleAdvertising) {
      _bleAdvertising = false;
      try {
        await UniversalBlePeripheral.stopAdvertising();
      } catch (e) {
        _fail(DiscoveryMedium.ble, e);
      }
    }
    await _advertisingState?.cancel();
    _advertisingState = null;
  }

  Future<void> startListening() async {
    if (_disposed) throw StateError('BroadcastChannel is disposed');
    if (_isListening) return _startingListen;
    _isListening = true;
    _startingListen = _startListening();
    await _startingListen;
  }

  Future<void> _startListening() async {
    var available = false;
    await Future.wait([
      if (_networkEnabled)
        () async {
          try {
            await _network.startListening((datagram, receivedAt) {
              if (!_isListening) return;
              final envelope = _wire.decodeNetwork(datagram.data);
              if (envelope == null) return;
              final payload = _wire.decode(envelope.data)!;
              _packets.add(
                BroadcastPacket(
                  data: payload.data,
                  senderId: payload.senderId,
                  fullSenderId: envelope.attributes['nearby.sender'],
                  deviceName: envelope.attributes['nearby.name'],
                  address: datagram.address.address,
                  medium: DiscoveryMedium.mdns,
                  receivedAt: receivedAt,
                  attributes: Map.unmodifiable(
                    Map.of(envelope.attributes)
                      ..removeWhere((key, _) => key.startsWith('nearby.')),
                  ),
                ),
              );
            });
            available = true;
          } catch (e) {
            _fail(DiscoveryMedium.mdns, e);
          }
        }(),
      if (_bleEnabled)
        () async {
          try {
            _bleScanning = true;
            await BleScanDispatcher.instance.addListener(_handleBleScanResult);
            available = true;
          } catch (e) {
            _bleScanning = false;
            _fail(DiscoveryMedium.ble, e);
          }
        }(),
    ]);
    if (!available) {
      _isListening = false;
      throw StateError('No Nearby listening transport available');
    }
  }

  void _handleBleScanResult(BleDevice device) {
    if (!_bleScanning || !_isListening) return;
    final carriers = <Uint8List>[
      for (final data in device.manufacturerDataList)
        if (data.companyId == config.bleCompanyId) data.payload,
      ?_wire.decodeLocalName(device.name),
    ];
    for (final bytes in carriers) {
      if (bytes.length > 18) continue;
      final payload = _wire.decode(bytes);
      if (payload == null) continue;
      _packets.add(
        BroadcastPacket(
          data: payload.data,
          senderId: payload.senderId,
          medium: DiscoveryMedium.ble,
          rssi: device.rssi,
          receivedAt:
              device.timestampMicrosecondsDateTime ??
              device.timestampDateTime ??
              DateTime.now(),
        ),
      );
      return;
    }
  }

  Future<void> stopListening() async {
    _isListening = false;
    try {
      await _startingListen;
    } catch (_) {
      /* Failure already reported. */
    }
    await _network.stopListening();
    if (_bleScanning) {
      _bleScanning = false;
      await BleScanDispatcher.instance.removeListener(_handleBleScanResult);
    }
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await stopBroadcasting();
    await stopListening();
    await _packets.close();
    await _errors.close();
  }
}
