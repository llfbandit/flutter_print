export 'src/flutter_print_platform_interface.dart'
    show
        DuplexMode,
        PageSize,
        PageMargins,
        PrintOptions,
        PrinterCapabilities,
        PrinterInfo;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import 'src/document_renderer.dart';
import 'src/flutter_print_platform_interface.dart';

/// Named paper-size presets.
///
/// All dimensions are in millimetres (width × height in portrait orientation).
abstract final class PaperSizes {
  // ISO 216 A-series
  static PageSize get a0 => PageSize(name: 'A0', width: 841.0, height: 1189.0);
  static PageSize get a1 => PageSize(name: 'A1', width: 594.0, height: 841.0);
  static PageSize get a2 => PageSize(name: 'A2', width: 420.0, height: 594.0);
  static PageSize get a3 => PageSize(name: 'A3', width: 297.0, height: 420.0);
  static PageSize get a4 => PageSize(name: 'A4', width: 210.0, height: 297.0);
  static PageSize get a5 => PageSize(name: 'A5', width: 148.0, height: 210.0);
  static PageSize get a6 => PageSize(name: 'A6', width: 105.0, height: 148.0);

  // ISO 216 B-series
  static PageSize get b4 => PageSize(name: 'B4', width: 250.0, height: 353.0);
  static PageSize get b5 => PageSize(name: 'B5', width: 176.0, height: 250.0);

  // North American
  static PageSize get letter =>
      PageSize(name: 'Letter', width: 215.9, height: 279.4);
  static PageSize get legal =>
      PageSize(name: 'Legal', width: 215.9, height: 355.6);
  static PageSize get tabloid =>
      PageSize(name: 'Tabloid', width: 279.4, height: 431.8);
  static PageSize get executive =>
      PageSize(name: 'Executive', width: 184.2, height: 266.7);

  // Japanese
  static PageSize get jisB4 =>
      PageSize(name: 'JIS B4', width: 257.0, height: 364.0);
  static PageSize get jisB5 =>
      PageSize(name: 'JIS B5', width: 182.0, height: 257.0);

  // Envelopes
  static PageSize get c5 => PageSize(name: 'C5', width: 162.0, height: 229.0);
  static PageSize get dl => PageSize(name: 'DL', width: 110.0, height: 220.0);
}

class FlutterPrint {
  FlutterPrint._();

  /// Prints [filePath], optionally bypassing the system dialog.
  ///
  /// When [directPrint] is `true`the plugin attempts a silent
  /// print using the options supplied. On platforms where silent printing is
  /// not possible the native print dialog is opened instead so the user can
  /// supply any missing settings.
  ///
  /// When [directPrint] is `false` (the default) the native print dialog is always shown,
  /// giving the user full control over printer selection and settings.
  ///
  /// Platform behaviour:
  ///
  /// On web, [filePath] must be a valid URL or Blob URL.
  ///
  /// | Platform | `directPrint: true`            | `directPrint: false`       |
  /// |----------|--------------------------------|----------------------------|
  /// | Android  | Print dialog                   | Print dialog               |
  /// | iOS      | Direct if `printerAddress` set | Print dialog               |
  /// | macOS    | Direct                         | Print dialog               |
  /// | Windows  | Direct                         | Print dialog or default app|
  /// | Linux    | Direct                         | Default app                |
  /// | Web      | Print dialog                   | Print dialog               |
  static Future<void> print(
    String filePath, {
    PrintOptions? options,
    bool directPrint = false,
  }) => directPrint
      ? FlutterPrintPlatform.instance.print(filePath, options: options)
      : FlutterPrintPlatform.instance.printPreview(filePath, options: options);

  /// Renders the widget returned by [builder] off-screen and prints it as a
  /// single-page PDF.
  ///
  /// [builder] receives the caller's [BuildContext], which can be used to
  /// inherit [Theme], [Localizations], or any other [InheritedWidget]:
  ///
  /// ```dart
  /// FlutterPrint.printDocument(
  ///   context: context,
  ///   (ctx) => Theme(data: Theme.of(ctx), child: MyReceiptWidget()),
  ///   options: PrintOptions(pageSize: PaperSizes.a4),
  /// );
  /// ```
  ///
  /// [MediaQuery.size] and [MediaQuery.devicePixelRatio] are always overridden
  /// to match the content area so the widget lays out for the page, not the
  /// screen.
  ///
  /// The printable area is derived from [options]:
  /// - **Page size** — `options.pageSize` (defaults to A4 when `null`).
  /// - **Margins** — `options.margins` (defaults to no margins when `null`).
  ///
  /// [dpi] controls the pixel density used when rasterising the widget.
  /// Higher values produce sharper output at the cost of a larger PDF.
  /// 300 DPI is suitable for most print jobs; 150 DPI is acceptable for
  /// draft output and yields files roughly four times smaller.
  ///
  /// [contentSize] decouples the widget's layout dimensions from the PDF page
  /// size. When provided, the widget is rendered at [contentSize] and centred
  /// within the page defined by `options.pageSize`. This is useful when the
  /// widget has fixed or card-like proportions that should not fill the entire
  /// page.
  ///
  /// ```dart
  /// FlutterPrint.printDocument(
  ///   context: context,
  ///   (ctx) => Theme(data: Theme.of(ctx), child: BusinessCard()),
  ///   options: PrintOptions(pageSize: PaperSizes.a4),
  ///   contentSize: PageSize(name: 'Business Card', width: 85.6, height: 54.0),
  /// );
  /// ```
  ///
  /// When [contentSize] is `null` the widget fills the full printable area of
  /// the page (original behaviour).
  static Future<void> printWidget(
    WidgetBuilder builder, {
    required BuildContext context,
    PrintOptions? options,
    bool directPrint = false,
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
    await FlutterPrintPlatform.instance.printBytes(
      bytes,
      options: options,
      directPrint: directPrint,
    );
  }

  /// Renders the widget returned by [builder] off-screen and returns the result
  /// as PNG image bytes for in-app preview.
  ///
  /// Use [Image.memory] to display the returned bytes:
  ///
  /// ```dart
  /// final png = await FlutterPrint.previewDocument(
  ///   (ctx) => Theme(data: Theme.of(ctx), child: MyReceiptWidget()),
  ///   context: context,
  ///   options: PrintOptions(pageSize: PaperSizes.a4),
  /// );
  /// // …
  /// Image.memory(png)
  /// ```
  ///
  /// [contentSize] works identically to [printWidget.contentSize]: the widget
  /// is rendered at [contentSize] and would be centred on `options.pageSize`
  /// if later passed to [printWidget].
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
  static Future<List<PrinterInfo>> listPrinters() =>
      FlutterPrintPlatform.instance.listPrinters();

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
  /// [PrintOptions.printerAddress] to print directly to that printer:
  ///
  /// ```dart
  /// final printer = await FlutterPrint.ios?.pickPrinter();
  /// if (printer != null) {
  ///   await FlutterPrint.print(
  ///     '/path/to/doc.pdf',
  ///     options: PrintOptions(printerAddress: printer.address, ...),
  ///     directPrint: true,
  ///   );
  /// }
  /// ```
  Future<PrinterInfo?> pickPrinter() =>
      FlutterPrintPlatform.instance.pickPrinter();
}
