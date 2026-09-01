import 'dart:typed_data';

/// Transport that discovered a peer or delivered a broadcast packet.
enum DiscoveryMedium { network, ble, hybrid }

/// A connectionless broadcast packet received over BLE advertisement or UDP multicast.
class BroadcastPacket {
  final Uint8List data;

  /// Lowercase eight-character sender fingerprint, identical on BLE and LAN.
  final String senderId;

  /// Full persistent sender ID, available on the network only.
  final String? fullSenderId;

  /// Network source address, never inferred from a BLE device address.
  final String? address;
  final DiscoveryMedium medium;
  final DateTime receivedAt;
  final String? deviceName;
  final int? rssi;

  /// Small string key/value attributes sent alongside [data].
  ///
  /// Only populated for packets received over the network
  /// transport - BLE advertisement payloads never carry attributes, since
  /// they must stay within the legacy 31-byte advertisement budget. Always
  /// empty (never null) when absent.
  final Map<String, String> attributes;

  BroadcastPacket({
    required this.data,
    required this.senderId,
    this.fullSenderId,
    this.address,
    required this.medium,
    DateTime? receivedAt,
    this.deviceName,
    this.rssi,
    Map<String, String>? attributes,
  }) : receivedAt = receivedAt ?? DateTime.now(),
       attributes = attributes ?? const {};

  @override
  String toString() =>
      'BroadcastPacket(senderId: $senderId, medium: ${medium.name}, bytes: ${data.length}, deviceName: $deviceName, attributes: $attributes)';
}
