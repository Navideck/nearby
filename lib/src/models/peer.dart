import '../broadcast/broadcast_packet.dart';
export '../broadcast/broadcast_packet.dart' show DiscoveryMedium;

/// Connection state of a remote peer.
enum PeerConnectionState {
  /// The peer is not connected.
  disconnected,

  /// A connection attempt is in progress.
  connecting,

  /// Connection established; authentication / SAS verification in progress.
  authenticating,

  /// The peer is fully connected and ready for data transfer.
  connected,
}

/// Represents a remote peer in the nearby network.
class Peer {
  /// Unique identifier of the peer (e.g. UUID or device hash).
  final String id;

  /// Human-readable display name of the peer device.
  final String displayName;

  /// Custom metadata or attributes broadcasted by the peer.
  final Map<String, String> metadata;

  /// The discovery medium.
  final DiscoveryMedium discoveredVia;

  /// IP address of the peer (if discovered via mDNS/LAN).
  final String? ipAddress;

  /// Port number of the peer's TCP server (if discovered via mDNS/LAN).
  final int? port;

  /// Bluetooth peripheral/device ID (if discovered via BLE).
  final String? bleDeviceId;

  /// Custom service UUID used for GATT connection (if discovered via BLE).
  final String? serviceUuid;

  /// Signal strength (RSSI in dBm) if available.
  final int? rssi;

  /// Timestamp of when the peer was last seen.
  final DateTime lastSeen;

  const Peer({
    required this.id,
    required this.displayName,
    this.metadata = const {},
    required this.discoveredVia,
    this.ipAddress,
    this.port,
    this.bleDeviceId,
    this.serviceUuid,
    this.rssi,
    required this.lastSeen,
  });

  /// Creates a copy of this peer with optional field overrides.
  Peer copyWith({
    String? id,
    String? displayName,
    Map<String, String>? metadata,
    DiscoveryMedium? discoveredVia,
    String? ipAddress,
    int? port,
    String? bleDeviceId,
    String? serviceUuid,
    int? rssi,
    DateTime? lastSeen,
  }) {
    return Peer(
      id: id ?? this.id,
      displayName: displayName ?? this.displayName,
      metadata: metadata ?? this.metadata,
      discoveredVia: discoveredVia ?? this.discoveredVia,
      ipAddress: ipAddress ?? this.ipAddress,
      port: port ?? this.port,
      bleDeviceId: bleDeviceId ?? this.bleDeviceId,
      serviceUuid: serviceUuid ?? this.serviceUuid,
      rssi: rssi ?? this.rssi,
      lastSeen: lastSeen ?? this.lastSeen,
    );
  }

  /// Serializes peer info into a JSON-compatible map.
  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'displayName': displayName,
      'metadata': metadata,
      'discoveredVia': discoveredVia.name,
      'ipAddress': ipAddress,
      'port': port,
      'bleDeviceId': bleDeviceId,
      'serviceUuid': serviceUuid,
      'rssi': rssi,
      'lastSeen': lastSeen.toIso8601String(),
    };
  }

  /// Deserializes peer info from a JSON-compatible map.
  factory Peer.fromJson(Map<String, dynamic> json) {
    return Peer(
      id: json['id'] as String,
      displayName: json['displayName'] as String,
      metadata:
          (json['metadata'] as Map<dynamic, dynamic>?)?.map(
            (k, v) => MapEntry(k.toString(), v.toString()),
          ) ??
          const {},
      discoveredVia: DiscoveryMedium.values.firstWhere(
        (m) => m.name == json['discoveredVia'],
        orElse: () => DiscoveryMedium.network,
      ),
      ipAddress: json['ipAddress'] as String?,
      port: json['port'] as int?,
      bleDeviceId: json['bleDeviceId'] as String?,
      serviceUuid: json['serviceUuid'] as String?,
      rssi: json['rssi'] as int?,
      lastSeen: json['lastSeen'] != null
          ? DateTime.parse(json['lastSeen'] as String)
          : DateTime.now(),
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Peer && runtimeType == other.runtimeType && id == other.id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() =>
      'Peer(id: $id, name: $displayName, via: ${discoveredVia.name}, ip: $ipAddress:$port, rssi: $rssi)';
}
