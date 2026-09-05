import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:universal_ble/universal_ble.dart';

import '../transport/ble/ble_scan_dispatcher.dart';
import 'broadcast_packet.dart';
import 'broadcast_wire.dart';
import 'multicast_transport.dart';

/// Transports used by a broadcast channel.
enum DiscoveryStrategy {
  hybrid,
  networkOnly,
  bleOnly;

  @Deprecated('Use DiscoveryStrategy.networkOnly instead')
  static const DiscoveryStrategy mdnsOnly = DiscoveryStrategy.networkOnly;
}

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
  bool _bluetoothEnablePrompted = false;
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
  bool get isBleAdvertising => _bleAdvertising;
  bool get isListening => _isListening;
  Stream<BroadcastPacket> get stream => _packets.stream;
  Stream<BroadcastFailure> get errors => _errors.stream;
  bool get _networkEnabled => config.strategy != DiscoveryStrategy.bleOnly;
  bool get _bleEnabled => config.strategy != DiscoveryStrategy.networkOnly;

  /// Returns true if at least one non-loopback IPv4 network interface is available
  /// for multicast transmission (excluding common cellular interface names).
  static Future<bool> isNetworkAvailable() =>
      MulticastTransport.isNetworkAvailable();

  /// Returns true if BLE peripheral advertising is ready.
  static Future<bool> isBleAvailable() async {
    try {
      final readiness = await UniversalBlePeripheral.getAvailabilityState();
      return readiness == PeripheralReadinessState.ready;
    } catch (_) {
      return false;
    }
  }

  /// Checks whether at least one configured transport (Network or BLE) is available.
  Future<bool> hasAvailableTransport({
    Future<bool> Function()? isNetworkAvailable,
    Future<bool> Function()? isBleAvailable,
  }) async {
    if (_networkEnabled &&
        await (isNetworkAvailable?.call() ??
            BroadcastChannel.isNetworkAvailable())) {
      return true;
    }
    if (_bleEnabled &&
        await (isBleAvailable?.call() ?? BroadcastChannel.isBleAvailable())) {
      return true;
    }
    return false;
  }

  void _fail(DiscoveryMedium medium, Object error) {
    if (!_errors.isClosed) _errors.add(BroadcastFailure(medium, error));
  }

  void _promptEnableBluetoothIfNeeded() {
    if (defaultTargetPlatform == TargetPlatform.android &&
        !_bluetoothEnablePrompted) {
      _bluetoothEnablePrompted = true;
      unawaited(UniversalBle.enableBluetooth().catchError((_) => false));
    }
  }

  Future<void> startBroadcasting() async {
    if (_disposed) throw StateError('BroadcastChannel is disposed');
    if (_isBroadcasting) return _startingBroadcast;
    _isBroadcasting = true;
    _bleUnavailable = false;
    _bluetoothEnablePrompted = false;
    _startingBroadcast = _startBroadcasting();
    await _startingBroadcast;
  }

  Future<void> _startBroadcasting() async {
    if (_bleEnabled) {
      _advertisingState = UniversalBlePeripheral.advertisingStateStream.listen((
        event,
      ) {
        if (event.state == PeripheralAdvertisingState.error) {
          _bleAdvertising = false;
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
        _fail(DiscoveryMedium.network, e);
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
      _sendNetwork(data, localName: localName, attributes: attributes);
    }
    if (!_bleEnabled || _bleUnavailable || _bleSending != null) return;
    _bleSending = _sendBle(_wire.encode(data, senderId));
    try {
      await _bleSending;
    } finally {
      _bleSending = null;
    }
  }

  /// Sends a packet over the network transport only.
  ///
  /// This is useful for control traffic that has no BLE representation, such
  /// as a response to a connectionless broadcast. The packet keeps the same
  /// channel and sender framing as [send].
  Future<void> sendNetwork(
    Uint8List data, {
    String? localName,
    Map<String, String>? attributes,
  }) async {
    if (_disposed) throw StateError('BroadcastChannel is disposed');
    if (!_networkEnabled) {
      throw StateError('Network transport is disabled');
    }
    if (!_isBroadcasting) await startBroadcasting();
    await _startingBroadcast;
    if (!_isBroadcasting) return;
    _sendNetwork(data, localName: localName, attributes: attributes);
  }

  void _sendNetwork(
    Uint8List data, {
    String? localName,
    Map<String, String>? attributes,
  }) {
    final bytes = _wire.encodeNetwork(
      data,
      senderId,
      localName ?? displayName,
      attributes ?? {},
    );
    if (!_network.send(bytes)) {
      _fail(DiscoveryMedium.network, StateError('No datagram sent'));
    }
  }

  bool _canAdvertise(PeripheralReadinessState readiness) {
    switch (readiness) {
      case PeripheralReadinessState.ready:
        _bleUnavailable = false;
        _bluetoothEnablePrompted = false;
        return true;
      case PeripheralReadinessState.bluetoothOff:
        _bleAdvertising = false;
        _promptEnableBluetoothIfNeeded();
        return false;
      case PeripheralReadinessState.unknown:
        _bleAdvertising = false;
        return false;
      case PeripheralReadinessState.unauthorized:
        throw StateError('BLE advertising $readiness');
      case PeripheralReadinessState.unsupported:
        _bleAdvertising = false;
        if (defaultTargetPlatform != TargetPlatform.android) {
          _bleUnavailable = true;
          throw StateError('BLE advertising $readiness');
        }
        return !_bluetoothEnablePrompted;
    }
  }

  void _handleBleSendError(Object error) {
    final message = error.toString().toLowerCase();
    final stateMessage = error is StateError ? error.message.toLowerCase() : '';
    if (stateMessage.contains('unsupported') ||
        message.contains('not supported') ||
        message.contains('unsupported')) {
      _bleUnavailable = true;
    } else if (message.contains('bluetooth is not enabled') ||
        message.contains('bluetoothoff')) {
      _bleAdvertising = false;
      _promptEnableBluetoothIfNeeded();
    }
    _fail(DiscoveryMedium.ble, error);
  }

  Future<void> _sendBle(Uint8List bytes) async {
    try {
      final readiness = await UniversalBlePeripheral.getAvailabilityState();
      if (!_isBroadcasting || !_canAdvertise(readiness)) return;
      if (_bleAdvertising) await UniversalBlePeripheral.stopAdvertising();
      _bleAdvertising = false;
      if (!_isBroadcasting) return;
      final apple =
          defaultTargetPlatform == TargetPlatform.iOS ||
          defaultTargetPlatform == TargetPlatform.macOS;
      await UniversalBlePeripheral.startAdvertising(
        services: const [],
        localName: apple ? _wire.localName(bytes) : null,
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
      _handleBleSendError(e);
    }
  }

  Future<void> stopBroadcasting() async {
    _isBroadcasting = false;
    _bluetoothEnablePrompted = false;
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

  /// Starts receiving through [strategy], constrained by [config].
  ///
  /// This lets a hybrid channel listen on one transport while continuing to
  /// broadcast on both.
  Future<void> startListening({DiscoveryStrategy? strategy}) async {
    if (_disposed) throw StateError('BroadcastChannel is disposed');
    if (_isListening) return _startingListen;
    _isListening = true;
    _startingListen = _startListening(strategy ?? config.strategy);
    await _startingListen;
  }

  Future<void> _startListening(DiscoveryStrategy strategy) async {
    var available = false;
    await Future.wait([
      if (_networkEnabled && strategy != DiscoveryStrategy.bleOnly)
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
                  medium: DiscoveryMedium.network,
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
            _fail(DiscoveryMedium.network, e);
          }
        }(),
      if (_bleEnabled && strategy != DiscoveryStrategy.networkOnly)
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
