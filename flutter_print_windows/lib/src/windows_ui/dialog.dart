import 'package:flutter/widgets.dart';

import 'theme.dart';

/// A WinUI content dialog: [title] and [content] over a footer with the
/// [actions], which share its width.
class WinDialog extends StatelessWidget {
  const WinDialog({
    super.key,
    required this.title,
    required this.content,
    required this.actions,
    this.constraints = const BoxConstraints(maxWidth: 548),
  });

  final Widget title;
  final Widget content;
  final List<Widget> actions;
  final BoxConstraints constraints;

  @override
  Widget build(BuildContext context) {
    final theme = WinTheme.of(context);
    final c = theme.colors;
    return Center(
      child: ConstrainedBox(
        constraints: constraints,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: c.solidBackground,
            border: Border.all(color: c.surfaceStroke),
            borderRadius: BorderRadius.circular(8),
            boxShadow: const [
              BoxShadow(
                color: Color(0x47000000),
                blurRadius: 64,
                offset: Offset(0, 32),
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(7),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ColoredBox(
                  color: c.layerAlt,
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        DefaultTextStyle(
                          style: theme.typography.subtitle,
                          child: title,
                        ),
                        const SizedBox(height: 12),
                        content,
                      ],
                    ),
                  ),
                ),
                Container(
                  decoration: BoxDecoration(
                    border: Border(top: BorderSide(color: c.cardStroke)),
                  ),
                  padding: const EdgeInsets.all(24),
                  child: Row(
                    children: [
                      for (final (i, action) in actions.indexed) ...[
                        if (i > 0) const SizedBox(width: 8),
                        Expanded(child: action),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
