import 'package:flutter_print_platform_interface/flutter_print_platform_interface.dart';

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
