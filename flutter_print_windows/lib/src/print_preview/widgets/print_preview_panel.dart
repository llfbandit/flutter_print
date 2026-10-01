import 'dart:async';
import 'dart:math' show max, min;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show listEquals;
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_print_platform_interface/flutter_print_platform_interface.dart';

import '../../windows_print_channel.dart';
import '../l10n/print_localizations.dart';

/// Width of the card border around the sheet.
const _border = 1.0;

const _grayscaleFilter = ColorFilter.matrix(<double>[
  0.2126, 0.7152, 0.0722, 0, 0, //
  0.2126, 0.7152, 0.0722, 0, 0, //
  0.2126, 0.7152, 0.0722, 0, 0, //
  0, 0, 0, 1, 0, //
]);

/// Shows the sheets the plugin renders for the printer, one at a time: the
/// preview matches print.
class PrintPreviewPanel extends StatefulWidget {
  const PrintPreviewPanel({
    super.key,
    required this.preview,
    required this.pageCount,
    required this.options,
  });

  /// Null while opening or when the file can't be previewed.
  final PreviewSession? preview;

  /// Null while loading, 0 when unknown.
  final int? pageCount;
  final PrintOptions options;

  @override
  State<PrintPreviewPanel> createState() => _PrintPreviewPanelState();
}

class _PrintPreviewPanelState extends State<PrintPreviewPanel> {
  /// 0-based indices of the pages to print. Empty until the page count is
  /// known.
  List<int> _selected = const [];

  /// Index in [_selected] of the shown page.
  int _pos = 0;

  /// Physical pixels the sheets are rendered to fit in.
  (int, int)? _box;
  Timer? _resize;

  /// Rendered sheets by page, null when a page can't render, for the current
  /// preview and box.
  final _sheets = <int, Uint8List?>{};
  final _pending = <int>{};

  // Bumps when the preview or the box changes: renders in flight are stale.
  int _generation = 0;

  /// The shown page before the last change, kept up while it renders again.
  (int, Uint8List)? _stale;

  int get _pageCount => widget.pageCount ?? 0;
  int? get _shown => _selected.isEmpty ? null : _selected[_pos];

  @override
  void initState() {
    super.initState();
    _recomputeSelection();
  }

  @override
  void dispose() {
    _resize?.cancel();
    super.dispose();
  }

  @override
  void didUpdateWidget(PrintPreviewPanel old) {
    super.didUpdateWidget(old);
    final shown = _shown;
    if (old.preview?.id != widget.preview?.id) _invalidate();
    if (old.pageCount != widget.pageCount ||
        !listEquals(
          old.options.pageRanges ?? const [],
          widget.options.pageRanges ?? const [],
        )) {
      _recomputeSelection();
      // Keep the current page when it is still selected.
      final idx = shown == null ? -1 : _selected.indexOf(shown);
      if (idx >= 0) _pos = idx;
    }
    _showPage();
  }

  /// Rebuilds [_selected] from the page ranges and keeps [_pos] in it.
  void _recomputeSelection() {
    final ranges = widget.options.pageRanges;
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

  // Drops the rendered sheets, but keeps the shown one up until it renders
  // again.
  void _invalidate() {
    final shown = _shown;
    final sheet = shown == null ? null : _sheets[shown];
    if (shown != null && sheet != null) _stale = (shown, sheet);
    _generation++;
    _sheets.clear();
    _pending.clear();
  }

  // Renders the shown page, then its neighbors, so page turns are instant.
  void _showPage() {
    final shown = _shown;
    if (shown == null) return;
    if (_sheets.containsKey(shown)) {
      _prefetch();
    } else {
      _render(shown);
    }
  }

  void _prefetch() {
    for (final pos in [_pos + 1, _pos - 1]) {
      if (pos >= 0 && pos < _selected.length) _render(_selected[pos]);
    }
    // Forget the pages far from the shown one.
    final keep = {
      for (var p = _pos - 2; p <= _pos + 2; p++)
        if (p >= 0 && p < _selected.length) _selected[p],
    };
    _sheets.removeWhere((page, _) => !keep.contains(page));
  }

  void _render(int page) {
    final preview = widget.preview;
    final box = _box;
    if (preview == null ||
        box == null ||
        _sheets.containsKey(page) ||
        !_pending.add(page)) {
      return;
    }
    final generation = _generation;
    WindowsPrintChannel.renderPreviewPage(
      preview.id,
      page,
      box.$1,
      box.$2,
    ).then<Uint8List?>((png) => png, onError: (Object _) => null).then((png) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _pending.remove(page);
        _sheets[page] = png;
        if (_stale?.$1 == page) _stale = null;
      });
      if (page == _shown) _prefetch();
    });
  }

  // Renders again for a new room, once it settles. Meanwhile, the old sheet
  // shows at its size, or shrinks to fit.
  void _onRoom(Size room, double dpr) {
    final box = (
      min(4096, (room.width * dpr).floor()),
      min(4096, (room.height * dpr).floor()),
    );
    if (box.$1 <= 0 || box.$2 <= 0 || box == _box) return;
    _resize?.cancel();
    if (_box == null) {
      _box = box;
      _showPage();
      return;
    }
    _resize = Timer(const Duration(milliseconds: 200), () {
      if (!mounted) return;
      setState(() {
        _invalidate();
        _box = box;
      });
      _showPage();
    });
  }

  void _navigatePage(int delta) {
    final next = (_pos + delta).clamp(0, _selected.length - 1);
    if (next == _pos) return;
    setState(() => _pos = next);
    _showPage();
  }

  /// The sheet to show, null while it renders. Empty when it can't render.
  Uint8List? get _sheet {
    final shown = _shown;
    if (shown == null) return null;
    if (_sheets.containsKey(shown)) return _sheets[shown] ?? Uint8List(0);
    final stale = _stale;
    return stale != null && stale.$1 == shown ? stale.$2 : null;
  }

  Widget _buildSheet(BuildContext context, Uint8List? sheet, bool exact) {
    final l10n = PrintLocalizations.of(context);
    if (sheet == null) {
      if (widget.pageCount == null || _shown != null) {
        return const Center(child: ProgressRing());
      }
      return Center(child: Text(l10n.previewUnavailable));
    }
    if (sheet.isEmpty) return Center(child: Text(l10n.previewUnavailable));
    // At its pixel size, nearest sampling copies the pixels. Smooth sampling
    // blurs them when the sheet sits between pixels.
    Widget img = Image.memory(
      sheet,
      fit: BoxFit.fill,
      gaplessPlayback: true,
      filterQuality: exact ? FilterQuality.none : FilterQuality.medium,
    );
    if (!(widget.options.color ?? true)) {
      img = ColorFiltered(colorFilter: _grayscaleFilter, child: img);
    }
    return img;
  }

  /// Logical size of [sheet] in [room], and whether it shows at its pixel
  /// size. Before a sheet is in, the chosen paper fitted in [room].
  (Size, bool) _sheetSize(Uint8List? sheet, Size room, double dpr) {
    final px = sheet == null ? null : _pngSize(sheet);
    if (px != null) {
      final size = Size(px.$1 / dpr, px.$2 / dpr);
      // Rendered for this room, or a larger one while it renders again.
      if (size.width <= room.width && size.height <= room.height) {
        return (size, true);
      }
      return (_fit(size, room), false);
    }
    final w = widget.options.pageSize?.width ?? 210.0;
    final h = widget.options.pageSize?.height ?? 297.0;
    final landscape = widget.options.landscape ?? false;
    return (_fit(landscape ? Size(h, w) : Size(w, h), room), false);
  }

  @override
  Widget build(BuildContext context) {
    final theme = FluentTheme.of(context);
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final sheet = _sheet;
    return Column(
      children: [
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              // The sheet fits inside the card border.
              final room = Size(
                max(0, constraints.maxWidth - 2 * _border),
                max(0, constraints.maxHeight - 2 * _border),
              );
              _onRoom(room, dpr);
              final (size, exact) = _sheetSize(sheet, room, dpr);
              return Center(
                child: Container(
                  decoration: BoxDecoration(
                    color: theme.resources.cardBackgroundFillColorDefault,
                    border: Border.all(
                      color: theme.resources.cardStrokeColorDefault,
                      width: _border,
                    ),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: SizedBox.fromSize(
                    size: size,
                    child: _buildSheet(context, sheet, exact),
                  ),
                ),
              );
            },
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
                  onPressed: _pos > 0 ? () => _navigatePage(-1) : null,
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
                  onPressed: _pos < _selected.length - 1
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

/// [size] scaled to fit in [room].
Size _fit(Size size, Size room) {
  final s = min(room.width / size.width, room.height / size.height);
  return size * s;
}

/// Pixel width and height of a PNG, read from its header.
(int, int)? _pngSize(Uint8List png) {
  if (png.length < 24) return null;
  final data = ByteData.sublistView(png);
  final (w, h) = (data.getUint32(16), data.getUint32(20));
  return w > 0 && h > 0 ? (w, h) : null;
}
