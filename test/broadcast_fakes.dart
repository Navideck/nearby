import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:universal_ble/universal_ble.dart';

class FakeCentral extends Fake implements UniversalBlePlatform {
  final packets = StreamController<BleDevice>.broadcast(sync: true);
  bool scanning = false, failScan = false;
  int starts = 0, stops = 0;
  OnScanResult? callback;
  @override
  Stream<BleDevice> get scanStream => packets.stream;
  @override
  set onScanResultUpdate(OnScanResult? value) => callback = value;
  @override
  Future<bool> isScanning() async => scanning;
  @override
  Future<void> startScan({
    ScanFilter? scanFilter,
    PlatformConfig? platformConfig,
  }) async {
    starts++;
    if (failScan) throw StateError('Denied');
    scanning = true;
  }

  @override
  Future<void> stopScan() async {
    stops++;
    scanning = false;
  }
}

class FakePeripheral extends Fake implements UniversalBlePeripheralPlatform {
  final events =
      StreamController<BlePeripheralAdvertisingStateChanged>.broadcast();
  PeripheralReadinessState readiness = PeripheralReadinessState.ready;
  List<String>? services;
  String? name;
  ManufacturerData? manufacturer;
  int starts = 0, stops = 0;
  Completer<void>? gate;
  @override
  Stream<BlePeripheralAdvertisingStateChanged> get advertisingStateStream =>
      events.stream;
  @override
  Future<PeripheralReadinessState> getAvailabilityState() async => readiness;
  @override
  Future<void> startAdvertising({
    required List<String> services,
    String? localName,
    Duration? timeout,
    ManufacturerData? manufacturerData,
    PeripheralPlatformConfig? platformConfig,
  }) async {
    starts++;
    this.services = services;
    name = localName;
    manufacturer = manufacturerData;
    await gate?.future;
  }

  @override
  Future<void> stopAdvertising() async {
    stops++;
  }

  @override
  void dispose() {}
}
