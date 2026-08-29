import 'dart:typed_data';
import '../models/peer.dart';

/// A connectionless broadcast packet received over BLE advertisement or UDP multicast.
class BroadcastPacket {
  final Uint8List data;
  final String senderId;
  final DiscoveryMedium medium;
  final DateTime receivedAt;
  final String? deviceName;
  final int? rssi;

  /// Small string key/value attributes sent alongside [data].
  ///
  /// Only populated for packets received over the network (mDNS/multicast)
  /// transport - BLE advertisement payloads never carry attributes, since
  /// they must stay within the legacy 31-byte advertisement budget. Always
  /// empty (never null) when absent.
  final Map<String, String> attributes;

  BroadcastPacket({
    required this.data,
    required this.senderId,
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
