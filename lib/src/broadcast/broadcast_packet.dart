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

  BroadcastPacket({
    required this.data,
    required this.senderId,
    required this.medium,
    DateTime? receivedAt,
    this.deviceName,
    this.rssi,
  }) : receivedAt = receivedAt ?? DateTime.now();

  @override
  String toString() =>
      'BroadcastPacket(senderId: $senderId, medium: ${medium.name}, bytes: ${data.length}, deviceName: $deviceName)';
}
