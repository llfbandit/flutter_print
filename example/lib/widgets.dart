import 'package:flutter/material.dart';
import 'package:flutter_print/flutter_print.dart';

class SectionCard extends StatelessWidget {
  const SectionCard({super.key, this.title, required this.child});
  final String? title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (title != null) ...[
              Text(title!, style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 10),
            ],
            child,
          ],
        ),
      ),
    );
  }
}

class CapabilitiesChips extends StatelessWidget {
  const CapabilitiesChips(this.caps, {super.key});
  final PrinterCapabilities caps;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 6,
      children: [
        if (caps.supportsColor case final v?)
          Chip(
            avatar: Icon(
              v ? Icons.color_lens : Icons.invert_colors_off,
              size: 16,
            ),
            label: Text(v ? 'Color' : 'Mono only'),
            visualDensity: VisualDensity.compact,
          ),
        if (caps.supportsDuplex case final v?)
          Chip(
            avatar: Icon(v ? Icons.flip : Icons.flip_outlined, size: 16),
            label: Text(v ? 'Duplex' : 'Simplex'),
            visualDensity: VisualDensity.compact,
          ),
        if (caps.maxCopies case final v?)
          Chip(
            avatar: const Icon(Icons.content_copy, size: 16),
            label: Text('Max $v copies'),
            visualDensity: VisualDensity.compact,
          ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Business card widget printed by the widget source option
// ---------------------------------------------------------------------------

class BusinessCard extends StatelessWidget {
  const BusinessCard({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final primary = theme.colorScheme.primary;

    // The renderer injects a page-sized MediaQuery, so sizeOf(context) gives
    // the printable-area dimensions — no LayoutBuilder needed.
    final size = MediaQuery.sizeOf(context);
    final w = size.width;
    final h = size.height;
    final padding = w * 0.06;
    final innerH = h - padding * 2;
    final imgSize = innerH * 0.44;
    final divH = innerH * 0.08;
    final rowH = (innerH - imgSize - divH) / 3;
    final iconSz = rowH * 0.55;
    final textSz = rowH * 0.55;
    final nameSz = imgSize * 0.22;
    final jobSz = imgSize * 0.17;

    return SizedBox(
      width: w,
      height: h,
      child: Container(
        color: Colors.white,
        padding: EdgeInsets.all(padding),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: Image.asset(
                    'assets/image.jpg',
                    width: imgSize,
                    height: imgSize,
                    fit: BoxFit.cover,
                  ),
                ),
                SizedBox(width: padding * 0.6),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'John Doe',
                        style: TextStyle(
                          fontSize: nameSz,
                          fontWeight: FontWeight.bold,
                          color: theme.colorScheme.onSurface,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(
                        "I think I'm a developer",
                        style: TextStyle(
                          fontSize: jobSz,
                          color: Colors.grey[600],
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
              ],
            ),
            Divider(height: divH, color: primary.withValues(alpha: 0.3)),
            _ContactRow(
              Icons.email_outlined,
              'john.doe@example.com',
              iconSize: iconSz,
              fontSize: textSz,
            ),
            _ContactRow(
              Icons.phone_outlined,
              '+1 (555) 123-4567',
              iconSize: iconSz,
              fontSize: textSz,
            ),
            _ContactRow(
              Icons.language_outlined,
              'www.example.com',
              iconSize: iconSz,
              fontSize: textSz,
            ),
          ],
        ),
      ),
    );
  }
}

class _ContactRow extends StatelessWidget {
  const _ContactRow(this.icon, this.text, {this.iconSize = 14, this.fontSize});
  final IconData icon;
  final String text;
  final double iconSize;
  final double? fontSize;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.symmetric(vertical: iconSize * 0.12),
      child: Row(
        children: [
          Icon(
            icon,
            size: iconSize,
            color: Theme.of(context).colorScheme.primary,
          ),
          SizedBox(width: iconSize * 0.5),
          Expanded(
            child: Text(
              text,
              style: TextStyle(fontSize: fontSize),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}
