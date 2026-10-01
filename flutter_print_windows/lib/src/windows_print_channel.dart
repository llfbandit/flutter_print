import 'package:flutter/services.dart';
import 'package:flutter_print_platform_interface/flutter_print_platform_interface.dart';

/// How the plugin prints a file. It opens [other] files in their default app.
enum FileKind { pdf, image, metafile, text, other }

/// An open preview: a file laid out for a printer and paper.
typedef PreviewSession = ({int id, int pageCount});

class WindowsPrintChannel {
  static const _channel = MethodChannel('flutter_print_windows');

  static Future<FileKind> getFileKind(String filePath) async {
    final name = await _channel.invokeMethod<String>('getFileKind', {
      'filePath': filePath,
    });
    return FileKind.values.asNameMap()[name] ?? FileKind.other;
  }

  /// Opens [filePath] for preview, laid out for the printer and paper of
  /// [options]. Returns null when it can't be previewed. Close it with
  /// [closePreview].
  static Future<PreviewSession?> openPreview(
    String filePath,
    FileKind kind,
    PrintOptions options,
  ) async {
    final result = await _channel.invokeMapMethod<String, int>('openPreview', {
      'filePath': filePath,
      'kind': kind.name,
      ..._layoutArgs(options),
    });
    if (result == null) return null;
    return (id: result['id']!, pageCount: result['pageCount']!);
  }

  /// Renders a page (0-based) of a preview as the printer prints it: the
  /// whole sheet, fitted in [maxWidth] x [maxHeight] pixels, as PNG. Returns
  /// null on error.
  static Future<Uint8List?> renderPreviewPage(
    int id,
    int pageIndex,
    int maxWidth,
    int maxHeight,
  ) => _channel.invokeMethod<Uint8List>('renderPreviewPage', {
    'id': id,
    'pageIndex': pageIndex,
    'maxWidth': maxWidth,
    'maxHeight': maxHeight,
  });

  static Future<void> closePreview(int id) =>
      _channel.invokeMethod<void>('closePreview', {'id': id});

  /// Opens [filePath] in its default app, for files the dialog can't preview.
  static Future<void> openInDefaultApp(String filePath) =>
      _channel.invokeMethod<void>('openInDefaultApp', {'filePath': filePath});

  /// Returns the name of the default paper of [printerName], like `'A4'`, or
  /// null when it is not a known size.
  static Future<String?> getDefaultPaperSize(String printerName) =>
      _channel.invokeMethod<String>('getDefaultPaperSize', {
        'printerName': printerName,
      });

  // The options that change how pages are laid out.
  static Map<String, Object> _layoutArgs(PrintOptions options) => {
    'printerName': ?options.printerAddress,
    'paperSizeName': ?options.pageSize?.name,
    'paperWidth': ?options.pageSize?.width,
    'paperHeight': ?options.pageSize?.height,
    'landscape': ?options.landscape,
  };
}
