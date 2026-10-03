import 'package:flutter_print_platform_interface/flutter_print_platform_interface.dart';

import 'flutter_print_windows_impl.dart';

/// Registers the Windows implementation of [FlutterPrintPlatform].
class FlutterPrintWindows {
  static void registerWith() {
    FlutterPrintPlatform.instance = FlutterPrintWindowsImpl();
  }
}
