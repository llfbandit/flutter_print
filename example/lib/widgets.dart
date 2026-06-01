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
