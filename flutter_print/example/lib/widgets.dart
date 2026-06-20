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
        if (caps.colorCapability != ColorCapability.unknown)
          Chip(
            avatar: Icon(
              caps.colorCapability == ColorCapability.monochrome
                  ? Icons.invert_colors_off
                  : Icons.color_lens,
              size: 16,
            ),
            label: Text(switch (caps.colorCapability) {
              ColorCapability.monochrome => 'Grayscale',
              ColorCapability.enforced => 'Color (enforced)',
              _ => 'Color',
            }),
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

  // The renderer maps 1 logical pixel = 1 typographic point (72 pt/inch),
  // so dimensions in logical pixels = mm × 72/25.4.

  static const _radius = 9.0;
  static const _pad = 8.0;
  static const _imgSize = 55.0;
  static const _imgGap = 9.0;
  static const _divH = 5.0;
  static const _nameSz = 13.0;
  static const _jobSz = 12.0;
  static const _contactSz = 11.0;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final primary = theme.colorScheme.primary;

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(_radius),
        border: Border.all(color: Colors.grey.shade300),
      ),
      padding: const EdgeInsets.all(_pad),
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
                  width: _imgSize,
                  height: _imgSize,
                  fit: BoxFit.cover,
                ),
              ),
              const SizedBox(width: _imgGap),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'John Doe',
                      style: TextStyle(
                        fontSize: _nameSz,
                        fontWeight: FontWeight.bold,
                        color: theme.colorScheme.onSurface,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(
                      "I think I'm a developer",
                      style: TextStyle(
                        fontSize: _jobSz,
                        color: Colors.grey[600],
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: _divH),
          Divider(color: primary.withValues(alpha: 0.3)),
          const _ContactRow(
            Icons.email_outlined,
            'john.doe@example.com',
            size: _contactSz,
          ),
          const _ContactRow(
            Icons.phone_outlined,
            '+1 (555) 123-4567',
            size: _contactSz,
          ),
          const _ContactRow(
            Icons.language_outlined,
            'www.example.com',
            size: _contactSz,
          ),
        ],
      ),
    );
  }
}

class _ContactRow extends StatelessWidget {
  const _ContactRow(this.icon, this.text, {required this.size});
  final IconData icon;
  final String text;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.symmetric(vertical: 1.5),
      child: Row(
        children: [
          Icon(icon, size: size, color: Theme.of(context).colorScheme.primary),
          SizedBox(width: 4.0),
          Expanded(
            child: Text(
              text,
              style: TextStyle(fontSize: size),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}
