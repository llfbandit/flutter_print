import 'dart:typed_data';

import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'flutter_print_method_channel.dart';
import 'messages.g.dart';

export 'messages.g.dart'
    show DuplexMode, PageSize, PageMargins, PrintOptions, PrinterCapabilities, PrinterInfo;

abstract class FlutterPrintPlatform extends PlatformInterface {
  FlutterPrintPlatform() : super(token: _token);

  static final Object _token = Object();

  static FlutterPrintPlatform _instance = MethodChannelFlutterPrint();

  static FlutterPrintPlatform get instance => _instance;

  static set instance(FlutterPrintPlatform instance) {
    PlatformInterface.verifyToken(instance, _token);
    _instance = instance;
  }

  Future<void> print(String filePath, {PrintOptions? options}) {
    throw UnimplementedError('print() has not been implemented.');
  }

  Future<void> printBytes(
    Uint8List bytes, {
    PrintOptions? options,
    bool directPrint = false,
  }) {
    throw UnimplementedError('printBytes() has not been implemented.');
  }

  Future<void> printPreview(String filePath, {PrintOptions? options}) {
    throw UnimplementedError('printPreview() has not been implemented.');
  }

  Future<List<PrinterInfo>> listPrinters() {
    throw UnimplementedError('listPrinters() has not been implemented.');
  }

  Future<PrinterInfo?> pickPrinter() {
    throw UnimplementedError('pickPrinter() has not been implemented.');
  }
}
