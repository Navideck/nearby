import 'dart:async';
import '../models/nearby_options.dart';
import '../models/peer.dart';
import '../transport/ble_transport.dart';
import 'ble_discovery.dart';
import 'bonsoir_discovery.dart';

/// Aggregates and synchronizes discovery across Bonsoir (mDNS) and Universal BLE.
class DiscoveryCoordinator {
  final BonsoirDiscoveryService _bonsoir = BonsoirDiscoveryService();
  final BleDiscoveryService _ble = BleDiscoveryService();

  final Map<String, Peer> _discoveredPeers = {};
  final Map<String, Set<DiscoveryMedium>> _peerActiveMediums = {};
  Timer? _pruneTimer;

  StreamSubscription<Peer>? _bonsoirFoundSub;
  StreamSubscription<String>? _bonsoirLostSub;
  StreamSubscription<Peer>? _bleFoundSub;
  StreamSubscription<String>? _bleLostSub;

  final StreamController<List<Peer>> _peersController =
      StreamController<List<Peer>>.broadcast();
  final StreamController<Peer> _peerDiscoveredController =
      StreamController<Peer>.broadcast();
  final StreamController<String> _peerLostController =
      StreamController<String>.broadcast();

  Stream<List<Peer>> get peersStream => _peersController.stream;
  Stream<Peer> get onPeerDiscovered => _peerDiscoveredController.stream;
  Stream<String> get onPeerLost => _peerLostController.stream;

  /// Stream of incoming client transports connected via BLE to our GATT server.
  Stream<BlePeripheralTransport> get incomingBleTransports =>
      _ble.incomingTransports;

  List<Peer> get currentPeers => List.unmodifiable(_discoveredPeers.values);

  /// Starts advertising on selected transport mediums based on [AdvertisingOptions].
  Future<void> startAdvertising({
    required String peerId,
    required String displayName,
    required AdvertisingOptions options,
    required int tcpPort,
  }) async {
    final strategy = options.strategy;

    if (strategy == DiscoveryStrategy.hybrid || strategy == DiscoveryStrategy.mdnsOnly) {
      await _bonsoir.startBroadcasting(
        serviceType: options.serviceId,
        peerId: peerId,
        displayName: displayName,
        port: tcpPort,
        metadata: options.metadata,
      );
    }

    if (strategy == DiscoveryStrategy.hybrid || strategy == DiscoveryStrategy.bleOnly) {
      await _ble.startAdvertising(
        peerId: peerId,
        displayName: displayName,
        serviceId: options.serviceId,
        metadata: options.metadata,
      );
    }
  }

  /// Stops advertising on all mediums.
  Future<void> stopAdvertising() async {
    await _bonsoir.stopBroadcasting();
    await _ble.stopAdvertising();
  }

  /// Starts discovery on selected transport mediums based on [DiscoveryOptions].
  Future<void> startDiscovery({
    required DiscoveryOptions options,
    Duration pruneInterval = const Duration(seconds: 10),
    Duration peerTimeout = const Duration(seconds: 25),
  }) async {
    await stopDiscovery();
    _discoveredPeers.clear();
    _peerActiveMediums.clear();
    _peersController.add([]);

    final strategy = options.strategy;

    // Listen to mDNS discoveries
    if (strategy == DiscoveryStrategy.hybrid || strategy == DiscoveryStrategy.mdnsOnly) {
      _bonsoirFoundSub = _bonsoir.onPeerFound.listen((peer) {
        _handlePeerFound(peer, options);
      });

      _bonsoirLostSub = _bonsoir.onPeerLost.listen((peerId) {
        _handlePeerMediumLost(peerId, DiscoveryMedium.mdns);
      });

      await _bonsoir.startBrowsing(serviceType: options.serviceId);
    }

    // Listen to BLE discoveries
    if (strategy == DiscoveryStrategy.hybrid || strategy == DiscoveryStrategy.bleOnly) {
      _bleFoundSub = _ble.onPeerFound.listen((peer) {
        _handlePeerFound(peer, options);
      });

      _bleLostSub = _ble.onPeerLost.listen((peerId) {
        _handlePeerMediumLost(peerId, DiscoveryMedium.ble);
      });

      await _ble.startScanning(serviceId: options.serviceId);
    }

    // Periodically prune stale BLE-only peers that timed out
    _pruneTimer = Timer.periodic(pruneInterval, (_) {
      final now = DateTime.now();
      final expiredPeerIds = <String>[];

      for (final entry in _discoveredPeers.entries) {
        final mediums = _peerActiveMediums[entry.key] ?? {};
        // Only prune peers whose active medium contains BLE and timed out
        if (mediums.contains(DiscoveryMedium.ble) &&
            !mediums.contains(DiscoveryMedium.mdns) &&
            now.difference(entry.value.lastSeen) > peerTimeout) {
          expiredPeerIds.add(entry.key);
        }
      }

      for (final id in expiredPeerIds) {
        _handlePeerMediumLost(id, DiscoveryMedium.ble);
      }
    });
  }

  void _handlePeerFound(Peer incoming, DiscoveryOptions options) {
    // Check metadata filter if configured
    if (options.metadataFilter != null) {
      for (final filterEntry in options.metadataFilter!.entries) {
        if (incoming.metadata[filterEntry.key] != filterEntry.value) {
          return; // Filter mismatch
        }
      }
    }

    final mediums = _peerActiveMediums.putIfAbsent(incoming.id, () => <DiscoveryMedium>{});
    mediums.add(incoming.discoveredVia);

    final existing = _discoveredPeers[incoming.id];
    final mergedMedium = mediums.length > 1 ? DiscoveryMedium.hybrid : incoming.discoveredVia;

    Peer updated;
    if (existing == null) {
      updated = incoming.copyWith(discoveredVia: mergedMedium);
      _discoveredPeers[incoming.id] = updated;
      _peerDiscoveredController.add(updated);
    } else {
      updated = existing.copyWith(
        displayName: incoming.displayName.isNotEmpty ? incoming.displayName : existing.displayName,
        metadata: {...existing.metadata, ...incoming.metadata},
        discoveredVia: mergedMedium,
        ipAddress: incoming.ipAddress ?? existing.ipAddress,
        port: incoming.port ?? existing.port,
        bleDeviceId: incoming.bleDeviceId ?? existing.bleDeviceId,
        serviceUuid: incoming.serviceUuid ?? existing.serviceUuid,
        rssi: incoming.rssi ?? existing.rssi,
        lastSeen: DateTime.now(),
      );

      _discoveredPeers[incoming.id] = updated;
    }

    _peersController.add(_discoveredPeers.values.toList());
  }

  void _handlePeerMediumLost(String peerId, DiscoveryMedium lostMedium) {
    final mediums = _peerActiveMediums[peerId];
    if (mediums != null) {
      mediums.remove(lostMedium);

      if (mediums.isNotEmpty) {
        // Downgrade hybrid peer to remaining medium
        final remainingMedium = mediums.first;
        final existing = _discoveredPeers[peerId];
        if (existing != null) {
          _discoveredPeers[peerId] = existing.copyWith(
            discoveredVia: remainingMedium,
          );
          _peersController.add(_discoveredPeers.values.toList());
        }
        return;
      }
    }

    // No active mediums left; fully remove peer
    _peerActiveMediums.remove(peerId);
    if (_discoveredPeers.remove(peerId) != null) {
      _peerLostController.add(peerId);
      _peersController.add(_discoveredPeers.values.toList());
    }
  }

  /// Stops discovery across all mediums.
  Future<void> stopDiscovery() async {
    _pruneTimer?.cancel();
    _pruneTimer = null;

    await _bonsoirFoundSub?.cancel();
    _bonsoirFoundSub = null;
    await _bonsoirLostSub?.cancel();
    _bonsoirLostSub = null;

    await _bleFoundSub?.cancel();
    _bleFoundSub = null;
    await _bleLostSub?.cancel();
    _bleLostSub = null;

    await _bonsoir.stopBrowsing();
    await _ble.stopScanning();
  }

  /// Disposes coordinator resources.
  Future<void> dispose() async {
    await stopAdvertising();
    await stopDiscovery();
    _discoveredPeers.clear();
    _peerActiveMediums.clear();
    await _peerDiscoveredController.close();
    await _peerLostController.close();
    await _peersController.close();
    await _bonsoir.dispose();
    await _ble.dispose();
  }
}
