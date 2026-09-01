import '../broadcast/broadcast_channel.dart';
export '../broadcast/broadcast_channel.dart' show DiscoveryStrategy;

/// Security mode for peer connections.
enum SecurityMode {
  /// Standard connection with SAS PIN verification handshake.
  pinVerification,

  /// Automatic handshake acceptance without manual PIN comparison.
  autoAccept,
}

/// Configuration options for advertising this device to nearby peers.
class AdvertisingOptions {
  /// The service identifier (e.g. `_nearby-app._tcp` or a 128-bit UUID for BLE).
  final String serviceId;

  /// Custom metadata to include in discovery broadcast (e.g. TXT record or manufacturer data).
  final Map<String, String> metadata;

  /// Discovery strategy to use.
  final DiscoveryStrategy strategy;

  /// Preferred TCP port to listen on for LAN connections (0 or null for dynamic port).
  final int? port;

  /// Whether a busy preferred [port] should fall back to a dynamic port.
  final bool fallbackToDynamicPort;

  /// Security / authentication mode.
  final SecurityMode securityMode;

  const AdvertisingOptions({
    required this.serviceId,
    this.metadata = const {},
    this.strategy = DiscoveryStrategy.hybrid,
    this.port,
    this.fallbackToDynamicPort = true,
    this.securityMode = SecurityMode.autoAccept,
  });
}

/// Configuration options for discovering nearby advertising peers.
class DiscoveryOptions {
  /// The service identifier to search for.
  final String serviceId;

  /// Discovery strategy to use.
  final DiscoveryStrategy strategy;

  /// Optional filter for specific peer metadata or prefix.
  final Map<String, String>? metadataFilter;

  const DiscoveryOptions({
    required this.serviceId,
    this.strategy = DiscoveryStrategy.hybrid,
    this.metadataFilter,
  });
}
