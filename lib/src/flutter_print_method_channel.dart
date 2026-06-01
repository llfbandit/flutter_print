import 'package:flutter/foundation.dart';

import 'flutter_print_platform_interface.dart';
import 'messages.g.dart';

class MethodChannelFlutterPrint extends FlutterPrintPlatform {
  @visibleForTesting
  FlutterPrintApi api = FlutterPrintApi();

  @override
  Future<void> print(String filePath, {PrintOptions? options}) =>
      api.print(filePath, options ?? _defaults());

  @override
  Future<void> printPreview(String filePath, {PrintOptions? options}) =>
      api.printPreview(filePath, options ?? _defaults());

  @override
  Future<List<PrinterInfo>> listPrinters() => api.listPrinters();

  @override
  Future<PrinterInfo?> pickPrinter() => api.pickPrinter();

  static PrintOptions _defaults() =>
      PrintOptions(copies: 1, landscape: false, color: true);
}
