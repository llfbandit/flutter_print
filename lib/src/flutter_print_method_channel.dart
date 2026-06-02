import 'dart:io';

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
  Future<void> printBytes(
    Uint8List bytes, {
    PrintOptions? options,
    bool directPrint = false,
  }) async {
    final file = File(
      '${Directory.systemTemp.path}${Platform.pathSeparator}'
      'flutter_print_${DateTime.now().millisecondsSinceEpoch}.pdf',
    );
    try {
      await file.writeAsBytes(bytes, flush: true);
      if (directPrint) {
        await api.print(file.path, options ?? _defaults());
      } else {
        await api.printPreview(file.path, options ?? _defaults());
      }
    } finally {
      if (file.existsSync()) await file.delete();
    }
  }

  @override
  Future<List<PrinterInfo>> listPrinters() => api.listPrinters();

  @override
  Future<PrinterInfo?> pickPrinter() => api.pickPrinter();

  static PrintOptions _defaults() =>
      PrintOptions(copies: 1, landscape: false, color: true);
}
