import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'nearby_method_channel.dart';

abstract class NearbyPlatform extends PlatformInterface {
  /// Constructs a NearbyPlatform.
  NearbyPlatform() : super(token: _token);

  static final Object _token = Object();

  static NearbyPlatform _instance = MethodChannelNearby();

  /// The default instance of [NearbyPlatform] to use.
  ///
  /// Defaults to [MethodChannelNearby].
  static NearbyPlatform get instance => _instance;

  /// Platform-specific implementations should set this with their own
  /// platform-specific class that extends [NearbyPlatform] when
  /// they register themselves.
  static set instance(NearbyPlatform instance) {
    PlatformInterface.verifyToken(instance, _token);
    _instance = instance;
  }

  Future<String?> getPlatformVersion() {
    throw UnimplementedError('platformVersion() has not been implemented.');
  }
}
