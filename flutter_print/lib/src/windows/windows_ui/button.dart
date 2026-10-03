import 'package:flutter/widgets.dart';

import 'control.dart';
import 'theme.dart';

/// A WinUI button. [accent] fills it with the accent color, for the main
/// action. Disabled when [onPressed] is null.
class WinButton extends StatelessWidget {
  const WinButton({
    super.key,
    required this.onPressed,
    required this.child,
    this.accent = false,
  });

  final VoidCallback? onPressed;
  final bool accent;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = WinTheme.of(context);
    final c = theme.colors;
    return ControlBuilder(
      onPressed: onPressed,
      builder: (context, s) {
        final (Color fill, Color? stroke, Color? bottom, Color text) = accent
            ? (
                s.disabled
                    ? c.accentFillDisabled
                    : s.pressed
                    ? c.accentFillTertiary
                    : s.hovered
                    ? c.accentFillSecondary
                    : c.accentFill,
                s.disabled ? null : c.controlStrokeOnAccent,
                s.disabled || s.pressed
                    ? null
                    : c.controlStrokeOnAccentSecondary,
                s.disabled
                    ? c.textOnAccentDisabled
                    : s.pressed
                    ? c.textOnAccentSecondary
                    : c.textOnAccent,
              )
            : (
                s.disabled
                    ? c.controlFillDisabled
                    : s.pressed
                    ? c.controlFillTertiary
                    : s.hovered
                    ? c.controlFillSecondary
                    : c.controlFill,
                c.controlStroke,
                s.disabled || s.pressed ? null : c.controlStrokeSecondary,
                s.disabled
                    ? c.textDisabled
                    : s.pressed
                    ? c.textSecondary
                    : c.textPrimary,
              );
        return FocusRing(
          visible: s.focused,
          child: CustomPaint(
            painter: ControlPainter(fill: fill, stroke: stroke, bottom: bottom),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 32),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(11, 5, 11, 6),
                child: Center(
                  widthFactor: 1,
                  child: DefaultTextStyle(
                    style: theme.typography.body.copyWith(color: text),
                    textAlign: TextAlign.center,
                    child: child,
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// A borderless button showing a glyph of [WinIcons].
class WinIconButton extends StatelessWidget {
  const WinIconButton({
    super.key,
    required this.glyph,
    required this.onPressed,
    this.size = const Size.square(32),
  });

  final int glyph;
  final VoidCallback? onPressed;
  final Size size;

  @override
  Widget build(BuildContext context) {
    final c = WinTheme.of(context).colors;
    return ControlBuilder(
      onPressed: onPressed,
      builder: (context, s) => FocusRing(
        visible: s.focused,
        child: CustomPaint(
          painter: ControlPainter(
            fill: s.pressed
                ? c.subtleFillTertiary
                : s.hovered
                ? c.subtleFillSecondary
                : const Color(0x00000000),
          ),
          child: SizedBox.fromSize(
            size: size,
            child: Center(
              child: WinIcon(
                glyph,
                size: 12,
                color: s.disabled
                    ? c.textDisabled
                    : s.pressed
                    ? c.textSecondary
                    : c.textPrimary,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
