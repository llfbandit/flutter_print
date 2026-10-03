import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'theme.dart';

/// Tracks whether the last input came from a pointer. Windows shows focus
/// rings only when the keyboard moves the focus, not after a click.
abstract final class _LastInput {
  static bool pointer = false;
  static bool _listening = false;

  static void listen() {
    if (_listening) return;
    _listening = true;
    GestureBinding.instance.pointerRouter.addGlobalRoute((event) {
      if (event is PointerDownEvent) pointer = true;
    });
    // Called before the focus system handles the key, e.g. moves on Tab.
    HardwareKeyboard.instance.addHandler((_) {
      pointer = false;
      return false;
    });
  }
}

/// The look a control takes for its state.
class ControlStates {
  const ControlStates({
    this.hovered = false,
    this.pressed = false,
    this.focused = false,
    this.disabled = false,
  });

  final bool hovered;
  final bool pressed;

  /// Focused from the keyboard: shows the focus ring.
  final bool focused;
  final bool disabled;
}

/// Tracks hover, press and keyboard focus, and calls [onPressed] on a click,
/// or on Enter or Space. Disabled when [onPressed] is null.
class ControlBuilder extends StatefulWidget {
  const ControlBuilder({
    super.key,
    required this.onPressed,
    required this.builder,
    this.focusNode,
    this.shortcuts,
    this.actions,
  });

  final VoidCallback? onPressed;
  final Widget Function(BuildContext context, ControlStates states) builder;
  final FocusNode? focusNode;
  final Map<ShortcutActivator, Intent>? shortcuts;
  final Map<Type, Action<Intent>>? actions;

  @override
  State<ControlBuilder> createState() => _ControlBuilderState();
}

class _ControlBuilderState extends State<ControlBuilder> {
  bool _hovered = false;
  bool _pressed = false;
  bool _focused = false;
  FocusNode? _ownFocus;

  FocusNode get _focus => widget.focusNode ?? (_ownFocus ??= FocusNode());

  @override
  void initState() {
    super.initState();
    _LastInput.listen();
  }

  @override
  void dispose() {
    _ownFocus?.dispose();
    super.dispose();
  }

  // A click focuses the control, as in Windows, without the focus ring.
  void _onTapDown() {
    _setPressed(true);
    _focus.requestFocus();
  }

  void _setPressed(bool pressed) {
    if (_pressed != pressed) setState(() => _pressed = pressed);
  }

  @override
  Widget build(BuildContext context) {
    final onPressed = widget.onPressed;
    final enabled = onPressed != null;
    return FocusableActionDetector(
      enabled: enabled,
      focusNode: _focus,
      // The arrow, also inside a text box.
      mouseCursor: SystemMouseCursors.basic,
      shortcuts: widget.shortcuts,
      actions: {
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (_) => onPressed?.call(),
        ),
        ...?widget.actions,
      },
      onShowHoverHighlight: (v) => setState(() => _hovered = v),
      // Decide when the focus comes, from the input that moved it.
      onShowFocusHighlight: (v) =>
          setState(() => _focused = v && !_LastInput.pointer),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: enabled ? (_) => _onTapDown() : null,
        onTapUp: enabled ? (_) => _setPressed(false) : null,
        onTapCancel: enabled ? () => _setPressed(false) : null,
        onTap: onPressed,
        child: widget.builder(
          context,
          ControlStates(
            hovered: enabled && _hovered,
            pressed: enabled && _pressed,
            focused: enabled && _focused,
            disabled: !enabled,
          ),
        ),
      ),
    );
  }
}

/// Paints a control's fill and border. [bottom] draws the bottom edge of the
/// border in another color, as WinUI's elevation borders do.
class ControlPainter extends CustomPainter {
  const ControlPainter({
    required this.fill,
    this.stroke,
    this.bottom,
    this.bottomWidth = 1,
    this.radius = 4,
  });

  final Color fill;
  final Color? stroke;
  final Color? bottom;
  final double bottomWidth;
  final double radius;

  @override
  void paint(Canvas canvas, Size size) {
    final rrect = RRect.fromRectAndRadius(
      Offset.zero & size,
      Radius.circular(radius),
    );
    canvas.drawRRect(rrect, Paint()..color = fill);
    final stroke = this.stroke;
    if (stroke != null) {
      canvas.drawRRect(
        rrect.deflate(0.5),
        Paint()
          ..style = PaintingStyle.stroke
          ..color = stroke,
      );
    }
    final bottom = this.bottom;
    if (bottom != null) {
      canvas.save();
      canvas.clipRRect(rrect);
      canvas.drawRect(
        Rect.fromLTWH(0, size.height - bottomWidth, size.width, bottomWidth),
        Paint()..color = bottom,
      );
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(ControlPainter old) =>
      fill != old.fill ||
      stroke != old.stroke ||
      bottom != old.bottom ||
      bottomWidth != old.bottomWidth ||
      radius != old.radius;
}

/// Draws the keyboard focus ring around [child], 3 pixels outside it.
class FocusRing extends StatelessWidget {
  const FocusRing({
    super.key,
    required this.visible,
    required this.child,
    this.radius = 4,
  });

  final bool visible;
  final double radius;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!visible) return child;
    final colors = WinTheme.of(context).colors;
    return CustomPaint(
      foregroundPainter: _FocusRingPainter(
        outer: colors.focusOuter,
        inner: colors.focusInner,
        radius: radius,
      ),
      child: child,
    );
  }
}

class _FocusRingPainter extends CustomPainter {
  const _FocusRingPainter({
    required this.outer,
    required this.inner,
    required this.radius,
  });

  final Color outer;
  final Color inner;
  final double radius;

  @override
  void paint(Canvas canvas, Size size) {
    final rrect = RRect.fromRectAndRadius(
      Offset.zero & size,
      Radius.circular(radius),
    );
    canvas.drawRRect(
      rrect.inflate(0.5),
      Paint()
        ..style = PaintingStyle.stroke
        ..color = inner,
    );
    canvas.drawRRect(
      rrect.inflate(2),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = outer,
    );
  }

  @override
  bool shouldRepaint(_FocusRingPainter old) =>
      outer != old.outer || inner != old.inner || radius != old.radius;
}

/// Glyphs of the Segoe Fluent Icons font, or Segoe MDL2 Assets before
/// Windows 11.
abstract final class WinIcons {
  static const chevronDown = 0xE70D;
  static const chevronUp = 0xE70E;
}

class WinIcon extends StatelessWidget {
  const WinIcon(this.glyph, {super.key, this.size = 16, this.color});

  final int glyph;
  final double size;

  /// Defaults to the text color.
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return Text(
      String.fromCharCode(glyph),
      style: TextStyle(
        fontFamily: 'Segoe Fluent Icons',
        fontFamilyFallback: const ['Segoe MDL2 Assets'],
        fontSize: size,
        height: 1,
        // Flutter draws glyphs thinner than Windows does: embolden them.
        fontWeight: FontWeight.w600,
        color: color ?? DefaultTextStyle.of(context).style.color,
      ),
    );
  }
}
