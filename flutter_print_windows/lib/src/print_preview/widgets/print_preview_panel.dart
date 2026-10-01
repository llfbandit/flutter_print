import 'dart:convert';
import 'dart:io' show File, Platform;
import 'dart:math' show min;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/services.dart' show FontLoader;
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_print_platform_interface/flutter_print_platform_interface.dart';

import '../../windows_print_channel.dart';
import '../l10n/print_localizations.dart';

const _grayscaleFilter = ColorFilter.matrix(<double>[
  0.2126, 0.7152, 0.0722, 0, 0, //
  0.2126, 0.7152, 0.0722, 0, 0, //
  0.2126, 0.7152, 0.0722, 0, 0, //
  0, 0, 0, 1, 0, //
]);

// ---------------------------------------------------------------------------
// Public widget
// ---------------------------------------------------------------------------

class PrintPreviewPanel extends StatefulWidget {
  const PrintPreviewPanel({
    super.key,
    required this.filePath,
    required this.kind,
    required this.pageCount,
    required this.options,
  });

  final String filePath;
  final FileKind kind;

  /// Null while loading, 0 when unknown.
  final int? pageCount;
  final PrintOptions options;

  @override
  State<PrintPreviewPanel> createState() => _PrintPreviewPanelState();
}

class _PrintPreviewPanelState extends State<PrintPreviewPanel> {
  PageMargins? _minimumMargins;

  @override
  void initState() {
    super.initState();
    _fetchMinimumMargins();
  }

  @override
  void didUpdateWidget(PrintPreviewPanel old) {
    super.didUpdateWidget(old);
    if (old.options.printerAddress != widget.options.printerAddress ||
        old.options.pageSize != widget.options.pageSize ||
        old.options.landscape != widget.options.landscape) {
      _fetchMinimumMargins();
    }
  }

  Future<void> _fetchMinimumMargins() async {
    final printer = widget.options.printerAddress;
    if (printer == null || printer.isEmpty) {
      if (mounted) setState(() => _minimumMargins = null);
      return;
    }
    final (w, h) = _paperMm;
    final margins = await WindowsPrintChannel.getMinimumMargins(
      printerName: printer,
      paperSizeName: widget.options.pageSize?.name,
      paperWidth: w,
      paperHeight: h,
    );
    if (mounted) setState(() => _minimumMargins = margins);
  }

  /// Oriented paper width and height in mm (A4 when unset).
  (double, double) get _paperMm {
    final w = widget.options.pageSize?.width ?? 210.0;
    final h = widget.options.pageSize?.height ?? 297.0;
    return (widget.options.landscape ?? false) ? (h, w) : (w, h);
  }

  @override
  Widget build(BuildContext context) {
    final (paperW, paperH) = _paperMm;
    Widget paper(Widget child, {bool fullSheet = false}) => _PaperShell(
      widthMm: paperW,
      heightMm: paperH,
      minimumMargins: _minimumMargins,
      fullSheet: fullSheet,
      child: child,
    );
    if (widget.kind == FileKind.text) {
      return paper(_PrintTextPreview(filePath: widget.filePath));
    }
    return _PagedPreview(
      filePath: widget.filePath,
      kind: widget.kind,
      pageCount: widget.pageCount,
      color: widget.options.color ?? true,
      pageRanges: widget.options.pageRanges,
      paperMm: (paperW, paperH),
      paper: paper,
    );
  }
}

// ---------------------------------------------------------------------------
// Paper container
// ---------------------------------------------------------------------------

class _PaperShell extends StatelessWidget {
  const _PaperShell({
    required this.widthMm,
    required this.heightMm,
    required this.minimumMargins,
    required this.fullSheet,
    required this.child,
  });

  final double widthMm;
  final double heightMm;
  final PageMargins? minimumMargins;

  /// Lays [child] out on the whole sheet, not only in the printable area.
  final bool fullSheet;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = FluentTheme.of(context);
    final m = minimumMargins;
    return Center(
      child: AspectRatio(
        aspectRatio: widthMm / heightMm,
        child: Container(
          decoration: BoxDecoration(
            color: theme.resources.cardBackgroundFillColorDefault,
            border: Border.all(color: theme.resources.cardStrokeColorDefault),
            borderRadius: BorderRadius.circular(4),
          ),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final pw = constraints.maxWidth;
              final ph = constraints.maxHeight;
              final printable = m == null
                  ? EdgeInsets.zero
                  : EdgeInsets.fromLTRB(
                      m.left / widthMm * pw,
                      m.top / heightMm * ph,
                      m.right / widthMm * pw,
                      m.bottom / heightMm * ph,
                    );
              if (!fullSheet) return Padding(padding: printable, child: child);
              // Hide what falls in the margins, as the printer drops it.
              return ClipRect(clipper: _InsetClipper(printable), child: child);
            },
          ),
        ),
      ),
    );
  }
}

class _InsetClipper extends CustomClipper<Rect> {
  const _InsetClipper(this.insets);

  final EdgeInsets insets;

  @override
  Rect getClip(Size size) => insets.deflateRect(Offset.zero & size);

  @override
  bool shouldReclip(_InsetClipper old) => old.insets != insets;
}

// ---------------------------------------------------------------------------
// PDF and image preview
// ---------------------------------------------------------------------------

const _previewDpi = 150.0;

/// Size in mm of a PNG rendered at [_previewDpi], read from its header.
(double, double)? _pngSizeMm(Uint8List png) {
  if (png.length < 24) return null;
  final data = ByteData.sublistView(png);
  const mmPerPixel = 25.4 / _previewDpi;
  return (data.getUint32(16) * mmPerPixel, data.getUint32(20) * mmPerPixel);
}

/// Shows the pages the plugin renders, one at a time.
class _PagedPreview extends StatefulWidget {
  const _PagedPreview({
    required this.filePath,
    required this.kind,
    required this.pageCount,
    required this.color,
    required this.pageRanges,
    required this.paperMm,
    required this.paper,
  });

  final String filePath;
  final FileKind kind;
  final int? pageCount;
  final bool color;
  final List<PageRange>? pageRanges;

  /// Oriented sheet width and height in mm.
  final (double, double) paperMm;
  final Widget Function(Widget page, {bool fullSheet}) paper;

  @override
  State<_PagedPreview> createState() => _PagedPreviewState();
}

class _PagedPreviewState extends State<_PagedPreview> {
  Uint8List? _previewImg;

  /// 0-based indices of the pages to print. Empty until the page count is
  /// known.
  List<int> _selected = const [];

  /// Index in [_selected] of the shown page.
  int _pos = 0;
  bool _loadingPreview = false;

  // Drop renders that finish after a newer request.
  int _request = 0;

  int get _pageCount => widget.pageCount ?? 0;

  @override
  void initState() {
    super.initState();
    _recomputeSelection();
    _startRender();
  }

  @override
  void didUpdateWidget(_PagedPreview old) {
    super.didUpdateWidget(old);
    if (old.filePath != widget.filePath) {
      _pos = 0;
      _recomputeSelection();
      _startRender();
    } else if (old.pageCount != widget.pageCount ||
        !listEquals(
          old.pageRanges ?? const [],
          widget.pageRanges ?? const [],
        )) {
      final shown = _selected.isEmpty ? null : _selected[_pos];
      _recomputeSelection();
      // Keep the current page when it is still selected.
      final idx = shown == null ? -1 : _selected.indexOf(shown);
      if (idx >= 0) {
        _pos = idx;
      } else {
        _startRender();
      }
    }
  }

  /// Rebuilds [_selected] from the page ranges and keeps [_pos] in it.
  void _recomputeSelection() {
    final ranges = widget.pageRanges;
    if (_pageCount <= 0) {
      _selected = const [];
    } else if (ranges == null || ranges.isEmpty) {
      _selected = List<int>.generate(_pageCount, (i) => i);
    } else {
      _selected = [
        for (var i = 0; i < _pageCount; i++)
          if (ranges.any((r) => i + 1 >= r.start && i + 1 <= r.end)) i,
      ];
    }
    if (_pos >= _selected.length) {
      _pos = _selected.isEmpty ? 0 : _selected.length - 1;
    }
  }

  // Starts rendering the page at [_pos]. The caller rebuilds.
  void _startRender() {
    final request = ++_request;
    _previewImg = null;
    _loadingPreview = _selected.isNotEmpty;
    if (_loadingPreview) _render(request, _selected[_pos]);
  }

  Future<void> _render(int request, int page) async {
    Uint8List? img;
    try {
      img = await WindowsPrintChannel.renderPageToPng(
        widget.filePath,
        widget.kind,
        page,
        _previewDpi,
      );
    } catch (_) {
      // Show the preview as unavailable.
    }
    if (!mounted || request != _request) return;
    setState(() {
      _previewImg = img;
      _loadingPreview = false;
    });
  }

  void _navigatePage(int delta) {
    final next = (_pos + delta).clamp(0, _selected.length - 1);
    if (next == _pos) return;
    setState(() {
      _pos = next;
      _startRender();
    });
  }

  Widget _buildContent(BuildContext context) {
    final l10n = PrintLocalizations.of(context);
    if (_loadingPreview || widget.pageCount == null) {
      return const Center(child: ProgressRing());
    }
    final png = _previewImg;
    if (png == null) return Center(child: Text(l10n.previewUnavailable));

    Widget img = Image.memory(png, fit: BoxFit.contain);
    if (!widget.color) {
      img = ColorFiltered(colorFilter: _grayscaleFilter, child: img);
    }
    if (widget.kind != FileKind.pdf) return img;

    // Like print: draw from the sheet corner at true size, and shrink pages
    // too large for the sheet.
    final size = _pngSizeMm(png);
    if (size == null) return img;
    final (pageW, pageH) = size;
    final (sheetW, sheetH) = widget.paperMm;
    final s = [1.0, sheetW / pageW, sheetH / pageH].reduce(min);
    return FractionallySizedBox(
      alignment: Alignment.topLeft,
      widthFactor: pageW * s / sheetW,
      heightFactor: pageH * s / sheetH,
      child: img,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Expanded(
          child: widget.paper(
            _buildContent(context),
            fullSheet: widget.kind == FileKind.pdf,
          ),
        ),
        if (_selected.length > 1)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                IconButton(
                  icon: const Icon(FluentIcons.chevron_left),
                  onPressed: (!_loadingPreview && _pos > 0)
                      ? () => _navigatePage(-1)
                      : null,
                ),
                const SizedBox(width: 8),
                // Show the page number, and its position in a custom range.
                Text(
                  _selected.length == _pageCount
                      ? '${_selected[_pos] + 1} / $_pageCount'
                      : '${_selected[_pos] + 1} (${_pos + 1} / ${_selected.length})',
                ),
                const SizedBox(width: 8),
                IconButton(
                  icon: const Icon(FluentIcons.chevron_right),
                  onPressed: (!_loadingPreview && _pos < _selected.length - 1)
                      ? () => _navigatePage(1)
                      : null,
                ),
              ],
            ),
          ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Text preview
// ---------------------------------------------------------------------------

class _PrintTextPreview extends StatefulWidget {
  const _PrintTextPreview({required this.filePath});

  final String filePath;

  @override
  State<_PrintTextPreview> createState() => _PrintTextPreviewState();
}

class _PrintTextPreviewState extends State<_PrintTextPreview> {
  /// Null while loading, empty when the text can't be shown.
  List<String>? _lines;
  bool _truncated = false;

  static const _maxLines = 20000;
  static Future<void>? _consolasFuture;

  @override
  void initState() {
    super.initState();
    _loadText();
  }

  static Future<void> _loadConsolas() async {
    final dir = Platform.environment['windir'] ?? r'C:\Windows';
    final file = File('$dir\\Fonts\\consola.ttf');
    if (!file.existsSync()) return;
    final loader = FontLoader('Consolas')
      ..addFont(file.readAsBytes().then((b) => b.buffer.asByteData()));
    await loader.load();
  }

  Future<void> _loadText() async {
    // Load the font and the text concurrently; show lines once both are in.
    final font = _consolasFuture ??= _loadConsolas();
    var lines = const <String>[];
    try {
      final text = await WindowsPrintChannel.decodeTextFile(widget.filePath);
      if (text != null) lines = const LineSplitter().convert(text);
      await font;
    } catch (_) {
      // Show the preview as unavailable.
    }
    if (!mounted) return;
    setState(() {
      _truncated = lines.length > _maxLines;
      _lines = _truncated ? lines.take(_maxLines).toList() : lines;
    });
  }

  @override
  Widget build(BuildContext context) {
    final lines = _lines;
    if (lines == null) return const Center(child: ProgressRing());
    if (lines.isEmpty) {
      return Center(
        child: Text(PrintLocalizations.of(context).previewUnavailable),
      );
    }
    const style = TextStyle(fontSize: 10, fontFamily: 'Consolas');
    return ListView.builder(
      itemCount: lines.length + (_truncated ? 1 : 0),
      itemBuilder: (context, i) => i < lines.length
          ? Text(lines[i], style: style)
          : Center(
              child: Text(
                '— preview truncated at $_maxLines lines —',
                style: style.copyWith(fontStyle: FontStyle.italic),
              ),
            ),
    );
  }
}
