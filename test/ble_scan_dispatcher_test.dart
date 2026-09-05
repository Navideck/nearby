import 'package:flutter_test/flutter_test.dart';
import 'package:nearby/src/transport/ble/ble_scan_dispatcher.dart';
import 'package:universal_ble/universal_ble.dart';

import 'broadcast_fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('BleScanDispatcher Tests', () {
    final dispatcher = BleScanDispatcher.instance;

    setUp(() async {
      await dispatcher.reset();
      UniversalBle.setInstance(FakeCentral());
    });

    tearDown(() async {
      await dispatcher.reset();
    });

    test(
      'Multiplexes scan callbacks across multiple registered listeners',
      () async {
        final received1 = <BleDevice>[];
        final received2 = <BleDevice>[];

        void callback1(BleDevice device) => received1.add(device);
        void callback2(BleDevice device) => received2.add(device);

        await dispatcher.addListener(callback1);
        await dispatcher.addListener(callback2);

        expect(dispatcher.listenerCount, 2);
        expect(dispatcher.isScanning, isTrue);

        final mockDevice = BleDevice(
          deviceId: 'device-123',
          name: 'Test Device',
          services: ['180d'],
        );

        // Trigger dispatch
        dispatcher.dispatchScanResultForTesting(mockDevice);

        expect(received1.length, 1);
        expect(received1.first.deviceId, 'device-123');
        expect(received2.length, 1);
        expect(received2.first.deviceId, 'device-123');

        // Remove one listener
        await dispatcher.removeListener(callback1);
        expect(dispatcher.listenerCount, 1);
        expect(dispatcher.isScanning, isTrue);

        dispatcher.dispatchScanResultForTesting(mockDevice);
        expect(received1.length, 1); // Not incremented
        expect(received2.length, 2); // Incremented

        // Remove last listener
        await dispatcher.removeListener(callback2);
        expect(dispatcher.listenerCount, 0);
        expect(dispatcher.isScanning, isFalse);
      },
    );

    test('suspendScan and resumeScan coordinate native scan state', () async {
      final received = <BleDevice>[];
      void callback(BleDevice device) => received.add(device);

      await dispatcher.addListener(callback);
      expect(dispatcher.isScanning, isTrue);
      expect(await UniversalBle.isScanning(), isTrue);

      // Suspend scan
      await dispatcher.suspendScan();
      expect(dispatcher.isScanning, isFalse);
      expect(await UniversalBle.isScanning(), isFalse);
      expect(dispatcher.listenerCount, 1);

      // Adding a listener while suspended registers callback without starting native scan
      void callback2(BleDevice device) {}
      await dispatcher.addListener(callback2);
      expect(dispatcher.listenerCount, 2);
      expect(dispatcher.isScanning, isFalse);
      expect(await UniversalBle.isScanning(), isFalse);

      // Resume scan
      await dispatcher.resumeScan();
      expect(dispatcher.isScanning, isTrue);
      expect(await UniversalBle.isScanning(), isTrue);

      final mockDevice = BleDevice(deviceId: 'd1', name: 'Test Device');
      dispatcher.dispatchScanResultForTesting(mockDevice);
      expect(received.length, 1);

      await dispatcher.removeListener(callback);
      await dispatcher.removeListener(callback2);
      expect(dispatcher.isScanning, isFalse);
      expect(await UniversalBle.isScanning(), isFalse);
    });

    test('restarts native scan when addListener is called after scan stopped', () async {
      void callback1(BleDevice _) {}
      await dispatcher.addListener(callback1);
      expect(await UniversalBle.isScanning(), isTrue);

      // Native scan stopped out-of-band (e.g. direct stopScan)
      await UniversalBle.stopScan();
      expect(await UniversalBle.isScanning(), isFalse);

      // addListener detects stopped scan and restarts it
      void callback2(BleDevice _) {}
      await dispatcher.addListener(callback2);
      expect(await UniversalBle.isScanning(), isTrue);
      expect(dispatcher.isScanning, isTrue);

      await dispatcher.removeListener(callback1);
      await dispatcher.removeListener(callback2);
    });
  });
}
