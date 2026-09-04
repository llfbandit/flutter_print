import 'package:flutter_print_platform_interface/flutter_print_platform_interface.dart';

/// Parses a page-range text such as `"2-6, 9, 15"`.
///
/// Returns `null` when the text is blank, has a bad token, or selects a page
/// after [pageCount]. A [pageCount] of 0 means unknown: skip that check.
List<PageRange>? parsePageRanges(String input, {required int pageCount}) {
  final ranges = <PageRange>[];
  for (final token in input.split(',')) {
    final part = token.trim();
    if (part.isEmpty) continue;

    final dash = part.indexOf('-');
    final int? start;
    final int? end;
    if (dash < 0) {
      start = end = int.tryParse(part);
    } else {
      start = int.tryParse(part.substring(0, dash).trim());
      end = int.tryParse(part.substring(dash + 1).trim());
    }
    if (start == null || end == null) return null;
    if (start < 1 || end < start) return null;
    if (pageCount > 0 && end > pageCount) return null;
    ranges.add(PageRange(start: start, end: end));
  }
  return ranges.isEmpty ? null : normalizePageRanges(ranges);
}

/// Formats [ranges] as page-range text, e.g. `"2-6, 9"`.
String formatPageRanges(List<PageRange> ranges) => ranges
    .map((r) => r.start == r.end ? '${r.start}' : '${r.start}-${r.end}')
    .join(', ');

bool mimeIsPdf(String mime) => mime == 'application/pdf';
bool mimeIsImage(String mime) => mime.startsWith('image/');
bool mimeIsText(String mime) => mime.startsWith('text/');

/// Paper sizes offered by the dialog, in menu order: name → (width, height)
/// in portrait millimetres.
const _pageSizesMm = {
  'A3': (297.0, 420.0),
  'A4': (210.0, 297.0),
  'A5': (148.0, 210.0),
  'A6': (105.0, 148.0),
  'Letter': (215.9, 279.4),
  'Legal': (215.9, 355.6),
  'Tabloid': (279.4, 431.8),
  'Executive': (184.15, 266.7),
  'JIS B4': (257.0, 364.0),
  'JIS B5': (182.0, 257.0),
  'DL': (110.0, 220.0),
  'C5': (162.0, 229.0),
};

final allPageSizes = _pageSizesMm.keys.toList(growable: false);

/// The named size, or A4 when [name] is unknown.
PageSize pageSizeFromName(String name) {
  final known = _pageSizesMm.containsKey(name);
  final (width, height) = _pageSizesMm[name] ?? _pageSizesMm['A4']!;
  return PageSize(name: known ? name : 'A4', width: width, height: height);
}
