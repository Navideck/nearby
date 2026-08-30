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
  });
}
