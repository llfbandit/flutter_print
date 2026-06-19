import 'package:flutter/services.dart';

class WindowsPrintChannel {
  static const _channel = MethodChannel('flutter_print_windows');

  static Future<Uint8List?> renderPdfPageToPng(
    String filePath,
    int pageIndex,
    double dpi,
  ) => _channel.invokeMethod<Uint8List>(
        'renderPdfPageToPng',
        {'filePath': filePath, 'pageIndex': pageIndex, 'dpi': dpi},
      );

  static Future<String> getMimeType(String filePath) async =>
      await _channel.invokeMethod<String>(
        'getMimeType',
        {'filePath': filePath},
      ) ??
      'application/octet-stream';

  static Future<int> getPdfPageCount(String filePath) async =>
      await _channel.invokeMethod<int>(
        'getPdfPageCount',
        {'filePath': filePath},
      ) ??
      0;

  static Future<String?> decodeTextFile(String filePath) =>
      _channel.invokeMethod<String>(
        'decodeTextFile',
        {'filePath': filePath},
      );
}
