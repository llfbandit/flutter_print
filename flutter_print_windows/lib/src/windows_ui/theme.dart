import 'package:flutter/widgets.dart';

/// The Windows accent color and its shades.
class AccentPalette {
  const AccentPalette({
    required this.light2,
    required this.base,
    required this.dark1,
  });

  /// The Windows 11 default blue.
  static const blue = AccentPalette(
    light2: Color(0xFF4CC2FF),
    base: Color(0xFF0078D4),
    dark1: Color(0xFF005FB8),
  );

  /// Reads the 7 shades of the Windows accent palette, lightest first, as
  /// ARGB values. Returns [blue] when [shades] isn't that.
  factory AccentPalette.fromShades(List<int>? shades) {
    if (shades == null || shades.length != 7) return blue;
    return AccentPalette(
      light2: Color(shades[1]),
      base: Color(shades[3]),
      dark1: Color(shades[4]),
    );
  }

  final Color light2;
  final Color base;
  final Color dark1;
}

/// The WinUI 3 theme colors the controls use.
class WinColors {
  const WinColors._({
    required this.textPrimary,
    required this.textSecondary,
    required this.textTertiary,
    required this.textDisabled,
    required this.textOnAccent,
    required this.textOnAccentSecondary,
    required this.textOnAccentDisabled,
    required this.controlFill,
    required this.controlFillSecondary,
    required this.controlFillTertiary,
    required this.controlFillDisabled,
    required this.controlFillInputActive,
    required this.controlStroke,
    required this.controlStrokeSecondary,
    required this.controlStrongStroke,
    required this.controlStrokeOnAccent,
    required this.controlStrokeOnAccentSecondary,
    required this.subtleFillSecondary,
    required this.subtleFillTertiary,
    required this.accentFill,
    required this.accentFillDisabled,
    required this.cardBackground,
    required this.cardStroke,
    required this.divider,
    required this.solidBackground,
    required this.layerAlt,
    required this.surfaceStroke,
    required this.flyoutBackground,
    required this.flyoutStroke,
    required this.critical,
    required this.focusOuter,
    required this.focusInner,
  });

  factory WinColors.light(AccentPalette accent) => WinColors._(
    textPrimary: const Color(0xE4000000),
    textSecondary: const Color(0x9E000000),
    textTertiary: const Color(0x72000000),
    textDisabled: const Color(0x5C000000),
    textOnAccent: const Color(0xFFFFFFFF),
    textOnAccentSecondary: const Color(0xB3FFFFFF),
    textOnAccentDisabled: const Color(0xFFFFFFFF),
    controlFill: const Color(0xB3FFFFFF),
    controlFillSecondary: const Color(0x80F9F9F9),
    controlFillTertiary: const Color(0x4DF9F9F9),
    controlFillDisabled: const Color(0x4DF9F9F9),
    controlFillInputActive: const Color(0xFFFFFFFF),
    // Stronger than WinUI's 0x0F and 0x29: Flutter's thinner text makes them
    // look fainter than in native apps.
    controlStroke: const Color(0x1A000000),
    controlStrokeSecondary: const Color(0x3D000000),
    controlStrongStroke: const Color(0x72000000),
    controlStrokeOnAccent: const Color(0x14FFFFFF),
    controlStrokeOnAccentSecondary: const Color(0x66000000),
    subtleFillSecondary: const Color(0x09000000),
    subtleFillTertiary: const Color(0x06000000),
    accentFill: accent.dark1,
    accentFillDisabled: const Color(0x37000000),
    cardBackground: const Color(0xB3FFFFFF),
    cardStroke: const Color(0x0F000000),
    divider: const Color(0x0F000000),
    solidBackground: const Color(0xFFF3F3F3),
    layerAlt: const Color(0xFFFFFFFF),
    surfaceStroke: const Color(0x66757575),
    flyoutBackground: const Color(0xFFFCFCFC),
    flyoutStroke: const Color(0x0F000000),
    critical: const Color(0xFFC42B1C),
    focusOuter: const Color(0xE4000000),
    focusInner: const Color(0xB3FFFFFF),
  );

  factory WinColors.dark(AccentPalette accent) => WinColors._(
    textPrimary: const Color(0xFFFFFFFF),
    textSecondary: const Color(0xC5FFFFFF),
    textTertiary: const Color(0x87FFFFFF),
    textDisabled: const Color(0x5DFFFFFF),
    textOnAccent: const Color(0xFF000000),
    textOnAccentSecondary: const Color(0x80000000),
    textOnAccentDisabled: const Color(0x87FFFFFF),
    controlFill: const Color(0x0FFFFFFF),
    controlFillSecondary: const Color(0x15FFFFFF),
    controlFillTertiary: const Color(0x08FFFFFF),
    controlFillDisabled: const Color(0x0BFFFFFF),
    controlFillInputActive: const Color(0xB31E1E1E),
    // Stronger than WinUI's 0x12 and 0x18, as in light.
    controlStroke: const Color(0x1FFFFFFF),
    controlStrokeSecondary: const Color(0x2AFFFFFF),
    controlStrongStroke: const Color(0x8BFFFFFF),
    controlStrokeOnAccent: const Color(0x14FFFFFF),
    controlStrokeOnAccentSecondary: const Color(0x23000000),
    subtleFillSecondary: const Color(0x0FFFFFFF),
    subtleFillTertiary: const Color(0x0AFFFFFF),
    accentFill: accent.light2,
    accentFillDisabled: const Color(0x28FFFFFF),
    cardBackground: const Color(0x0DFFFFFF),
    cardStroke: const Color(0x19000000),
    divider: const Color(0x15FFFFFF),
    solidBackground: const Color(0xFF202020),
    layerAlt: const Color(0x0DFFFFFF),
    surfaceStroke: const Color(0x66757575),
    flyoutBackground: const Color(0xFF2C2C2C),
    flyoutStroke: const Color(0x33000000),
    critical: const Color(0xFFFF99A4),
    focusOuter: const Color(0xFFFFFFFF),
    focusInner: const Color(0xB3000000),
  );

  final Color textPrimary;
  final Color textSecondary;
  final Color textTertiary;
  final Color textDisabled;
  final Color textOnAccent;
  final Color textOnAccentSecondary;
  final Color textOnAccentDisabled;
  final Color controlFill;
  final Color controlFillSecondary;
  final Color controlFillTertiary;
  final Color controlFillDisabled;
  final Color controlFillInputActive;
  final Color controlStroke;
  final Color controlStrokeSecondary;
  final Color controlStrongStroke;
  final Color controlStrokeOnAccent;
  final Color controlStrokeOnAccentSecondary;
  final Color subtleFillSecondary;
  final Color subtleFillTertiary;
  final Color accentFill;
  final Color accentFillDisabled;
  final Color cardBackground;
  final Color cardStroke;
  final Color divider;
  final Color solidBackground;
  final Color layerAlt;
  final Color surfaceStroke;
  final Color flyoutBackground;
  final Color flyoutStroke;
  final Color critical;
  final Color focusOuter;
  final Color focusInner;

  /// The accent fill on hover.
  Color get accentFillSecondary => accentFill.withValues(alpha: 0.9);

  /// The accent fill when pressed.
  Color get accentFillTertiary => accentFill.withValues(alpha: 0.8);
}

/// The WinUI 3 type ramp, in Segoe UI Variable, or Segoe UI before
/// Windows 11.
class WinTypography {
  WinTypography(Color color)
    : body = _style(14, 20, FontWeight.normal, color),
      bodyStrong = _style(14, 20, FontWeight.w600, color),
      subtitle = _style(20, 28, FontWeight.w600, color, display: true);

  final TextStyle body;
  final TextStyle bodyStrong;
  final TextStyle subtitle;

  static TextStyle _style(
    double size,
    double lineHeight,
    FontWeight weight,
    Color color, {
    bool display = false,
  }) => TextStyle(
    fontFamily: display
        ? 'Segoe UI Variable Display'
        : 'Segoe UI Variable Text',
    fontFamilyFallback: const ['Segoe UI'],
    fontSize: size,
    height: lineHeight / size,
    fontWeight: weight,
    color: color,
    decoration: TextDecoration.none,
  );
}

class WinThemeData {
  WinThemeData({required this.brightness, AccentPalette? accent})
    : colors = brightness == Brightness.dark
          ? WinColors.dark(accent ?? AccentPalette.blue)
          : WinColors.light(accent ?? AccentPalette.blue) {
    typography = WinTypography(colors.textPrimary);
  }

  final Brightness brightness;
  final WinColors colors;
  late final WinTypography typography;
}

/// Gives the Windows theme to the controls below it, with the body text
/// style.
class WinTheme extends InheritedWidget {
  WinTheme({super.key, required this.data, required Widget child})
    : super(
        child: DefaultTextStyle(style: data.typography.body, child: child),
      );

  final WinThemeData data;

  static WinThemeData of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<WinTheme>()!.data;

  @override
  bool updateShouldNotify(WinTheme old) => data != old.data;
}
