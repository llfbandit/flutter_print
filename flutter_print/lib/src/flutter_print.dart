import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_print_platform_interface/flutter_print_platform_interface.dart';

import 'bytes_helper/bytes_helper.dart';
import 'document_renderer.dart';

class FlutterPrint {
  FlutterPrint._();

  /// Silently prints [filePath]  using the options supplied.
  ///
  /// On web, [filePath] must be a valid URL or Blob URL.
  static Future<void> print(String filePath, {PrintOptions? options}) {
    return FlutterPrintPlatform.instance.print(filePath, options: options);
  }

  /// Shows a print-preview or print dialog for [filePath].
  ///
  /// On web, [filePath] must be a valid URL or Blob URL.
  static Future<void> printPreview(
    String filePath, {
    PrintOptions? options,
    required BuildContext context,
  }) {
    return FlutterPrintPlatform.instance.printPreview(
      filePath,
      options: options,
      context: context,
    );
  }

  /// Renders the widget returned by [builder] off-screen and prints it as a
  /// single-page PDF.
  ///
  /// [builder] receives the caller's [BuildContext], which can be used to
  /// inherit [Theme], [Localizations], or any other [InheritedWidget]:
  ///
  /// ```dart
  /// FlutterPrint.printWidget(
  ///   context: context,
  ///   (ctx) => Theme(data: Theme.of(ctx), child: MyReceiptWidget()),
  ///   options: PrintOptions(pageSize: PaperSizes.a4),
  /// );
  /// ```
  ///
  /// [dpi] controls the pixel density used when rasterising the widget.
  /// 300 DPI is suitable for most print jobs; 150 DPI is acceptable for draft
  /// output and yields files roughly four times smaller.
  ///
  /// [contentSize] decouples the widget's layout dimensions from the PDF page
  /// size. When provided, the widget is rendered at [contentSize] and centred
  /// within the page defined by `options.pageSize`.
  static Future<void> printWidget(
    WidgetBuilder builder, {
    required BuildContext context,
    PrintOptions? options,
    double dpi = 300,
    PageSize? contentSize,
  }) async {
    final bytes = await renderWidgetToPdf(
      builder: builder,
      context: context,
      dpi: dpi,
      pageSize: options?.pageSize,
      contentSize: contentSize,
      margins: options?.margins,
    );

    if (!context.mounted) return;

    final path = await bytesToPath(bytes);
    await FlutterPrintPlatform.instance.print(path, options: options);
  }

  /// Renders the widget returned by [builder] off-screen and opens the
  /// platform print-preview or print dialog for the resulting PDF.
  ///
  /// Behaves like [printWidget] but passes the PDF through
  /// [FlutterPrintPlatform.printPreview] instead of printing silently.
  /// On platforms where the print dialog already includes a preview step
  /// (Android, iOS), this is identical to [printWidget].
  ///
  /// [contentSize] works identically to [printWidget.contentSize].
  static Future<void> printWidgetPreview(
    WidgetBuilder builder, {
    required BuildContext context,
    PrintOptions? options,
    double dpi = 300,
    PageSize? contentSize,
  }) async {
    final bytes = await renderWidgetToPdf(
      builder: builder,
      context: context,
      dpi: dpi,
      pageSize: options?.pageSize,
      contentSize: contentSize,
      margins: options?.margins,
    );

    if (!context.mounted) return;
    final path = await bytesToPath(bytes);
    if (!context.mounted) return;

    await FlutterPrintPlatform.instance.printPreview(
      path,
      options: options,
      context: context,
    );
  }

  /// Renders the widget returned by [builder] off-screen and returns the result
  /// as PNG image bytes for in-app preview.
  ///
  /// Use [Image.memory] to display the returned bytes:
  ///
  /// ```dart
  /// final png = await FlutterPrint.previewWidget(
  ///   (ctx) => Theme(data: Theme.of(ctx), child: MyReceiptWidget()),
  ///   context: context,
  ///   options: PrintOptions(pageSize: PaperSizes.a4),
  /// );
  /// // ...
  /// Image.memory(png)
  /// ```
  ///
  /// [contentSize] works identically to [printWidget.contentSize].
  static Future<Uint8List> previewWidget(
    WidgetBuilder builder, {
    required BuildContext context,
    PrintOptions? options,
    PageSize? contentSize,
  }) => renderWidgetToImage(
    builder: builder,
    context: context,
    dpi: MediaQuery.of(context).devicePixelRatio * 96,
    pageSize: options?.pageSize,
    contentSize: contentSize,
    margins: options?.margins,
  );

  /// Returns the list of printers available on this device.
  ///
  /// Returns an empty list on platforms without an enumeration API
  /// (Android, iOS, Web).
  static Future<List<PrinterInfo>> listPrinters() {
    return FlutterPrintPlatform.instance.listPrinters();
  }

  /// iOS-specific extensions. Returns `null` on all other platforms.
  ///
  /// ```dart
  /// final printer = await FlutterPrint.ios?.pickPrinter();
  /// ```
  static FlutterPrintIOS? get ios =>
      defaultTargetPlatform == TargetPlatform.iOS ? FlutterPrintIOS._() : null;
}

/// iOS-specific print APIs exposed via [FlutterPrint.ios].
final class FlutterPrintIOS {
  FlutterPrintIOS._();

  /// Shows the native AirPrint printer-picker sheet and returns the selected
  /// printer, or `null` if the user cancelled.
  ///
  /// The [PrinterInfo.address] of the returned printer is the full AirPrint
  /// URL (e.g. `ipp://MyPrinter.local./ipp/print`). Pass it as
  /// [PrintOptions.printerAddress] to print directly to that printer.
  /// ```
  Future<PrinterInfo?> pickPrinter() {
    return FlutterPrintPlatform.instance.pickPrinter();
  }
}
