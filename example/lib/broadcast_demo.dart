import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:nearby/nearby.dart';
import 'package:permission_handler/permission_handler.dart';

class BroadcastDemoScreen extends StatefulWidget {
  const BroadcastDemoScreen({super.key});

  @override
  State<BroadcastDemoScreen> createState() => _BroadcastDemoScreenState();
}

class _BroadcastDemoScreenState extends State<BroadcastDemoScreen> {
  late final BroadcastChannel _channel;
  StreamSubscription<BroadcastPacket>? _packets;
  StreamSubscription<BroadcastFailure>? _errors;
  final _messages = <String>[];
  var _status = 'Idle';
  var _sequence = 0;

  @override
  void initState() {
    super.initState();
    _channel = BroadcastChannel(
      config: const BroadcastChannelConfig(channelId: 'nearby-example-v1'),
      displayName: Platform.localHostname,
    );
    unawaited(_start());
  }

  Future<void> _start() async {
    setState(() => _status = 'Starting');
    try {
      await _requestPermissions();
      if (!mounted) return;
      _packets = _channel.stream.listen((packet) {
        if (!mounted) return;
        setState(() {
          _messages.insert(
            0,
            '${packet.senderId} via ${packet.medium.name}: ${packet.data}',
          );
        });
      });
      _errors = _channel.errors.listen((failure) {
        if (!mounted) return;
        setState(() => _status = '${failure.medium.name}: ${failure.error}');
      });
      await _channel.startListening();
      await _channel.startBroadcasting();
      if (mounted) setState(() => _status = 'Listening and broadcasting');
    } catch (error) {
      if (mounted) setState(() => _status = '$error');
    }
  }

  Future<void> _requestPermissions() async {
    if (Platform.isIOS || Platform.isMacOS) {
      await Permission.bluetooth.request();
    } else if (Platform.isAndroid) {
      await [
        Permission.bluetoothScan,
        Permission.bluetoothAdvertise,
        Permission.bluetoothConnect,
        Permission.locationWhenInUse,
        Permission.nearbyWifiDevices,
      ].request();
    }
  }

  Future<void> _send() async {
    final value = _sequence++;
    await _channel.send(
      Uint8List.fromList(
        [
          value >> 24,
          value >> 16,
          value >> 8,
          value,
        ].map((byte) => byte & 0xff).toList(),
      ),
      attributes: {'sequence': '$value'},
    );
  }

  @override
  void dispose() {
    unawaited(_packets?.cancel());
    unawaited(_errors?.cancel());
    unawaited(_channel.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Nearby Broadcast')),
      floatingActionButton: FloatingActionButton(
        onPressed: _send,
        child: const Icon(Icons.send),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(_status),
          const SizedBox(height: 16),
          for (final message in _messages) ListTile(title: Text(message)),
        ],
      ),
    );
  }
}
