import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nearby/nearby.dart';
import 'package:nearby/src/discovery/ble_discovery.dart';
import 'package:nearby/src/transport/ble/ble_transport_registry.dart';
import 'package:universal_ble/universal_ble.dart';

class _TestCentralPlatform extends UniversalBlePlatform {
  bool scanning = false;
  final Map<String, bool> connectedDevices = {};

  @override
  Future<AvailabilityState> getBluetoothAvailabilityState() async =>
      AvailabilityState.poweredOn;

  @override
  Future<bool> enableBluetooth() async => true;

  @override
  Future<bool> disableBluetooth() async => true;

  @override
  Future<void> startScan({
    ScanFilter? scanFilter,
    PlatformConfig? platformConfig,
  }) async {
    scanning = true;
  }

  @override
  Future<void> stopScan() async {
    scanning = false;
  }

  @override
  Future<bool> isScanning() async => scanning;

  @override
  Future<void> connect(
    String deviceId, {
    Duration? connectionTimeout,
    bool autoConnect = false,
    ConnectionPlatformConfig? platformConfig,
  }) async {
    connectedDevices[deviceId.toLowerCase()] = true;
    scheduleMicrotask(() {
      updateConnection(deviceId, true);
    });
  }

  @override
  Future<void> disconnect(String deviceId) async {
    connectedDevices[deviceId.toLowerCase()] = false;
    scheduleMicrotask(() {
      updateConnection(deviceId, false);
    });
  }

  @override
  Future<BleConnectionState> getConnectionState(String deviceId) async {
    final isConnected = connectedDevices[deviceId.toLowerCase()] ?? false;
    return isConnected
        ? BleConnectionState.connected
        : BleConnectionState.disconnected;
  }

  @override
  Future<List<BleService>> discoverServices(
    String deviceId,
    bool withDescriptors, {
    DiscoverServicesPlatformConfig? platformConfig,
  }) async {
    return [
      BleService(kNearbyBleServiceUuid, [
        BleCharacteristic(kNearbyBleTxCharUuid, [
          CharacteristicProperty.write,
        ], []),
        BleCharacteristic(kNearbyBleRxCharUuid, [
          CharacteristicProperty.notify,
        ], []),
      ]),
    ];
  }

  @override
  Future<void> setNotifiable(
    String deviceId,
    String service,
    String characteristic,
    BleInputProperty bleInputProperty,
  ) async {}

  @override
  Future<Uint8List> readValue(
    String deviceId,
    String service,
    String characteristic, {
    Duration? timeout,
  }) async => Uint8List(0);

  @override
  Future<Uint8List> readDescriptorValue(
    String deviceId,
    String service,
    String characteristic,
    String descriptor, {
    Duration? timeout,
  }) async => Uint8List(0);

  @override
  Future<void> writeValue(
    String deviceId,
    String service,
    String characteristic,
    Uint8List value,
    BleOutputProperty bleOutputProperty,
  ) async {}

  @override
  Future<void> writeDescriptorValue(
    String deviceId,
    String service,
    String characteristic,
    String descriptor,
    Uint8List value,
  ) async {}

  @override
  Future<int> requestMtu(String deviceId, int expectedMtu) async => 247;

  @override
  Future<int> readRssi(String deviceId) async => -50;

  @override
  Future<void> requestConnectionPriority(
    String deviceId,
    BleConnectionPriority priority,
  ) async {}

  @override
  Future<bool> isPaired(String deviceId) async => true;

  @override
  Future<bool> pair(String deviceId) async => true;

  @override
  Future<void> unpair(String deviceId) async {}

  @override
  Future<List<BleDevice>> getSystemDevices(List<String>? withServices) async =>
      [];
}

class _TestPeripheralPlatform extends UniversalBlePeripheralUnsupported {
  final Set<String> registeredServices = {};
  List<String>? advertisedServices;
  String? advertisedLocalName;
  ManufacturerData? advertisedManufacturer;
  int startAdvertisingCalls = 0;
  int stopAdvertisingCalls = 0;
  int clearServicesCalls = 0;
  OnPeripheralWriteRequest? writeHandler;
  OnPeripheralReadRequest? readHandler;

  @override
  Future<PeripheralReadinessState> getAvailabilityState() async =>
      PeripheralReadinessState.ready;

  @override
  Future<PeripheralAdvertisingState> getAdvertisingState() async =>
      advertisedServices != null
      ? PeripheralAdvertisingState.advertising
      : PeripheralAdvertisingState.idle;

  @override
  Future<void> addService(
    dynamic service, {
    bool primary = true,
    Duration? timeout,
  }) async {
    // PeripheralService generated pigeon class exposes `.uuid`
    final uuid = BleUuidParser.string(service.uuid as String);
    registeredServices.add(uuid);
  }

  @override
  Future<void> removeService(String serviceId) async {
    registeredServices.remove(BleUuidParser.string(serviceId));
  }

  @override
  Future<void> clearServices() async {
    clearServicesCalls++;
    registeredServices.clear();
  }

  @override
  Future<List<String>> getServices() async => registeredServices.toList();

  @override
  Future<void> startAdvertising({
    required List<String> services,
    String? localName,
    Duration? timeout,
    ManufacturerData? manufacturerData,
    PeripheralPlatformConfig? platformConfig,
  }) async {
    startAdvertisingCalls++;
    advertisedServices = List.of(services);
    advertisedLocalName = localName;
    advertisedManufacturer = manufacturerData;
  }

  @override
  Future<void> stopAdvertising() async {
    stopAdvertisingCalls++;
    advertisedServices = null;
  }

  @override
  void setWriteRequestHandler(OnPeripheralWriteRequest? handler) {
    writeHandler = handler;
  }

  @override
  void setReadRequestHandler(OnPeripheralReadRequest? handler) {
    readHandler = handler;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _TestCentralPlatform central;
  late _TestPeripheralPlatform peripheral;

  setUp(() async {
    await BleScanDispatcher.instance.reset();
    BlePeripheralCoordinator.instance.reset();
    BleTransportRegistry.instance.clear();
    central = _TestCentralPlatform();
    peripheral = _TestPeripheralPlatform();
    UniversalBle.setInstance(central);
    UniversalBlePeripheral.setInstance(peripheral);
  });

  tearDown(() async {
    await BleScanDispatcher.instance.reset();
    BlePeripheralCoordinator.instance.reset();
    BleTransportRegistry.instance.clear();
  });

  group('Hazard 1: UniversalBle callback non-interference', () {
    test(
      'BleTransport uses per-device streams without overwriting host callbacks',
      () async {
        final hostValues = <BleCharacteristicValue>[];
        final hostConnections = <BleConnectionChange>[];

        void hostValueCallback(BleCharacteristicValue update) {
          hostValues.add(update);
        }

        void hostConnectionCallback(BleConnectionChange update) {
          hostConnections.add(update);
        }

        UniversalBle.onValueChange = hostValueCallback;
        UniversalBle.onConnectionChange = hostConnectionCallback;

        final transport = await BleTransport.connect(
          deviceId: 'AA:BB:CC:DD:EE:01',
          peerId: 'peer-1',
        );

        // Host callbacks remain intact after BleTransport registers.
        expect(central.onValueChange, same(hostValueCallback));
        expect(central.onConnectionChange, same(hostConnectionCallback));

        final receivedFrames = <PacketFrame>[];
        final frameSub = transport.incomingFrames.listen(receivedFrames.add);

        // Emit frame on Nearby's RX characteristic -> both host callback and
        // BleTransport receive their expected updates.
        final frame = PacketFrame(
          type: FrameType.heartbeat,
          sequence: 7,
          body: Uint8List.fromList([42]),
        );
        central.updateCharacteristicValue(
          'AA:BB:CC:DD:EE:01',
          kNearbyBleRxCharUuid,
          frame.toBytes(),
          null,
        );

        // Emit notification for an unrelated camera characteristic.
        central.updateCharacteristicValue(
          '11:22:33:44:55:66',
          '0000ff02-0000-1000-8000-00805f9b34fb',
          Uint8List.fromList([0x01, 0x02]),
          null,
        );

        await pumpEventQueue();

        expect(receivedFrames.length, 1);
        expect(receivedFrames.first.sequence, 7);
        expect(hostValues.length, 2);

        // Remote peripheral disconnect closes BleTransport AND notifies host.
        central.updateConnection('AA:BB:CC:DD:EE:01', false);
        await pumpEventQueue();

        expect(transport.isClosed, isTrue);
        expect(
          hostConnections.any((c) => !c.isConnected),
          isTrue,
        );

        await frameSub.cancel();
      },
    );
  });

  group('Hazard 2: UniversalBlePeripheral service & advertiser coordination', () {
    test(
      'BleDiscoveryService preserves host GATT services instead of clearServices',
      () async {
        const hidUuid = '00001812-0000-1000-8000-00805f9b34fb';
        peripheral.registeredServices.add(hidUuid);

        final discovery = BleDiscoveryService();
        await discovery.startAdvertising(
          peerId: 'peer-a',
          displayName: 'Node A',
          serviceId: 'navideck-link',
        );

        final nearbyUuid = BleUuidParser.string(
          BleDiscoveryService.generateServiceUuid('navideck-link'),
        );
        expect(peripheral.clearServicesCalls, 0);
        expect(peripheral.registeredServices, containsAll([hidUuid, nearbyUuid]));
        expect(peripheral.writeHandler, isNotNull);

        await discovery.stopAdvertising();

        // Host HID service remains registered while Nearby's service & handlers clean up.
        expect(peripheral.clearServicesCalls, 0);
        expect(peripheral.registeredServices, equals({hidUuid}));
        expect(peripheral.writeHandler, isNull);
        expect(peripheral.readHandler, isNull);

        await discovery.dispose();
      },
    );

    test(
      'BroadcastChannel yields BLE peripheral when GATT discovery or external host owns advertising',
      () async {
        final channel = BroadcastChannel(
          config: const BroadcastChannelConfig(
            channelId: 'tc',
            strategy: DiscoveryStrategy.bleOnly,
          ),
          senderId: 'sender',
        );

        // 1. External host peripheral active (e.g. BLE HID): BroadcastChannel skips BLE
        var externalHidActive = true;
        BlePeripheralCoordinator.instance.isExternalAdvertisingActive =
            () => externalHidActive;
        peripheral.advertisedServices = ['1812'];

        expect(await BroadcastChannel.isBleAvailable(), isFalse);
        await channel.send(Uint8List.fromList([1, 2, 3, 4]));
        expect(peripheral.startAdvertisingCalls, 0);
        expect(peripheral.stopAdvertisingCalls, 0);
        expect(peripheral.advertisedServices, ['1812']);

        // Stopping BroadcastChannel while external owner is active never stops host advertising.
        await channel.stopBroadcasting();
        expect(peripheral.stopAdvertisingCalls, 0);
        expect(peripheral.advertisedServices, ['1812']);

        // 2. External host releases peripheral -> BroadcastChannel automatically resumes BLE.
        externalHidActive = false;
        expect(await BroadcastChannel.isBleAvailable(), isTrue);
        await channel.send(Uint8List.fromList([1, 2, 3, 4]));
        expect(peripheral.startAdvertisingCalls, 1);

        // 3. BleDiscoveryService starts GATT advertising -> acquires coordinator lease;
        // BroadcastChannel yields without stopping BleDiscoveryService's advertisement.
        final discovery = BleDiscoveryService();
        await discovery.startAdvertising(
          peerId: 'peer-a',
          displayName: 'Node A',
        );
        final startsAfterDiscovery = peripheral.startAdvertisingCalls;
        final stopsAfterDiscovery = peripheral.stopAdvertisingCalls;

        await channel.send(Uint8List.fromList([5, 6, 7, 8]));
        expect(peripheral.startAdvertisingCalls, startsAfterDiscovery);
        expect(peripheral.stopAdvertisingCalls, stopsAfterDiscovery);

        await channel.dispose();
        expect(peripheral.stopAdvertisingCalls, stopsAfterDiscovery);

        await discovery.dispose();
      },
    );
  });
}
