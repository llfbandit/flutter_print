export 'src/flutter_print_platform_interface.dart'
    show
        DuplexMode,
        PageSize,
        PageMargins,
        PrintOptions,
        PrinterCapabilities,
        PrinterInfo;

import 'package:flutter/foundation.dart';

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
