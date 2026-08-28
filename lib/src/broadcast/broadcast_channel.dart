import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:universal_ble/universal_ble.dart';
import '../discovery/ble_discovery.dart';
import '../models/nearby_options.dart';
import '../models/peer.dart';
import '../transport/ble/ble_scan_dispatcher.dart';
import '../transport/ble_transport.dart';
import 'broadcast_packet.dart';

/// Configuration for a [BroadcastChannel].
class BroadcastChannelConfig {
  /// Unique identifier/namespace for this broadcast channel.
  final String channelId;

  /// Transport strategy (BLE-only, mDNS/Multicast-only, or Hybrid).
  final DiscoveryStrategy strategy;

  /// UDP multicast IP address (default: 239.255.0.1).
  final String multicastAddress;

  /// UDP multicast port (default: 9876).
  final int multicastPort;

  /// Custom BLE service UUID. If null, derived deterministically from [channelId].
  final String? bleServiceUuid;

  /// BLE manufacturer company ID (default: 0xFFFF).
  final int bleCompanyId;

  /// Optional prefix in local name for carrier fallback.
  final String? bleLocalNamePrefix;

  const BroadcastChannelConfig({
    required this.channelId,
    this.strategy = DiscoveryStrategy.hybrid,
    this.multicastAddress = '239.255.0.128',
    this.multicastPort = 53210,
    this.bleServiceUuid,
    this.bleCompanyId = 0xFFFF,
    this.bleLocalNamePrefix,
  });
}

/// Generic connectionless broadcast channel supporting high-frequency
/// UDP multicast and Bluetooth Low Energy advertisement updates.
class BroadcastChannel {
  final BroadcastChannelConfig config;
  final StreamController<BroadcastPacket> _packetController =
      StreamController<BroadcastPacket>.broadcast();

  bool _isBroadcasting = false;
  bool _isListening = false;

  // Network UDP Sockets
  final List<RawDatagramSocket> _sendSockets = [];
  RawDatagramSocket? _listenSocket;
  StreamSubscription<RawSocketEvent>? _listenSocketSub;

  // BLE state
  bool _bleScanning = false;
  bool _bleAdvertising = false;
  String? _targetBleUuid;

  BroadcastChannel({
    required this.config,
  }) {
    _targetBleUuid = config.bleServiceUuid ??
        BleDiscoveryService.generateServiceUuid(config.channelId);
  }

  bool get isBroadcasting => _isBroadcasting;
  bool get isListening => _isListening;
  Stream<BroadcastPacket> get stream => _packetController.stream;

  bool get _networkEnabled =>
      config.strategy == DiscoveryStrategy.hybrid ||
      config.strategy == DiscoveryStrategy.mdnsOnly;

  bool get _bleEnabled =>
      config.strategy == DiscoveryStrategy.hybrid ||
      config.strategy == DiscoveryStrategy.bleOnly;

  /// Starts broadcasting channel on enabled transports.
  Future<void> startBroadcasting() async {
    if (_isBroadcasting) return;
    _isBroadcasting = true;

    if (_networkEnabled) {
      await _setupSendSockets();
    }
  }

  /// Sends a raw data packet to all broadcast listeners across enabled transports.
  Future<void> send(Uint8List data, {String? localName}) async {
    if (!_isBroadcasting) {
      await startBroadcasting();
    }

    // 1. Network Multicast
    if (_networkEnabled && _sendSockets.isNotEmpty) {
      final targetGroup = InternetAddress(config.multicastAddress);
      for (final socket in _sendSockets) {
        try {
          socket.send(data, targetGroup, config.multicastPort);
        } catch (_) {}
      }
    }

    // 2. BLE Advertisement
    if (_bleEnabled) {
      try {
        await _updateBleAdvertisement(data, localName: localName);
      } catch (_) {}
    }
  }

  /// Stops broadcasting on all transports.
  Future<void> stopBroadcasting() async {
    _isBroadcasting = false;

    for (final socket in _sendSockets) {
      try {
        socket.close();
      } catch (_) {}
    }
    _sendSockets.clear();

    if (_bleAdvertising) {
      _bleAdvertising = false;
      try {
        await UniversalBlePeripheral.stopAdvertising();
      } catch (_) {}
    }
  }

  /// Starts listening for broadcast packets across enabled transports.
  Future<void> startListening() async {
    if (_isListening) return;
    _isListening = true;

    if (_networkEnabled) {
      await _setupListenSocket();
    }

    if (_bleEnabled) {
      await _setupBleScanning();
    }
  }

  /// Stops listening for broadcast packets.
  Future<void> stopListening() async {
    if (!_isListening) return;
    _isListening = false;

    if (_listenSocketSub != null) {
      await _listenSocketSub?.cancel();
      _listenSocketSub = null;
    }
    if (_listenSocket != null) {
      try {
        _listenSocket?.close();
      } catch (_) {}
      _listenSocket = null;
    }

    if (_bleScanning) {
      _bleScanning = false;
      await BleScanDispatcher.instance.removeListener(_handleBleScanResult);
    }
  }

  // --- Network Internal Implementation ---

  Future<void> _setupSendSockets() async {
    _sendSockets.clear();
    try {
      final interfaces = await NetworkInterface.list(
        includeLinkLocal: false,
        type: InternetAddressType.IPv4,
      );

      for (final iface in interfaces) {
        for (final addr in iface.addresses) {
          if (!addr.isLoopback) {
            try {
              final socket = await RawDatagramSocket.bind(
                addr,
                0,
                reuseAddress: true,
                reusePort: true,
              );
              socket.multicastHops = 1;
              socket.broadcastEnabled = true;
              _sendSockets.add(socket);
            } catch (_) {}
          }
        }
      }

      if (_sendSockets.isEmpty) {
        final fallback = await RawDatagramSocket.bind(
          InternetAddress.anyIPv4,
          0,
          reuseAddress: true,
          reusePort: true,
        );
        fallback.multicastHops = 1;
        fallback.broadcastEnabled = true;
        _sendSockets.add(fallback);
      }
    } catch (_) {}
  }

  Future<void> _setupListenSocket() async {
    try {
      final socket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        config.multicastPort,
        reuseAddress: true,
        reusePort: true,
      );

      final group = InternetAddress(config.multicastAddress);
      try {
        socket.joinMulticast(group);
      } catch (_) {}

      try {
        final interfaces = await NetworkInterface.list(
          includeLinkLocal: false,
          type: InternetAddressType.IPv4,
        );
        for (final iface in interfaces) {
          try {
            socket.joinMulticast(group, iface);
          } catch (_) {}
        }
      } catch (_) {}

      _listenSocket = socket;
      _listenSocketSub = socket.listen((event) {
        if (event == RawSocketEvent.read) {
          final datagram = socket.receive();
          if (datagram != null && datagram.data.isNotEmpty) {
            final packet = BroadcastPacket(
              data: datagram.data,
              senderId: '${datagram.address.address}:${datagram.port}',
              medium: DiscoveryMedium.mdns,
              receivedAt: DateTime.now(),
            );
            if (!_packetController.isClosed) {
              _packetController.add(packet);
            }
          }
        }
      });
    } catch (_) {}
  }

  // --- BLE Internal Implementation ---

  Future<void> _updateBleAdvertisement(Uint8List data, {String? localName}) async {
    final targetUuid = _targetBleUuid!;
    final truncatedName = localName != null && localName.length > 18
        ? localName.substring(0, 18)
        : localName;

    final advertiseLocalName =
        defaultTargetPlatform == TargetPlatform.android ? null : truncatedName;

    _bleAdvertising = true;
    await UniversalBlePeripheral.startAdvertising(
      services: [targetUuid],
      localName: advertiseLocalName,
      manufacturerData: ManufacturerData(config.bleCompanyId, data),
      platformConfig: PeripheralPlatformConfig(
        android: PeripheralAndroidOptions(
          addManufacturerDataInScanResponse: true,
        ),
      ),
    );
  }

  Future<void> _setupBleScanning() async {
    _bleScanning = true;
    final targetUuid = _targetBleUuid!;

    await BleScanDispatcher.instance.addListener(
      _handleBleScanResult,
      scanFilter: ScanFilter(withServices: [targetUuid]),
    );
  }

  void _handleBleScanResult(BleDevice device) {
    if (!_bleScanning || _targetBleUuid == null) return;
    final targetUuid = _targetBleUuid!;

    Uint8List? payload;

    // 1. Check manufacturer data
    for (final mfg in device.manufacturerDataList) {
      if (mfg.companyId == config.bleCompanyId && mfg.payload.isNotEmpty) {
        payload = mfg.payload;
        break;
      }
    }

    // 2. Check local name payload fallback
    if (payload == null && config.bleLocalNamePrefix != null && device.name != null) {
      if (device.name!.startsWith(config.bleLocalNamePrefix!)) {
        final raw = device.name!.substring(config.bleLocalNamePrefix!.length);
        try {
          payload = base64Url.decode(base64.normalize(raw));
        } catch (_) {}
      }
    }

    // 3. Check service match
    final matchesService = device.services.any(
      (s) => BleUuidParser.compareStrings(s, targetUuid),
    );

    if (payload != null || matchesService) {
      final packet = BroadcastPacket(
        data: payload ?? Uint8List(0),
        senderId: device.deviceId,
        medium: DiscoveryMedium.ble,
        receivedAt: DateTime.now(),
        deviceName: device.name,
        rssi: device.rssi,
      );
      if (!_packetController.isClosed) {
        _packetController.add(packet);
      }
    }
  }

  /// Disposes resources.
  Future<void> dispose() async {
    await stopBroadcasting();
    await stopListening();
    await _packetController.close();
  }
}
