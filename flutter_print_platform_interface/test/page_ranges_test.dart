import 'package:flutter_print_platform_interface/flutter_print_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';

List<(int, int)>? pairs(List<PageRange>? ranges) =>
    ranges?.map((r) => (r.start, r.end)).toList();

PageRange r(int start, int end) => PageRange(start: start, end: end);

void main() {
  group('normalizePageRanges', () {
    test('keeps null and empty', () {
      expect(normalizePageRanges(null), isNull);
      expect(normalizePageRanges([]), isEmpty);
    });

    test('sorts ranges', () {
      expect(pairs(normalizePageRanges([r(9, 9), r(2, 6)])), [(2, 6), (9, 9)]);
    });

    test('merges overlapping and adjacent ranges', () {
      expect(pairs(normalizePageRanges([r(1, 5), r(3, 7)])), [(1, 7)]);
      expect(pairs(normalizePageRanges([r(1, 3), r(4, 5)])), [(1, 5)]);
      expect(pairs(normalizePageRanges([r(1, 9), r(2, 3)])), [(1, 9)]);
    });

    test('keeps the input untouched', () {
      final input = [r(3, 7), r(1, 5)];
      normalizePageRanges(input);
      expect(pairs(input), [(3, 7), (1, 5)]);
    });

    test('throws on invalid ranges', () {
      expect(() => normalizePageRanges([r(0, 2)]), throwsArgumentError);
      expect(() => normalizePageRanges([r(6, 2)]), throwsArgumentError);
    });
  });
}
