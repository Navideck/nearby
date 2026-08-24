import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:nearby/nearby.dart';

void main() {
  group('Peer Model', () {
    test('Peer JSON serialization and deserialization roundtrip', () {
      final now = DateTime.now();
      final peer = Peer(
        id: 'peer_abc_123',
        displayName: 'Alice MacBook',
        metadata: {'platform': 'macos', 'app_version': '1.0.0'},
        discoveredVia: DiscoveryMedium.hybrid,
        ipAddress: '192.168.1.50',
        port: 8888,
        bleDeviceId: 'AA:BB:CC:DD:EE:FF',
        rssi: -45,
        lastSeen: now,
      );

      final json = peer.toJson();
      final reconstructed = Peer.fromJson(json);

      expect(reconstructed.id, equals(peer.id));
      expect(reconstructed.displayName, equals(peer.displayName));
      expect(reconstructed.metadata, equals(peer.metadata));
      expect(reconstructed.discoveredVia, equals(DiscoveryMedium.hybrid));
      expect(reconstructed.ipAddress, equals('192.168.1.50'));
      expect(reconstructed.port, equals(8888));
      expect(reconstructed.bleDeviceId, equals('AA:BB:CC:DD:EE:FF'));
      expect(reconstructed.rssi, equals(-45));
    });

    test('Peer copyWith updates fields correctly', () {
      final peer = Peer(
        id: 'p1',
        displayName: 'Device 1',
        discoveredVia: DiscoveryMedium.mdns,
        lastSeen: DateTime.now(),
      );

      final updated = peer.copyWith(
        displayName: 'Renamed Device',
        discoveredVia: DiscoveryMedium.hybrid,
        rssi: -60,
      );

      expect(updated.id, equals('p1'));
      expect(updated.displayName, equals('Renamed Device'));
      expect(updated.discoveredVia, equals(DiscoveryMedium.hybrid));
      expect(updated.rssi, equals(-60));
    });

    test('Peer equality and hashCode based on ID', () {
      final peer1 = Peer(
        id: 'same_id',
        displayName: 'Name 1',
        discoveredVia: DiscoveryMedium.mdns,
        lastSeen: DateTime.now(),
      );
      final peer2 = Peer(
        id: 'same_id',
        displayName: 'Name 2',
        discoveredVia: DiscoveryMedium.ble,
        lastSeen: DateTime.now(),
      );

      expect(peer1, equals(peer2));
      expect(peer1.hashCode, equals(peer2.hashCode));
    });
  });

  group('NearbyPayload Models', () {
    test('NearbyPayload.fromBytes factory creates bytes payload', () {
      final data = Uint8List.fromList([1, 2, 3, 4, 5]);
      final payload = NearbyPayload.fromBytes(bytes: data);

      expect(payload.type, equals(PayloadType.bytes));
      expect(payload.bytes, equals(data));
      expect(payload.totalBytes, equals(5));
      expect(payload.file, isNull);
      expect(payload.stream, isNull);
    });

    test('NearbyPayload.fromFile factory creates file payload', () {
      final tempFile = File('${Directory.systemTemp.path}/test_file.png');
      tempFile.writeAsBytesSync([10, 20, 30, 40]);

      final payload = NearbyPayload.fromFile(
        file: tempFile,
        customFileName: 'custom_avatar.png',
      );

      expect(payload.type, equals(PayloadType.file));
      expect(payload.file, equals(tempFile));
      expect(payload.fileName, equals('custom_avatar.png'));
      expect(payload.totalBytes, equals(4));

      tempFile.deleteSync();
    });

    test('NearbyPayload.fromStream factory creates stream payload', () {
      final stream = Stream<List<int>>.value([1, 2, 3]);
      final payload = NearbyPayload.fromStream(stream: stream);

      expect(payload.type, equals(PayloadType.stream));
      expect(payload.totalBytes, equals(-1));
      expect(payload.stream, equals(stream));
    });
  });

  group('PayloadTransferUpdate Calculations', () {
    test('Calculates progress fraction and percentage accurately', () {
      const update = PayloadTransferUpdate(
        payloadId: 100,
        peerId: 'peer_1',
        bytesTransferred: 250,
        totalBytes: 1000,
        status: PayloadStatus.inProgress,
      );

      expect(update.progress, equals(0.25));
      expect(update.percentage, equals(25));
    });

    test('Handles stream with unknown totalBytes gracefully', () {
      const update = PayloadTransferUpdate(
        payloadId: 100,
        peerId: 'peer_1',
        bytesTransferred: 500,
        totalBytes: -1,
        status: PayloadStatus.inProgress,
      );

      expect(update.progress, isNull);
      expect(update.percentage, equals(0));
    });
  });

  group('Options and Request Models', () {
    test('AdvertisingOptions defaults', () {
      const options = AdvertisingOptions(serviceId: 'test-app');
      expect(options.strategy, equals(DiscoveryStrategy.hybrid));
      expect(options.securityMode, equals(SecurityMode.autoAccept));
      expect(options.metadata, isEmpty);
    });

    test('DiscoveryOptions configuration', () {
      const options = DiscoveryOptions(
        serviceId: 'test-app',
        strategy: DiscoveryStrategy.mdnsOnly,
        metadataFilter: {'env': 'prod'},
      );
      expect(options.strategy, equals(DiscoveryStrategy.mdnsOnly));
      expect(options.metadataFilter?['env'], equals('prod'));
    });

    test('ConnectionRequest structure', () {
      final now = DateTime.now();
      final peer = Peer(
        id: 'peer_x',
        displayName: 'Peer X',
        discoveredVia: DiscoveryMedium.hybrid,
        lastSeen: now,
      );

      final req = ConnectionRequest(
        peer: peer,
        authenticationPin: '4819',
        metadata: {'role': 'player'},
        timestamp: now,
      );

      expect(req.peer.id, equals('peer_x'));
      expect(req.authenticationPin, equals('4819'));
      expect(req.metadata['role'], equals('player'));
    });
  });
}
