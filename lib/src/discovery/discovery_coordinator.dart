import 'dart:async';
import '../models/nearby_options.dart';
import '../models/peer.dart';
import 'ble_discovery.dart';
import 'bonsoir_discovery.dart';

/// Aggregates and synchronizes discovery across Bonsoir (mDNS) and Universal BLE.
class DiscoveryCoordinator {
  final BonsoirDiscoveryService _bonsoir = BonsoirDiscoveryService();
  final BleDiscoveryService _ble = BleDiscoveryService();

  final Map<String, Peer> _discoveredPeers = {};
  Timer? _pruneTimer;

  final StreamController<List<Peer>> _peersController =
      StreamController<List<Peer>>.broadcast();
  final StreamController<Peer> _peerDiscoveredController =
      StreamController<Peer>.broadcast();
  final StreamController<String> _peerLostController =
      StreamController<String>.broadcast();

  Stream<List<Peer>> get peersStream => _peersController.stream;
  Stream<Peer> get onPeerDiscovered => _peerDiscoveredController.stream;
  Stream<String> get onPeerLost => _peerLostController.stream;

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
    _peersController.add([]);

    final strategy = options.strategy;

    // Listen to mDNS discoveries
    if (strategy == DiscoveryStrategy.hybrid || strategy == DiscoveryStrategy.mdnsOnly) {
      _bonsoir.onPeerFound.listen((peer) {
        _handlePeerFound(peer, options);
      });

      _bonsoir.onPeerLost.listen((peerId) {
        _handlePeerLost(peerId);
      });

      await _bonsoir.startBrowsing(serviceType: options.serviceId);
    }

    // Listen to BLE discoveries
    if (strategy == DiscoveryStrategy.hybrid || strategy == DiscoveryStrategy.bleOnly) {
      _ble.onPeerFound.listen((peer) {
        _handlePeerFound(peer, options);
      });

      _ble.onPeerLost.listen((peerId) {
        _handlePeerLost(peerId);
      });

      await _ble.startScanning();
    }

    // Periodically prune stale peers
    _pruneTimer = Timer.periodic(pruneInterval, (_) {
      final now = DateTime.now();
      final expiredPeerIds = <String>[];

      for (final entry in _discoveredPeers.entries) {
        if (now.difference(entry.value.lastSeen) > peerTimeout) {
          expiredPeerIds.add(entry.key);
        }
      }

      for (final id in expiredPeerIds) {
        _handlePeerLost(id);
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

    final existing = _discoveredPeers[incoming.id];
    Peer updated;

    if (existing == null) {
      updated = incoming;
      _discoveredPeers[incoming.id] = updated;
      _peerDiscoveredController.add(updated);
    } else {
      // Merge peer information (e.g. Upgrade to hybrid if seen across both BLE & mDNS)
      final isDifferentMedium = existing.discoveredVia != incoming.discoveredVia;
      final mergedMedium = isDifferentMedium ? DiscoveryMedium.hybrid : incoming.discoveredVia;

      updated = existing.copyWith(
        displayName: incoming.displayName.isNotEmpty ? incoming.displayName : existing.displayName,
        metadata: {...existing.metadata, ...incoming.metadata},
        discoveredVia: mergedMedium,
        ipAddress: incoming.ipAddress ?? existing.ipAddress,
        port: incoming.port ?? existing.port,
        bleDeviceId: incoming.bleDeviceId ?? existing.bleDeviceId,
        rssi: incoming.rssi ?? existing.rssi,
        lastSeen: DateTime.now(),
      );

      _discoveredPeers[incoming.id] = updated;
    }

    _peersController.add(_discoveredPeers.values.toList());
  }

  void _handlePeerLost(String peerId) {
    if (_discoveredPeers.remove(peerId) != null) {
      _peerLostController.add(peerId);
      _peersController.add(_discoveredPeers.values.toList());
    }
  }

  /// Stops discovery across all mediums.
  Future<void> stopDiscovery() async {
    _pruneTimer?.cancel();
    _pruneTimer = null;
    await _bonsoir.stopBrowsing();
    await _ble.stopScanning();
    _discoveredPeers.clear();
    _peersController.add([]);
  }

  /// Disposes coordinator resources.
  Future<void> dispose() async {
    await stopAdvertising();
    await stopDiscovery();
    await _bonsoir.dispose();
    await _ble.dispose();
    await _peersController.close();
    await _peerDiscoveredController.close();
    await _peerLostController.close();
  }
}
