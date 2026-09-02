import 'messages.g.dart';

/// Sorts [ranges] and merges overlapping or adjacent ones.
///
/// Throws an [ArgumentError] when a range has `start < 1` or `end < start`.
List<PageRange>? normalizePageRanges(List<PageRange>? ranges) {
  if (ranges == null || ranges.isEmpty) return ranges;

  for (final r in ranges) {
    if (r.start < 1 || r.end < r.start) {
      throw ArgumentError.value(
        '${r.start}-${r.end}',
        'pageRanges',
        'Invalid page range',
      );
    }
  }

  final sorted = [...ranges]..sort((a, b) => a.start.compareTo(b.start));
  final merged = <PageRange>[
    PageRange(start: sorted.first.start, end: sorted.first.end),
  ];
  for (final r in sorted.skip(1)) {
    final last = merged.last;
    if (r.start <= last.end + 1) {
      if (r.end > last.end) last.end = r.end;
    } else {
      merged.add(PageRange(start: r.start, end: r.end));
    }
  }
  return merged;
}
