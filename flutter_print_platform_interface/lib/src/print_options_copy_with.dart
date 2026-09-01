import 'messages.g.dart';

extension PrintOptionsCopyWith on PrintOptions {
  PrintOptions copyWith({
    String? printerAddress,
    PageSize? pageSize,
    PageMargins? margins,
    int? copies,
    bool? landscape,
    bool? color,
    DuplexMode? duplexMode,
    List<PageRange>? pageRanges,
  }) => PrintOptions(
    printerAddress: printerAddress ?? this.printerAddress,
    pageSize: pageSize ?? this.pageSize,
    margins: margins ?? this.margins,
    copies: copies ?? this.copies,
    landscape: landscape ?? this.landscape,
    color: color ?? this.color,
    duplexMode: duplexMode ?? this.duplexMode,
    pageRanges: pageRanges ?? this.pageRanges,
  );
}
