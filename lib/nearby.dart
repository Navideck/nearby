
import 'nearby_platform_interface.dart';

class Nearby {
  Future<String?> getPlatformVersion() {
    return NearbyPlatform.instance.getPlatformVersion();
  }
}
