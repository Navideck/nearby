import 'package:flutter_test/flutter_test.dart';
import 'package:nearby/nearby.dart';
import 'package:nearby/nearby_platform_interface.dart';
import 'package:nearby/nearby_method_channel.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

class MockNearbyPlatform
    with MockPlatformInterfaceMixin
    implements NearbyPlatform {
  @override
  Future<String?> getPlatformVersion() => Future.value('42');
}

void main() {
  final NearbyPlatform initialPlatform = NearbyPlatform.instance;

  test('$MethodChannelNearby is the default instance', () {
    expect(initialPlatform, isInstanceOf<MethodChannelNearby>());
  });

  test('getPlatformVersion', () async {
    Nearby nearbyPlugin = Nearby();
    MockNearbyPlatform fakePlatform = MockNearbyPlatform();
    NearbyPlatform.instance = fakePlatform;

    expect(await nearbyPlugin.getPlatformVersion(), '42');
  });
}
