import 'dart:async';
import 'dart:convert';

import 'package:bonsoir/bonsoir.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';

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
      ...metadata,
      'id': peerId,
      'name': displayName,
      'port': port.toString(),
    };

    final formattedType = formatServiceType(serviceType);

    final service = BonsoirService(
      name: formatServiceName(displayName, peerId),
      type: formattedType,
      port: port,
      attributes: attributes,
    );

    _broadcast = BonsoirBroadcast(service: service);
    try {
      await _broadcast!.initialize();
      await _broadcast!.start();
    } on MissingPluginException {
      _broadcast = null;
    }
  }

  /// Stops broadcasting this device.
  Future<void> stopBroadcasting() async {
    if (_broadcast != null) {
      try {
        await _broadcast!.stop();
      } on MissingPluginException {
        // TCP sessions still work when discovery is unavailable.
      }
      _broadcast = null;
    }
  }

  /// Starts scanning / browsing for nearby Bonsoir services.
  Future<void> startBrowsing({required String serviceType}) async {
    await stopBrowsing();

    final formattedType = formatServiceType(serviceType);

    _discovery = BonsoirDiscovery(type: formattedType);
    try {
      await _discovery!.initialize();
    } on MissingPluginException {
      _discovery = null;
      return;
    }

    _discoverySubscription = _discovery!.eventStream?.listen(
      (event) {
        if (event is BonsoirDiscoveryServiceFoundEvent) {
          event.service.resolve(_discovery!.serviceResolver);
        } else if (event is BonsoirDiscoveryServiceResolvedEvent) {
          final service = event.service;
          final attributes = service.attributes;
          final peerId = attributes['id'] ?? service.name;
          final displayName = attributes['name'] ?? service.name;
          final ip =
              service.hostAddress ??
              (service.hostAddresses.isNotEmpty
                  ? service.hostAddresses.first
                  : null) ??
              service.hostname;
          final port = service.port > 0
              ? service.port
              : (int.tryParse(attributes['port'] ?? '') ?? 0);

          final peer = Peer(
            id: peerId,
            displayName: displayName,
            metadata: attributes,
            discoveredVia: DiscoveryMedium.network,
            ipAddress: ip,
            port: port > 0 ? port : null,
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
      try {
        await _discovery!.stop();
      } on MissingPluginException {
        // Manual connections remain available without discovery.
      }
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

  /// Fits the instance name into one 63-byte DNS label without splitting UTF-8.
  /// Full display names and peer IDs remain available in TXT attributes.
  static String formatServiceName(String displayName, String peerId) {
    final peerBytes = utf8.encode(peerId);
    // Leave room for the separator; hash oversized IDs to preserve uniqueness.
    final suffix = peerBytes.length <= 62
        ? peerId
        : sha256.convert(peerBytes).toString().substring(0, 32);
    final prefix = StringBuffer();
    var remaining = 63 - 1 - utf8.encode(suffix).length;
    for (final rune in displayName.runes) {
      final character = String.fromCharCode(rune);
      final size = utf8.encode(character).length;
      if (size > remaining) break;
      prefix.write(character);
      remaining -= size;
    }
    return '$prefix-$suffix';
  }

  /// Normalizes a service ID into a fully-qualified Bonjour service type.
  ///
  /// Accepts:
  /// - Fully-qualified types like `_navideck-tc._udp` or `_navideck-tc._tcp`
  ///   (returned as-is; protocol matching is case-insensitive).
  /// - Short names like `navideck-tc` (expanded to `_navideck-tc._tcp`).
  static String formatServiceType(String serviceType) {
    // Already fully-qualified (starts with `_` and contains `._tcp` or `._udp`)
    // — never append another protocol suffix. mDNS labels are case-insensitive
    // (RFC 6763), so compare against the lowercased form but preserve the
    // caller's original casing.
    final normalized = serviceType.toLowerCase();
    if (normalized.startsWith('_') &&
        (normalized.contains('._tcp') || normalized.contains('._udp'))) {
      return serviceType;
    }
    // Starts with underscore but missing protocol suffix — default to ._tcp
    if (serviceType.startsWith('_')) {
      return '$serviceType._tcp';
    }
    // Plain name — prepend underscore and append ._tcp
    return '_$serviceType._tcp';
  }
}
