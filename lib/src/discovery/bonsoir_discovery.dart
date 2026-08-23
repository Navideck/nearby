import 'dart:async';
import 'package:bonsoir/bonsoir.dart';
import '../models/peer.dart';

/// Bonsoir (mDNS / Bonjour) implementation for Local Network broadcasting and peer browsing.
class BonsoirDiscoveryService {
  BonsoirBroadcast? _broadcast;
  BonsoirDiscovery? _discovery;
  StreamSubscription<BonsoirDiscoveryEvent>? _discoverySubscription;

  final StreamController<Peer> _peerFoundController =
      StreamController<Peer>.broadcast();
  final StreamController<String> _peerLostController =
      StreamController<String>.broadcast();

  Stream<Peer> get onPeerFound => _peerFoundController.stream;
  Stream<String> get onPeerLost => _peerLostController.stream;

  /// Starts broadcasting this device over mDNS / Bonjour.
  Future<void> startBroadcasting({
    required String serviceType,
    required String peerId,
    required String displayName,
    required int port,
    Map<String, String> metadata = const {},
  }) async {
    await stopBroadcasting();

    final attributes = <String, String>{
      'id': peerId,
      'name': displayName,
      ...metadata,
    };

    final formattedType = serviceType.startsWith('_')
        ? (serviceType.endsWith('._tcp') ? serviceType : '$serviceType._tcp')
        : '_$serviceType._tcp';

    final service = BonsoirService(
      name: '$displayName-$peerId',
      type: formattedType,
      port: port,
      attributes: attributes,
    );

    _broadcast = BonsoirBroadcast(service: service);
    await _broadcast!.start();
  }

  /// Stops broadcasting this device.
  Future<void> stopBroadcasting() async {
    if (_broadcast != null) {
      await _broadcast!.stop();
      _broadcast = null;
    }
  }

  /// Starts scanning / browsing for nearby Bonsoir services.
  Future<void> startBrowsing({
    required String serviceType,
  }) async {
    await stopBrowsing();

    final formattedType = serviceType.startsWith('_')
        ? (serviceType.endsWith('._tcp') ? serviceType : '$serviceType._tcp')
        : '_$serviceType._tcp';

    _discovery = BonsoirDiscovery(type: formattedType);

    _discoverySubscription = _discovery!.eventStream?.listen(
      (event) {
        if (event is BonsoirDiscoveryServiceFoundEvent) {
          event.service.resolve(_discovery!.serviceResolver);
        } else if (event is BonsoirDiscoveryServiceResolvedEvent) {
          final service = event.service;
          final attributes = service.attributes;
          final peerId = attributes['id'] ?? service.name;
          final displayName = attributes['name'] ?? service.name;
          final ip = service.toJson()['ip'] as String?;
          final port = service.port;

          final peer = Peer(
            id: peerId,
            displayName: displayName,
            metadata: attributes,
            discoveredVia: DiscoveryMedium.mdns,
            ipAddress: ip,
            port: port,
            lastSeen: DateTime.now(),
          );

          _peerFoundController.add(peer);
        } else if (event is BonsoirDiscoveryServiceLostEvent) {
          final service = event.service;
          final peerId = service.attributes['id'] ?? service.name;
          _peerLostController.add(peerId);
        }
      },
      onError: (error) {
        // Handle discovery stream error
      },
    );

    await _discovery!.start();
  }

  /// Stops scanning for services.
  Future<void> stopBrowsing() async {
    if (_discoverySubscription != null) {
      await _discoverySubscription!.cancel();
      _discoverySubscription = null;
    }
    if (_discovery != null) {
      await _discovery!.stop();
      _discovery = null;
    }
  }

  /// Closes and cleans up all controllers.
  Future<void> dispose() async {
    await stopBroadcasting();
    await stopBrowsing();
    await _peerFoundController.close();
    await _peerLostController.close();
  }
}
