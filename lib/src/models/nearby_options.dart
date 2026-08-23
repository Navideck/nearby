/// Strategy determining how peers are discovered and connected.
enum DiscoveryStrategy {
  /// Hybrid: Advertises and scans over both mDNS (Local Network) and BLE.
  /// Provides the highest discovery speed and connection success rate.
  hybrid,

  /// mDNS Only: Broadcasts and browses exclusively on local network via Bonjour/mDNS.
  mdnsOnly,

  /// BLE Only: Advertises and scans exclusively via Bluetooth Low Energy.
  bleOnly,
}

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

  /// Security / authentication mode.
  final SecurityMode securityMode;

  const AdvertisingOptions({
    required this.serviceId,
    this.metadata = const {},
    this.strategy = DiscoveryStrategy.hybrid,
    this.port,
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
