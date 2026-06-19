import 'dart:convert';
import 'dart:io' show File, Platform;
import 'dart:typed_data';

import 'package:flutter/services.dart' show FontLoader;
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_print_platform_interface/flutter_print_platform_interface.dart';

import '../../windows_print_channel.dart';
import '../l10n/print_localizations.dart';
import '../print_dialog_utils.dart';

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
    required this.options,
  });

  final String filePath;
  final PrintOptions options;

  @override
  State<PrintPreviewPanel> createState() => _PrintPreviewPanelState();
}

class _PrintPreviewPanelState extends State<PrintPreviewPanel> {
  String? _mimeType;
  PageMargins? _minimumMargins;

  @override
  void initState() {
    super.initState();
    _loadMimeType();
    _fetchMinimumMargins();
  }

  @override
  void didUpdateWidget(PrintPreviewPanel old) {
    super.didUpdateWidget(old);
    if (old.filePath != widget.filePath) {
      setState(() => _mimeType = null);
      _loadMimeType();
    }
    if (old.options.printerAddress != widget.options.printerAddress ||
        old.options.pageSize != widget.options.pageSize ||
        old.options.landscape != widget.options.landscape) {
      _fetchMinimumMargins();
    }
  }

  Future<void> _loadMimeType() async {
    final mime = await WindowsPrintChannel.getMimeType(widget.filePath);
    if (mounted) setState(() => _mimeType = mime);
  }

  Future<void> _fetchMinimumMargins() async {
    final printer = widget.options.printerAddress;
    if (printer == null || printer.isEmpty) {
      if (mounted) setState(() => _minimumMargins = null);
      return;
    }
    final pageSize = widget.options.pageSize;
    final w = pageSize?.width ?? 210.0;
    final h = pageSize?.height ?? 297.0;
    final landscape = widget.options.landscape;
    final margins = await WindowsPrintChannel.getMinimumMargins(
      printerName: printer,
      paperSizeName: pageSize?.name,
      paperWidth: landscape ? h : w,
      paperHeight: landscape ? w : h,
    );
    if (mounted) setState(() => _minimumMargins = margins);
  }

  @override
  Widget build(BuildContext context) {
    final mime = _mimeType;
    final double w = widget.options.pageSize?.width ?? 210.0;
    final double h = widget.options.pageSize?.height ?? 297.0;
    final bool landscape = widget.options.landscape;
    final double paperW = landscape ? h : w;
    final double paperH = landscape ? w : h;
    final double paperAspect = paperW / paperH;

    if (mime == null) {
      return Column(
        children: [
          _PaperShell(
            paperAspect: paperAspect,
            paperWidthMm: paperW,
            paperHeightMm: paperH,
            minimumMargins: _minimumMargins,
            child: const Center(child: ProgressRing()),
          ),
        ],
      );
    }

    if (mimeIsPdf(mime)) {
      return _PrintPdfPreview(
        filePath: widget.filePath,
        paperAspect: paperAspect,
        paperWidthMm: paperW,
        paperHeightMm: paperH,
        minimumMargins: _minimumMargins,
        color: widget.options.color,
      );
    }

    if (mimeIsImage(mime)) {
      return _PrintImagePreview(
        filePath: widget.filePath,
        paperAspect: paperAspect,
        paperWidthMm: paperW,
        paperHeightMm: paperH,
        minimumMargins: _minimumMargins,
        color: widget.options.color,
      );
    }

    if (mimeIsText(mime)) {
      return _PrintTextPreview(
        filePath: widget.filePath,
        paperAspect: paperAspect,
        paperWidthMm: paperW,
        paperHeightMm: paperH,
        minimumMargins: _minimumMargins,
      );
    }

    return _PrintUnknownPreview(paperAspect: paperAspect);
  }
}

// ---------------------------------------------------------------------------
// Paper container
// ---------------------------------------------------------------------------

class _PaperShell extends StatelessWidget {
  const _PaperShell({
    required this.paperAspect,
    required this.child,
    this.paperWidthMm = 210.0,
    this.paperHeightMm = 297.0,
    this.minimumMargins,
  });

  final double paperAspect;
  final Widget child;
  final double paperWidthMm;
  final double paperHeightMm;
  final PageMargins? minimumMargins;

  @override
  Widget build(BuildContext context) {
    final theme = FluentTheme.of(context);
    final margins = minimumMargins;
    return Expanded(
      child: Center(
        child: AspectRatio(
          aspectRatio: paperAspect,
          child: Container(
            decoration: BoxDecoration(
              color: theme.resources.cardBackgroundFillColorDefault,
              border: Border.all(color: theme.resources.cardStrokeColorDefault),
              borderRadius: BorderRadius.circular(4),
            ),
            child: LayoutBuilder(
              builder: (context, constraints) {
                return Stack(
                  fit: StackFit.expand,
                  children: [
                    Padding(
                      padding: _getContentPadding(constraints, margins),
                      child: child,
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  EdgeInsets _getContentPadding(
    BoxConstraints constraints,
    PageMargins? margins,
  ) {
    if (margins == null) {
      return EdgeInsets.zero;
    }

    final pw = constraints.maxWidth;
    final ph = constraints.maxHeight;

    return EdgeInsets.fromLTRB(
      (margins.left / paperWidthMm) * pw,
      (margins.top / paperHeightMm) * ph,
      (margins.right / paperWidthMm) * pw,
      (margins.bottom / paperHeightMm) * ph,
    );
  }
}

// ---------------------------------------------------------------------------
// PDF preview
// ---------------------------------------------------------------------------

class _PrintPdfPreview extends StatefulWidget {
  const _PrintPdfPreview({
    required this.filePath,
    required this.paperAspect,
    required this.paperWidthMm,
    required this.paperHeightMm,
    required this.minimumMargins,
    required this.color,
  });

  final String filePath;
  final double paperAspect;
  final double paperWidthMm;
  final double paperHeightMm;
  final PageMargins? minimumMargins;
  final bool color;

  @override
  State<_PrintPdfPreview> createState() => _PrintPdfPreviewState();
}

class _PrintPdfPreviewState extends State<_PrintPdfPreview> {
  Uint8List? _previewImg;
  int _currentPage = 0;
  int _pageCount = 1;
  bool _loadingPreview = false;

  @override
  void initState() {
    super.initState();
    _loadPdfPreview(0);
  }

  @override
  void didUpdateWidget(_PrintPdfPreview old) {
    super.didUpdateWidget(old);
    if (old.filePath != widget.filePath) {
      _currentPage = 0;
      _pageCount = 1;
      _loadPdfPreview(0);
    }
  }

  Future<void> _loadPdfPreview(int pageIndex) async {
    setState(() {
      _loadingPreview = true;
      _previewImg = null;
    });
    try {
      if (_pageCount <= 1) {
        _pageCount = await WindowsPrintChannel.getPdfPageCount(widget.filePath);
      }
      final img = await WindowsPrintChannel.renderPdfPageToPng(
        widget.filePath,
        pageIndex,
        150.0,
      );
      if (!mounted) return;
      setState(() {
        _previewImg = img;
        _loadingPreview = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loadingPreview = false);
    }
  }

  Future<void> _navigatePage(int delta) async {
    final next = (_currentPage + delta).clamp(0, _pageCount - 1);
    if (next == _currentPage) return;
    _currentPage = next;
    await _loadPdfPreview(_currentPage);
  }

  Widget _buildContent(BuildContext context) {
    final l10n = PrintLocalizations.of(context);
    if (_loadingPreview) return const Center(child: ProgressRing());
    if (_previewImg != null) {
      Widget img = Image.memory(
        _previewImg!,
        fit: BoxFit.contain,
        alignment: Alignment.topLeft,
      );
      if (!widget.color) {
        img = ColorFiltered(colorFilter: _grayscaleFilter, child: img);
      }
      return img;
    }
    return Center(child: Text(l10n.previewUnavailable));
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _PaperShell(
          paperAspect: widget.paperAspect,
          paperWidthMm: widget.paperWidthMm,
          paperHeightMm: widget.paperHeightMm,
          minimumMargins: widget.minimumMargins,
          child: _buildContent(context),
        ),
        if (_pageCount > 1)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                IconButton(
                  icon: const Icon(FluentIcons.chevron_left),
                  onPressed: (!_loadingPreview && _currentPage > 0)
                      ? () => _navigatePage(-1)
                      : null,
                ),
                const SizedBox(width: 8),
                Text('${_currentPage + 1} / $_pageCount'),
                const SizedBox(width: 8),
                IconButton(
                  icon: const Icon(FluentIcons.chevron_right),
                  onPressed: (!_loadingPreview && _currentPage < _pageCount - 1)
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
// Image preview
// ---------------------------------------------------------------------------

class _PrintImagePreview extends StatelessWidget {
  const _PrintImagePreview({
    required this.filePath,
    required this.paperAspect,
    required this.paperWidthMm,
    required this.paperHeightMm,
    required this.minimumMargins,
    required this.color,
  });

  final String filePath;
  final double paperAspect;
  final double paperWidthMm;
  final double paperHeightMm;
  final PageMargins? minimumMargins;
  final bool color;

  @override
  Widget build(BuildContext context) {
    final l10n = PrintLocalizations.of(context);
    Widget img = Image.file(
      File(filePath),
      fit: BoxFit.contain,
      errorBuilder: (_, _, _) => Center(child: Text(l10n.previewUnavailable)),
    );
    if (!color) img = ColorFiltered(colorFilter: _grayscaleFilter, child: img);
    return Column(
      children: [
        _PaperShell(
          paperAspect: paperAspect,
          paperWidthMm: paperWidthMm,
          paperHeightMm: paperHeightMm,
          minimumMargins: minimumMargins,
          child: img,
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Text preview
// ---------------------------------------------------------------------------

class _PrintTextPreview extends StatefulWidget {
  const _PrintTextPreview({
    required this.filePath,
    required this.paperAspect,
    required this.paperWidthMm,
    required this.paperHeightMm,
    required this.minimumMargins,
  });

  final String filePath;
  final double paperAspect;
  final double paperWidthMm;
  final double paperHeightMm;
  final PageMargins? minimumMargins;

  @override
  State<_PrintTextPreview> createState() => _PrintTextPreviewState();
}

class _PrintTextPreviewState extends State<_PrintTextPreview> {
  final _lines = <String>[];
  bool _loading = true;
  bool _truncated = false;

  static const _maxLines = 20000;
  static Future<void>? _consolasFuture;

  @override
  void initState() {
    super.initState();
    (_consolasFuture ??= _loadConsolas()).then((_) => _loadText());
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
    if (!mounted) return;
    try {
      final text = await WindowsPrintChannel.decodeTextFile(widget.filePath);
      if (!mounted) return;
      if (text == null) {
        setState(() => _loading = false);
        return;
      }
      final lines = const LineSplitter().convert(text);
      setState(() {
        if (lines.length > _maxLines) {
          _lines.addAll(lines.take(_maxLines));
          _truncated = true;
        } else {
          _lines.addAll(lines);
        }
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = PrintLocalizations.of(context);
    final Widget child;

    if (_lines.isEmpty) {
      child = _loading
          ? const Center(child: ProgressRing())
          : Center(child: Text(l10n.previewUnavailable));
    } else {
      const style = TextStyle(fontSize: 10, fontFamily: 'Consolas');
      child = ListView.builder(
        itemCount: _lines.length + (_loading || _truncated ? 1 : 0),
        itemBuilder: (context, i) {
          if (i == _lines.length) {
            return _loading
                ? const Center(child: ProgressRing())
                : Center(
                    child: Text(
                      '— preview truncated at $_maxLines lines —',
                      style: style.copyWith(fontStyle: FontStyle.italic),
                    ),
                  );
          }
          return Text(_lines[i], style: style);
        },
      );
    }

    return Column(
      children: [
        _PaperShell(
          paperAspect: widget.paperAspect,
          paperWidthMm: widget.paperWidthMm,
          paperHeightMm: widget.paperHeightMm,
          minimumMargins: widget.minimumMargins,
          child: child,
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Unknown content (no preview available)
// ---------------------------------------------------------------------------

class _PrintUnknownPreview extends StatelessWidget {
  const _PrintUnknownPreview({required this.paperAspect});

  final double paperAspect;

  @override
  Widget build(BuildContext context) {
    final theme = FluentTheme.of(context);
    final l10n = PrintLocalizations.of(context);

    return Column(
      children: [
        _PaperShell(
          paperAspect: paperAspect,
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  FluentIcons.document,
                  size: 64,
                  color: theme.resources.textFillColorSecondary,
                ),
                const SizedBox(height: 8),
                Text(
                  l10n.noPreview,
                  style: theme.typography.body?.apply(
                    color: theme.resources.textFillColorSecondary,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
