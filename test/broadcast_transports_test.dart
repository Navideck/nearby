import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nearby/nearby.dart';
import 'package:nearby/src/broadcast/broadcast_wire.dart';
import 'package:universal_ble/universal_ble.dart';

import 'broadcast_fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late FakeCentral central;
  late FakePeripheral peripheral;
  setUp(() async {
    await BleScanDispatcher.instance.reset();
    central = FakeCentral();
    peripheral = FakePeripheral();
    UniversalBle.setInstance(central);
    UniversalBlePeripheral.setInstance(peripheral);
  });
  tearDown(() async {
    await BleScanDispatcher.instance.reset();
    debugDefaultTargetPlatformOverride = null;
    await central.packets.close();
    await peripheral.events.close();
  });

  test('wire identity and byte budget are identical on both carriers', () {
    final wire = BroadcastWire('a');
    final data = Uint8List.fromList(List.generate(10, (i) => i));
    final bytes = wire.encode(data, 'sender');
    expect(bytes.length, 18);
    final name = wire.localName(bytes);
    expect(name.length + 2 + 3, 31);
    expect(wire.decodeLocalName(name), bytes);
    expect(
      wire.decode(bytes)?.senderId,
      BroadcastChannel.fingerprint('sender'),
    );
    expect(wire.decode(bytes)?.data, data);
    expect(BroadcastWire('b').decode(bytes), isNull);
    expect(() => wire.localName(Uint8List(19)), throwsArgumentError);
    expect(wire.decodeLocalName('N2!!'), isNull);
    expect(wire.decodeNetwork(Uint8List.fromList([0, 1])), isNull);
  });

  for (final platform in [
    TargetPlatform.iOS,
    TargetPlatform.macOS,
    TargetPlatform.android,
    TargetPlatform.windows,
  ]) {
    test('correct legacy advertising carrier on $platform', () async {
      debugDefaultTargetPlatformOverride = platform;
      final channel = BroadcastChannel(
        config: const BroadcastChannelConfig(
          channelId: 'a',
          strategy: DiscoveryStrategy.bleOnly,
        ),
        senderId: 'sender',
      );
      final data = Uint8List(10);
      await channel.send(data);
      expect(peripheral.services, isEmpty);
      final apple =
          platform == TargetPlatform.iOS || platform == TargetPlatform.macOS;
      expect(peripheral.name != null, apple);
      expect(peripheral.manufacturer != null, !apple);
      final wire = BroadcastWire('a');
      final bytes = apple
          ? wire.decodeLocalName(peripheral.name)!
          : peripheral.manufacturer!.payload;
      expect(wire.decode(bytes)?.data, data);
      await channel.send(data);
      expect(peripheral.stops, 1);
      await channel.dispose();
      expect(peripheral.stops, 2);
    });
  }

  test('receive normalized identity/data and native timestamp, reject other channels', () async {
    final channel = BroadcastChannel(
      config: const BroadcastChannelConfig(
        channelId: 'a',
        strategy: DiscoveryStrategy.bleOnly,
      ),
    );
    final received = <BroadcastPacket>[];
    final sub = channel.stream.listen(received.add);
    await channel.startListening();
    final wire = BroadcastWire('a');
    final bytes = wire.encode(Uint8List.fromList([1, 2]), 'sender');
    central.packets.add(
      BleDevice(
        deviceId: 'mac-1',
        name: wire.localName(bytes),
        timestampMicroseconds: 1234567,
      ),
    );
    central.packets.add(
      BleDevice(
        deviceId: 'mac-2',
        name: null,
        timestampMicroseconds: 1234568,
        manufacturerDataList: [ManufacturerData(0xffff, bytes)],
      ),
    );
    central.packets.add(
      BleDevice(
        deviceId: 'unrelated',
        name: null,
        manufacturerDataList: [
          ManufacturerData(
            0xffff,
            BroadcastWire('b').encode(Uint8List(1), 'sender'),
          ),
        ],
      ),
    );
    await pumpEventQueue();
    expect(received.length, 2);
    expect(received[0].senderId, received[1].senderId);
    expect(received[0].receivedAt.microsecondsSinceEpoch, 1234567);
    await channel.dispose();
    await sub.cancel();
  });

  test(
    'scan keeps external callback and restores an interrupted scanner',
    () async {
      central.scanning = true;
      void external(BleDevice _) {}
      UniversalBle.onScanResult = external;
      final dispatcher = BleScanDispatcher.instance;
      var restored = false;
      dispatcher.resumeInterruptedScan = () async {
        restored = true;
      };
      void listener(BleDevice _) {}
      await dispatcher.addListener(listener);
      expect(central.callback, same(external));
      await dispatcher.removeListener(listener);
      expect(central.stops, 2);
      expect(restored, isTrue);
      dispatcher.resumeInterruptedScan = null;
    },
  );

  test('same-host UDP delivers metadata even when BLE is denied', () async {
    central.failScan = true;
    peripheral.readiness = PeripheralReadinessState.unauthorized;
    final temporary = await RawDatagramSocket.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    final port = temporary.port;
    temporary.close();
    final config = BroadcastChannelConfig(
      channelId: 'udp-test',
      multicastPort: port,
    );
    final receiver = BroadcastChannel(config: config);
    final sender = BroadcastChannel(
      config: config,
      senderId: 'persistent',
      displayName: 'Camera A',
    );
    final result = receiver.stream.first.timeout(const Duration(seconds: 3));
    await receiver.startListening();
    await sender.send(
      Uint8List.fromList([1, 2, 3]),
      attributes: {'clock': '1234'},
    );
    final packet = await result;
    expect(packet.senderId, BroadcastChannel.fingerprint('persistent'));
    expect(packet.fullSenderId, 'persistent');
    expect(packet.deviceName, 'Camera A');
    expect(packet.address, isNotNull);
    expect(packet.attributes, {'clock': '1234'});
    await sender.dispose();
    await receiver.dispose();
  });

  test('network-only packets bypass BLE and keep Nearby framing', () async {
    final temporary = await RawDatagramSocket.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    final port = temporary.port;
    temporary.close();
    final config = BroadcastChannelConfig(
      channelId: 'network-control-test',
      multicastPort: port,
    );
    final receiver = BroadcastChannel(config: config);
    final sender = BroadcastChannel(config: config, senderId: 'controller');
    final result = receiver.stream.first.timeout(const Duration(seconds: 3));
    await receiver.startListening(strategy: DiscoveryStrategy.networkOnly);
    await sender.sendNetwork(Uint8List.fromList(List.generate(64, (i) => i)));
    final packet = await result;
    expect(packet.fullSenderId, 'controller');
    expect(packet.data, Uint8List.fromList(List.generate(64, (i) => i)));
    expect(central.starts, 0);
    expect(peripheral.starts, 0);
    await sender.dispose();
    await receiver.dispose();
  });

  test(
    'stop during in-flight BLE send prevents advertising from leaking',
    () async {
      peripheral.gate = Completer<void>();
      final channel = BroadcastChannel(
        config: const BroadcastChannelConfig(
          channelId: 'a',
          strategy: DiscoveryStrategy.bleOnly,
        ),
      );
      final send = channel.send(Uint8List(10));
      await pumpEventQueue();
      final stop = channel.stopBroadcasting();
      peripheral.gate!.complete();
      await send;
      await stop;
      expect(peripheral.starts, 1);
      expect(peripheral.stops, 1);
      expect(channel.isBroadcasting, isFalse);
      await channel.dispose();
    },
  );
}
