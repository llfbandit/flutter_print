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

const allPageSizes = [
  'A3',
  'A4',
  'A5',
  'A6',
  'Letter',
  'Legal',
  'Tabloid',
  'Executive',
  'JIS B4',
  'JIS B5',
  'DL',
  'C5',
];

PageSize pageSizeFromName(String name) {
  switch (name) {
    case 'A3':
      return PageSize(name: 'A3', width: 297.0, height: 420.0);
    case 'A5':
      return PageSize(name: 'A5', width: 148.0, height: 210.0);
    case 'A6':
      return PageSize(name: 'A6', width: 105.0, height: 148.0);
    case 'Letter':
      return PageSize(name: 'Letter', width: 215.9, height: 279.4);
    case 'Legal':
      return PageSize(name: 'Legal', width: 215.9, height: 355.6);
    case 'Tabloid':
      return PageSize(name: 'Tabloid', width: 279.4, height: 431.8);
    case 'Executive':
      return PageSize(name: 'Executive', width: 184.15, height: 266.7);
    case 'JIS B4':
      return PageSize(name: 'JIS B4', width: 257.0, height: 364.0);
    case 'JIS B5':
      return PageSize(name: 'JIS B5', width: 182.0, height: 257.0);
    case 'DL':
      return PageSize(name: 'DL', width: 110.0, height: 220.0);
    case 'C5':
      return PageSize(name: 'C5', width: 162.0, height: 229.0);
    default:
      return PageSize(name: 'A4', width: 210.0, height: 297.0);
  }
}
