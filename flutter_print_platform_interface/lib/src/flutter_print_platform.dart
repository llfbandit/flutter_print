import 'package:flutter/widgets.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'flutter_print_method_channel.dart';
import 'messages.g.dart';

abstract class FlutterPrintPlatform extends PlatformInterface {
  FlutterPrintPlatform() : super(token: _token);

  /// A token used for verification of subclasses to ensure they extend this
  /// class instead of implementing it.
  static final Object _token = Object(); // This token must be non-`const`

  static FlutterPrintPlatform _instance = MethodChannelFlutterPrint();

  /// The default instance of [FlutterPrintPlatform] to use.
  ///
  /// Defaults to [MethodChannelFlutterPrint].
  static FlutterPrintPlatform get instance => _instance;

  /// Platform-specific plugins should set this to an instance of their own
  /// platform-specific class that extends [FlutterPrintPlatform] when they register
  /// themselves.
  static set instance(FlutterPrintPlatform instance) {
    PlatformInterface.verify(instance, _token);
    _instance = instance;
  }

  /// Sends [filePath] directly to the printer.
  Future<void> print(String filePath, {PrintOptions? options}) {
    throw UnimplementedError('print() has not been implemented.');
  }

  /// Shows a print-preview or print dialog for [filePath].
  Future<void> printPreview(
    String filePath, {
    PrintOptions? options,
    required BuildContext context,
  }) {
    throw UnimplementedError('printPreview() has not been implemented.');
  }

  /// Returns all printers available on this device.
  Future<List<PrinterInfo>> listPrinters() {
    throw UnimplementedError('listPrinters() has not been implemented.');
  }

  /// Shows a native printer-picker UI (iOS only).
  Future<PrinterInfo?> pickPrinter() {
    throw UnimplementedError('pickPrinter() has not been implemented.');
  }
}
