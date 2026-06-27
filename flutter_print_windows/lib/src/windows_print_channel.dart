import 'package:flutter/services.dart';
import 'package:flutter_print_platform_interface/flutter_print_platform_interface.dart';

class WindowsPrintChannel {
  static const _channel = MethodChannel('flutter_print_windows');

  static Future<Uint8List?> renderPdfPageToPng(
    String filePath,
    int pageIndex,
    double dpi,
  ) => _channel.invokeMethod<Uint8List>('renderPdfPageToPng', {
    'filePath': filePath,
    'pageIndex': pageIndex,
    'dpi': dpi,
  });

  static Future<String> getMimeType(String filePath) async =>
      await _channel.invokeMethod<String>('getMimeType', {
        'filePath': filePath,
      }) ??
      'application/octet-stream';

  static Future<int> getPdfPageCount(String filePath) async =>
      await _channel.invokeMethod<int>('getPdfPageCount', {
        'filePath': filePath,
      }) ??
      0;

  static Future<String?> decodeTextFile(String filePath) =>
      _channel.invokeMethod<String>('decodeTextFile', {'filePath': filePath});

  /// Opens [filePath] in its associated application (the shell "open" verb).
  /// Used by the preview flow for file types the in-app dialog cannot render.
  static Future<void> openInDefaultApp(String filePath) =>
      _channel.invokeMethod<void>('openInDefaultApp', {'filePath': filePath});

  /// Returns the hardware minimum margins (unprintable area) in mm for
  /// [printerName] with the given paper size.
  static Future<PageMargins?> getMinimumMargins({
    required String printerName,
    String? paperSizeName,
    double? paperWidth,
    double? paperHeight,
  }) async {
    final result = await _channel
        .invokeMapMethod<String, double>('getMinimumMargins', {
          'printerName': printerName,
          'paperSizeName': ?paperSizeName,
          'paperWidth': ?paperWidth,
          'paperHeight': ?paperHeight,
        });
    if (result == null) return null;
    return PageMargins(
      left: result['left'] ?? 0,
      top: result['top'] ?? 0,
      right: result['right'] ?? 0,
      bottom: result['bottom'] ?? 0,
    );
  }
}
