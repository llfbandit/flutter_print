import 'dart:async';
import 'dart:ui' show lerpDouble;

import 'package:flutter/gestures.dart' show PointerHoverEvent;
import 'package:flutter/widgets.dart';

import 'theme.dart';

// Scrollbar thumb thickness, thin until the pointer comes near.
const _thin = 3.0;
const _wide = 8.0;

// Width near the edge that widens the scrollbar.
const _hoverWidth = 16.0;

// As Windows: widen after a short hover, shrink back a while after leaving.
const _widenDelay = Duration(milliseconds: 250);
const _shrinkDelay = Duration(milliseconds: 700);
const _resize = Duration(milliseconds: 150);

/// Windows scrollbars, and no overscroll glow, whatever the app uses.
class WinScrollBehavior extends ScrollBehavior {
  const WinScrollBehavior(this.colors);

  final WinColors colors;

  @override
  Widget buildScrollbar(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) {
    return WinScrollbar(
      controller: details.controller,
      axis: axisDirectionToAxis(details.direction),
      color: colors.controlStrongStroke,
      child: child,
    );
  }

  @override
  Widget buildOverscrollIndicator(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) => child;

  @override
  bool shouldNotify(covariant WinScrollBehavior oldDelegate) =>
      colors != oldDelegate.colors;
}

/// A thin scrollbar that widens while the pointer is near it, so it's easy
/// to grab. [WinScrollBehavior] adds one to each scroll view; place one to
/// show the scroll view of [controller] elsewhere, e.g. outside a nested
/// one.
class WinScrollbar extends StatefulWidget {
  const WinScrollbar({
    super.key,
    required this.controller,
    required this.axis,
    required this.color,
    required this.child,
    this.nested = false,
  });

  final ScrollController? controller;
  final Axis axis;
  final Color color;
  final Widget child;

  /// Follows a scroll view nested in [child], not [child] itself.
  final bool nested;

  @override
  State<WinScrollbar> createState() => _WinScrollbarState();
}

class _WinScrollbarState extends State<WinScrollbar>
    with SingleTickerProviderStateMixin {
  late final _width = AnimationController(vsync: this, duration: _resize);
  late final _curve = CurvedAnimation(parent: _width, curve: Curves.easeOut);
  Timer? _timer;
  bool _near = false;

  @override
  void dispose() {
    _timer?.cancel();
    _curve.dispose();
    _width.dispose();
    super.dispose();
  }

  void _setNear(bool near) {
    if (near == _near) return;
    _near = near;
    _timer?.cancel();
    _timer = Timer(near ? _widenDelay : _shrinkDelay, () {
      if (!mounted) return;
      near ? _width.forward() : _width.reverse();
    });
  }

  void _onHover(PointerHoverEvent event) {
    final size = context.size;
    if (size == null) return;
    final p = event.localPosition;
    _setNear(
      widget.axis == Axis.vertical
          ? p.dx >= size.width - _hoverWidth
          : p.dy >= size.height - _hoverWidth,
    );
  }

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onHover: _onHover,
      onExit: (_) => _setNear(false),
      child: AnimatedBuilder(
        animation: _curve,
        builder: (context, child) {
          final thickness = lerpDouble(_thin, _wide, _curve.value)!;
          return RawScrollbar(
            controller: widget.controller,
            notificationPredicate: (n) =>
                n.metrics.axis == widget.axis &&
                (widget.nested || n.depth == 0),
            thumbVisibility: true,
            thickness: thickness,
            radius: Radius.circular(thickness / 2),
            crossAxisMargin: 2,
            mainAxisMargin: 4,
            thumbColor: widget.color,
            child: child!,
          );
        },
        child: widget.child,
      ),
    );
  }
}
