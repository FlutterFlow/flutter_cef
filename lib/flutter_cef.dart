
import 'flutter_cef_platform_interface.dart';

class FlutterCef {
  Future<String?> getPlatformVersion() {
    return FlutterCefPlatform.instance.getPlatformVersion();
  }
}
