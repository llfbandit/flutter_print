import 'package:flutter/services.dart';
import 'package:flutter_print_platform_interface/flutter_print_platform_interface.dart';

/// How the plugin prints a file. It opens [other] files in their default app.
enum FileKind { pdf, image, metafile, text, other }

class WindowsPrintChannel {
  static const _channel = MethodChannel('flutter_print_windows');

  static Future<FileKind> getFileKind(String filePath) async {
    final name = await _channel.invokeMethod<String>('getFileKind', {
      'filePath': filePath,
    });
    return FileKind.values.asNameMap()[name] ?? FileKind.other;
  }

  /// Returns the page count of a PDF, image or metafile, or 0 on error.
  static Future<int> getPageCount(String filePath, FileKind kind) async =>
      await _channel.invokeMethod<int>('getPageCount', {
        'filePath': filePath,
        'kind': kind.name,
      }) ??
      0;

  /// Renders a page (0-based) of a PDF, image or metafile to PNG, or returns
  /// null.
  static Future<Uint8List?> renderPageToPng(
    String filePath,
    FileKind kind,
    int pageIndex,
    double dpi,
  ) => _channel.invokeMethod<Uint8List>('renderPageToPng', {
    'filePath': filePath,
    'kind': kind.name,
    'pageIndex': pageIndex,
    'dpi': dpi,
  });

  static Future<String?> decodeTextFile(String filePath) =>
      _channel.invokeMethod<String>('decodeTextFile', {'filePath': filePath});

  /// Opens [filePath] in its default app, for files the dialog can't preview.
  static Future<void> openInDefaultApp(String filePath) =>
      _channel.invokeMethod<void>('openInDefaultApp', {'filePath': filePath});

  /// Returns the unprintable margins in mm of [printerName] for a paper size.
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
