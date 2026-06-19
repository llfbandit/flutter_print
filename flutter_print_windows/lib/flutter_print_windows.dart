import 'package:flutter_print_platform_interface/flutter_print_platform_interface.dart';

import 'src/flutter_print_windows_impl.dart';

export 'package:flutter_print_platform_interface/flutter_print_platform_interface.dart';

/// Registers the Windows implementation of [FlutterPrintPlatform].
class FlutterPrintWindows {
  static void registerWith() {
    FlutterPrintPlatform.instance = FlutterPrintWindowsImpl();
  }
}
