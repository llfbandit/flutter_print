import 'package:flutter_print_platform_interface/flutter_print_platform_interface.dart';
import 'package:flutter_print/src/windows/print_preview/print_dialog_utils.dart';
import 'package:flutter_test/flutter_test.dart';

String? parse(String input, int pageCount) {
  final ranges = parsePageRanges(input, pageCount: pageCount);
  return ranges == null ? null : formatPageRanges(ranges);
}

void main() {
  group('parsePageRanges', () {
    test('parses, sorts and merges', () {
      expect(parse('9, 2-6,', 9), '2-6, 9');
      expect(parse(' 1 - 3 , 2-4 ', 9), '1-4');
      expect(parse('1', 1), '1');
    });

    test('rejects blank and bad text', () {
      expect(parse('  ', 5), isNull);
      expect(parse('5-', 50), isNull);
      expect(parse('3,a', 50), isNull);
      expect(parse('0', 5), isNull);
      expect(parse('6-2', 9), isNull);
    });

    test('rejects pages after the page count', () {
      expect(parse('10', 5), isNull);
      expect(parse('3-8', 5), isNull);
    });

    test('skips the page count check when unknown', () {
      expect(parse('3-8', 0), '3-8');
    });
  });

  test('formatPageRanges', () {
    expect(
      formatPageRanges([
        PageRange(start: 2, end: 6),
        PageRange(start: 9, end: 9),
      ]),
      '2-6, 9',
    );
  });
}
