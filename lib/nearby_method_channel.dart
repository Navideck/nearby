import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'nearby_platform_interface.dart';

/// An implementation of [NearbyPlatform] that uses method channels.
class MethodChannelNearby extends NearbyPlatform {
  /// The method channel used to interact with the native platform.
  @visibleForTesting
  final methodChannel = const MethodChannel('nearby');

  @override
  Future<String?> getPlatformVersion() async {
    final version = await methodChannel.invokeMethod<String>(
      'getPlatformVersion',
    );
    return version;
  }
}
