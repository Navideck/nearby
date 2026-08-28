import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nearby/nearby.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('BroadcastChannel & BroadcastPacket', () {
    test('BroadcastChannelConfig initializes with expected defaults', () {
      const config = BroadcastChannelConfig(channelId: 'test-channel');
      expect(config.channelId, 'test-channel');
      expect(config.strategy, DiscoveryStrategy.hybrid);
      expect(config.multicastAddress, '239.255.0.128');
      expect(config.multicastPort, 53210);
      expect(config.bleCompanyId, 0xFFFF);
      expect(config.bleServiceUuid, isNull);
    });

    test('BroadcastPacket stores metadata and payload', () {
      final data = Uint8List.fromList([1, 2, 3, 4, 5]);
      final packet = BroadcastPacket(
        data: data,
        senderId: 'device-123',
        medium: DiscoveryMedium.ble,
        deviceName: 'Camera A',
        rssi: -45,
      );

      expect(packet.data, data);
      expect(packet.senderId, 'device-123');
      expect(packet.medium, DiscoveryMedium.ble);
      expect(packet.deviceName, 'Camera A');
      expect(packet.rssi, -45);
      expect(packet.toString(), contains('Camera A'));
    });

    test('BroadcastChannel lifecycle start and stop without errors', () async {
      final channel = BroadcastChannel(
        config: const BroadcastChannelConfig(
          channelId: 'unit-test',
          strategy: DiscoveryStrategy.hybrid,
        ),
      );

      expect(channel.isBroadcasting, isFalse);
      expect(channel.isListening, isFalse);

      await channel.startBroadcasting();
      expect(channel.isBroadcasting, isTrue);

      await channel.startListening();
      expect(channel.isListening, isTrue);

      await channel.stopBroadcasting();
      expect(channel.isBroadcasting, isFalse);

      await channel.stopListening();
      expect(channel.isListening, isFalse);

      await channel.dispose();
    });
  });
}
