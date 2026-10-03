import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import 'theme.dart';

/// An indeterminate WinUI progress ring, in the accent color.
class WinProgressRing extends StatefulWidget {
  const WinProgressRing({super.key, this.size = 32, this.strokeWidth = 4});

  final double size;
  final double strokeWidth;

  @override
  State<WinProgressRing> createState() => _WinProgressRingState();
}

class _WinProgressRingState extends State<WinProgressRing>
    with SingleTickerProviderStateMixin {
  late final _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2000),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox.square(
      dimension: widget.size,
      child: CustomPaint(
        painter: _RingPainter(
          _controller,
          WinTheme.of(context).colors.accentFill,
          widget.strokeWidth,
        ),
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  _RingPainter(this.t, this.color, this.strokeWidth) : super(repaint: t);

  final Animation<double> t;
  final Color color;
  final double strokeWidth;

  @override
  void paint(Canvas canvas, Size size) {
    // The arc grows then shrinks while it turns.
    final v = t.value;
    final sweep =
        math.pi * (0.1 + 1.3 * (0.5 - 0.5 * math.cos(2 * math.pi * v)));
    final start = 2 * math.pi * 1.5 * v - math.pi / 2;
    final rect = (Offset.zero & size).deflate(strokeWidth / 2);
    canvas.drawArc(
      rect,
      start,
      sweep,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth
        ..strokeCap = StrokeCap.round
        ..color = color,
    );
  }

  @override
  bool shouldRepaint(_RingPainter old) =>
      color != old.color || strokeWidth != old.strokeWidth;
}
