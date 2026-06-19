import 'package:flutter_print_platform_interface/flutter_print_platform_interface.dart';

extension PrintOptionsCopyWith on PrintOptions {
  PrintOptions copyWith({
    String? printerAddress,
    PageSize? pageSize,
    PageMargins? margins,
    int? copies,
    bool? landscape,
    bool? color,
    DuplexMode? duplexMode,
  }) => PrintOptions(
    printerAddress: printerAddress ?? this.printerAddress,
    pageSize: pageSize ?? this.pageSize,
    margins: margins ?? this.margins,
    copies: copies ?? this.copies,
    landscape: landscape ?? this.landscape,
    color: color ?? this.color,
    duplexMode: duplexMode ?? this.duplexMode,
  );
}

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
