import 'dart:async';
import 'dart:math' show max, min, pow;

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_print_platform_interface/flutter_print_platform_interface.dart';

import '../../windows_print_channel.dart';
import '../../windows_ui/windows_ui.dart';
import '../l10n/print_localizations.dart';

/// Width of the card border around the sheet.
const _border = 1.0;

/// Height of the page number under each sheet.
const _labelHeight = 28.0;

/// Room on each side of the sheets, for the scrollbar.
const _side = 8.0;

/// Pixels an arrow key scrolls: about three lines.
const _lineStep = 48.0;

/// Height the sheets may take: they fit the panel width, as the list scrolls.
const _unbounded = 100000.0;

/// Zoom, as a share of the panel width, and the factor of a wheel notch or a
/// key press.
const _minZoom = 0.25;
const _maxZoom = 4.0;
const _zoomStep = 1.1;

const _grayscaleFilter = ColorFilter.matrix(<double>[
  0.2126, 0.7152, 0.0722, 0, 0, //
  0.2126, 0.7152, 0.0722, 0, 0, //
  0.2126, 0.7152, 0.0722, 0, 0, //
  0, 0, 0, 1, 0, //
]);

/// Shows the sheets the plugin renders for the printer, one under the other,
/// at the panel width: the preview matches print.
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

  /// Physical pixels the sheets are rendered to fit in.
  (int, int)? _box;
  Timer? _resize;

  /// Rendered sheets by page, null when a page can't render, for the current
  /// preview and box.
  final _sheets = <int, Uint8List?>{};
  final _pending = <int>{};

  // Bumps when the preview or the box changes: renders in flight are stale.
  int _generation = 0;

  /// The sheets before the last change, kept up while they render again.
  final _stale = <int, Uint8List>{};

  final _scroll = ScrollController();

  /// Scrolls sideways, when zoomed wider than the panel.
  final _hScroll = ScrollController();

  /// Takes the keys that scroll, once clicked or tabbed to.
  final _focus = FocusNode();

  /// Height of a sheet with its page number, in the list.
  double _extent = 1;

  /// Sheet width, as a share of the panel width.
  double _zoom = 1;

  // The panel, to place the zoom under the pointer.
  final _viewportKey = GlobalKey();

  /// Sheet width at 100%: the panel width, inside the card border.
  double _fitWidth = 0;

  /// The panel size and pixel ratio, from the last layout.
  Size _viewport = Size.zero;
  double _dpr = 1;

  /// Sharp renders of the shown part of each shown sheet, laid over the
  /// sheets when zoomed in past their render size.
  final _details = <int, _Detail>{};
  Timer? _detailTimer;
  int _detailGeneration = 0;
  final _detailRequests =
      <int, (int, ({int left, int top, int right, int bottom}))>{};

  Size _roomAt(double zoom) => Size(_fitWidth * zoom, _unbounded);

  /// Height of a sheet with its page number in [room]. From the paper shape
  /// only, so it doesn't move by a pixel as sheets render.
  double _extentIn(Size room) {
    // All sheets have the printer's paper size: any one gives the shape.
    final any =
        _sheets.values.nonNulls.firstOrNull ?? _stale.values.firstOrNull;
    final px = any == null ? null : _pngSize(any);
    final shape = px != null
        ? Size(px.$1.toDouble(), px.$2.toDouble())
        : _paperShape;
    return _fit(shape, room).height + 2 * _border + _labelHeight;
  }

  /// Width and height of the chosen paper, as laid out.
  Size get _paperShape {
    final w = widget.options.pageSize?.width ?? 210.0;
    final h = widget.options.pageSize?.height ?? 297.0;
    return (widget.options.landscape ?? false) ? Size(h, w) : Size(w, h);
  }

  int get _pageCount => widget.pageCount ?? 0;

  @override
  void initState() {
    super.initState();
    _recomputeSelection();
    _scroll.addListener(_forgetFarSheets);
    _scroll.addListener(_scheduleDetails);
    _hScroll.addListener(_scheduleDetails);
  }

  @override
  void dispose() {
    _detailTimer?.cancel();
    _resize?.cancel();
    _scroll.dispose();
    _hScroll.dispose();
    _focus.dispose();
    super.dispose();
  }

  // Zooms to [zoom], keeping the point at [focal] in the panel in place.
  void _zoomTo(double zoom, Offset focal) {
    zoom = zoom.clamp(_minZoom, _maxZoom);
    if (zoom == _zoom || !_scroll.hasClients) return;
    final ratio = zoom / _zoom;
    // The sheet under the focal point, and how far down it the point is.
    final y = _scroll.offset + focal.dy;
    final sheet = (y / _extent).floor();
    final into = y - sheet * _extent;
    final x = _hScroll.hasClients ? _hScroll.offset + focal.dx : focal.dx;
    // Move before the zoomed layout, not after: a frame at the old offset
    // would flicker. The layout clamps the offsets to the new content.
    // Clamp to the new content, or the list would spring back into it.
    final room = _roomAt(zoom);
    final extent = _extentIn(room);
    final v = _scroll.position;
    final top = sheet * extent + into * ratio - focal.dy;
    final maxTop = _selected.length * extent - v.viewportDimension;
    v.correctPixels(top.clamp(0.0, max(0.0, maxTop)));
    if (_hScroll.hasClients) {
      final h = _hScroll.position;
      final maxLeft = room.width + 2 * (_border + _side) - h.viewportDimension;
      h.correctPixels((x * ratio - focal.dx).clamp(0.0, max(0.0, maxLeft)));
    }
    setState(() => _zoom = zoom);
  }

  void _zoomBy(double factor, Offset focal) => _zoomTo(_zoom * factor, focal);

  // The panel center, to zoom from the keyboard.
  Offset get _center {
    final box = _viewportKey.currentContext?.findRenderObject() as RenderBox?;
    return box == null ? Offset.zero : box.size.center(Offset.zero);
  }

  // Ctrl+wheel zooms, instead of scrolling.
  void _onPointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent ||
        !HardwareKeyboard.instance.isControlPressed) {
      return;
    }
    GestureBinding.instance.pointerSignalResolver.register(event, (e) {
      final box = _viewportKey.currentContext?.findRenderObject() as RenderBox?;
      if (box == null) return;
      final dy = (e as PointerScrollEvent).scrollDelta.dy;
      _zoomBy(
        pow(_zoomStep, -dy / 100).toDouble(),
        box.globalToLocal(e.position),
      );
    });
  }

  // Scrolls as Windows does: a few lines with the arrows, a screen with Page
  // Up and Page Down, a sheet with Left and Right. Ctrl with +, - or 0 zooms.
  KeyEventResult _onKey(FocusNode _, KeyEvent event) {
    if (event is KeyUpEvent || !_scroll.hasClients) {
      return KeyEventResult.ignored;
    }
    if (HardwareKeyboard.instance.isControlPressed) {
      final zoom = switch (event.logicalKey) {
        LogicalKeyboardKey.equal ||
        LogicalKeyboardKey.numpadAdd => _zoom * _zoomStep,
        LogicalKeyboardKey.minus ||
        LogicalKeyboardKey.numpadSubtract => _zoom / _zoomStep,
        LogicalKeyboardKey.digit0 || LogicalKeyboardKey.numpad0 => 1.0,
        _ => null,
      };
      if (zoom == null) return KeyEventResult.ignored;
      _zoomTo(zoom, _center);
      return KeyEventResult.handled;
    }
    final position = _scroll.position;
    final offset = position.pixels;
    final screen = position.viewportDimension - _lineStep;
    // The sheet at the top, counting one just scrolled to as reached.
    final at = offset / _extent + 0.01;
    final sheet = at.floor();
    final double? target = switch (event.logicalKey) {
      LogicalKeyboardKey.arrowDown => offset + _lineStep,
      LogicalKeyboardKey.arrowUp => offset - _lineStep,
      LogicalKeyboardKey.pageDown => offset + screen,
      LogicalKeyboardKey.pageUp => offset - screen,
      LogicalKeyboardKey.arrowRight => (sheet + 1) * _extent,
      // The start of this sheet, or of the one before when there already.
      LogicalKeyboardKey.arrowLeft =>
        (at - sheet < 0.02 ? sheet - 1 : sheet) * _extent,
      LogicalKeyboardKey.home => 0,
      LogicalKeyboardKey.end => position.maxScrollExtent,
      _ => null,
    };
    if (target == null) return KeyEventResult.ignored;
    _scroll.animateTo(
      target.clamp(0.0, position.maxScrollExtent),
      duration: const Duration(milliseconds: 120),
      curve: Curves.easeOut,
    );
    return KeyEventResult.handled;
  }

  @override
  void didUpdateWidget(PrintPreviewPanel old) {
    super.didUpdateWidget(old);
    if (old.preview?.id != widget.preview?.id) {
      _invalidate();
      // Details show the old layout: drop them, unlike the sheets.
      _details.clear();
      _detailRequests.clear();
      _detailGeneration++;
    }
    if (old.pageCount != widget.pageCount ||
        !listEquals(
          old.options.pageRanges ?? const [],
          widget.options.pageRanges ?? const [],
        )) {
      _recomputeSelection();
    }
  }

  // Updates the details once the scroll and zoom settle.
  void _scheduleDetails() {
    _detailTimer?.cancel();
    _detailTimer = Timer(const Duration(milliseconds: 150), _updateDetails);
  }

  // Renders the shown part of each shown sheet at its shown size, when the
  // sheet renders are smaller: zoomed in past 100%.
  void _updateDetails() {
    final preview = widget.preview;
    final box = _box;
    if (!mounted || preview == null || box == null || !_scroll.hasClients) {
      return;
    }
    final room = _roomAt(_zoom);
    final sheetSize = Size(room.width, _extent - 2 * _border - _labelHeight);
    final sheetWidth = (sheetSize.width * _dpr).floor();
    // The sheet renders fit the box, at its paper shape.
    final baseWidth = min(
      box.$1.toDouble(),
      box.$2 * sheetSize.width / sheetSize.height,
    );
    if (sheetWidth <= baseWidth + 1.5 || sheetSize.height <= 0) {
      if (_details.isNotEmpty) setState(_details.clear);
      return;
    }

    // The shown part of the list, and where the sheets are in it.
    final v = _scroll.position;
    final left = _hScroll.hasClients ? _hScroll.position.pixels : 0.0;
    final shown = Rect.fromLTWH(
      left,
      v.pixels,
      _viewport.width,
      v.viewportDimension,
    );
    final contentWidth = max(
      _viewport.width,
      room.width + 2 * (_border + _side),
    );
    final sheetLeft = (contentWidth - room.width) / 2;
    final first = max(0, (shown.top / _extent).floor());
    final last = min(_selected.length - 1, (shown.bottom / _extent).floor());

    final keep = <int>{};
    for (var i = first; i <= last; i++) {
      final page = _selected[i];
      final sheet = Offset(sheetLeft, i * _extent + _border) & sheetSize;
      final part = sheet.intersect(shown);
      if (part.width <= 0 || part.height <= 0) continue;
      keep.add(page);
      final region = (
        left: ((part.left - sheet.left) * _dpr).floor(),
        top: ((part.top - sheet.top) * _dpr).floor(),
        right: ((part.right - sheet.left) * _dpr).ceil(),
        bottom: ((part.bottom - sheet.top) * _dpr).ceil(),
      );
      // Skip what is shown or on its way already.
      final want = (sheetWidth, region);
      final had = _details[page];
      if ((had != null && (had.sheetWidth, had.region) == want) ||
          _detailRequests[page] == want) {
        continue;
      }
      _detailRequests[page] = want;
      final generation = _detailGeneration;
      WindowsPrintChannel.renderPreviewPage(
        preview.id,
        page,
        sheetWidth,
        1 << 20,
        region: region,
      ).then<Uint8List?>((png) => png, onError: (Object _) => null).then((png) {
        if (_detailRequests[page] == want) _detailRequests.remove(page);
        if (!mounted || png == null || generation != _detailGeneration) {
          return;
        }
        setState(
          () => _details[page] = (
            sheetWidth: sheetWidth,
            region: region,
            png: png,
          ),
        );
      });
    }
    _details.removeWhere((page, _) => !keep.contains(page));
  }

  /// Rebuilds [_selected] from the page ranges.
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
  }

  // Drops the rendered sheets, but keeps them up until they render again.
  void _invalidate() {
    for (final MapEntry(:key, :value) in _sheets.entries) {
      if (value != null) _stale[key] = value;
    }
    _generation++;
    _sheets.clear();
    _pending.clear();
  }

  // Forgets the sheets far from the shown ones. The list renders them again
  // when they come back.
  void _forgetFarSheets() {
    if (!_scroll.hasClients) return;
    final first = (_scroll.offset / _extent).floor();
    final last =
        ((_scroll.offset + _scroll.position.viewportDimension) / _extent)
            .ceil();
    final keep = {
      for (
        var i = max(0, first - 2);
        i <= min(_selected.length - 1, last + 2);
        i++
      )
        _selected[i],
    };
    _sheets.removeWhere((page, _) => !keep.contains(page));
    _stale.removeWhere((page, _) => !keep.contains(page));
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
        _stale.remove(page);
      });
    });
  }

  // Renders again for a new room, once it settles. Meanwhile, the old sheets
  // show at their size, or shrink to fit.
  void _onRoom(Size room, double dpr) {
    final box = (
      min(4096, (room.width * dpr).floor()),
      min(4096, (room.height * dpr).floor()),
    );
    if (box.$1 <= 0 || box.$2 <= 0 || box == _box) return;
    _resize?.cancel();
    if (_box == null) {
      _box = box;
      return;
    }
    _resize = Timer(const Duration(milliseconds: 200), () {
      if (!mounted) return;
      setState(() {
        _invalidate();
        _box = box;
      });
    });
  }

  /// The sheet of [page], null while it renders. Empty when it can't render.
  Uint8List? _sheetOf(int page) {
    if (_sheets.containsKey(page)) return _sheets[page] ?? Uint8List(0);
    return _stale[page];
  }

  /// The sheet in [size], with its [detail] over it.
  Widget _buildSheet(
    BuildContext context,
    Uint8List? sheet,
    bool exact,
    Size size,
    _Detail? detail,
  ) {
    if (sheet == null) return const Center(child: WinProgressRing());
    if (sheet.isEmpty) {
      return Center(
        child: Text(PrintLocalizations.of(context).previewUnavailable),
      );
    }
    // At its pixel size, nearest sampling copies the pixels. Smooth sampling
    // blurs them when the sheet sits between pixels.
    Widget img = Image.memory(
      sheet,
      fit: BoxFit.fill,
      gaplessPlayback: true,
      filterQuality: exact ? FilterQuality.none : FilterQuality.medium,
    );
    if (detail != null) {
      // Logical pixels per detail pixel: 1 / dpr, until the zoom changes.
      final k = size.width / detail.sheetWidth;
      final r = detail.region;
      img = Stack(
        fit: StackFit.expand,
        children: [
          img,
          Positioned(
            left: r.left * k,
            top: r.top * k,
            width: (r.right - r.left) * k,
            height: (r.bottom - r.top) * k,
            child: Image.memory(
              detail.png,
              fit: BoxFit.fill,
              gaplessPlayback: true,
              filterQuality: (k * _dpr - 1).abs() < 0.001
                  ? FilterQuality.none
                  : FilterQuality.medium,
            ),
          ),
        ],
      );
    }
    if (!(widget.options.color ?? true)) {
      img = ColorFiltered(colorFilter: _grayscaleFilter, child: img);
    }
    return img;
  }

  /// Logical size of [sheet] fitted in [room], and whether it shows at its
  /// pixel size: it does when rendered for this room. Before a sheet is in,
  /// the chosen paper fitted in [room].
  (Size, bool) _sheetSize(Uint8List? sheet, Size room, double dpr) {
    final px = sheet == null ? null : _pngSize(sheet);
    if (px != null) {
      final fitted = _fit(Size(px.$1.toDouble(), px.$2.toDouble()), room);
      if ((px.$1 - fitted.width * dpr).abs() < 1.5) {
        return (Size(px.$1 / dpr, px.$2 / dpr), true);
      }
      // Rendered for another room or zoom: scaled until it renders again.
      return (fitted, false);
    }
    return (_fit(_paperShape, room), false);
  }

  Widget _buildPage(BuildContext context, int page, Size room, double dpr) {
    final colors = WinTheme.of(context).colors;
    final sheet = _sheetOf(page);
    // Render it for the current room, also while its old render shows.
    if (!_sheets.containsKey(page)) _render(page);
    final (size, exact) = _sheetSize(sheet, room, dpr);
    // On the sheets, Ctrl+wheel zooms before the list scrolls.
    return Listener(
      onPointerSignal: _onPointerSignal,
      child: Column(
        children: [
          SizedBox(
            height: _extent - _labelHeight,
            child: Center(
              child: Container(
                // A visible edge and a light shadow, as paper.
                decoration: BoxDecoration(
                  color: colors.cardBackground,
                  border: Border.all(
                    color: colors.surfaceStroke,
                    width: _border,
                  ),
                  borderRadius: BorderRadius.circular(4),
                  boxShadow: const [
                    BoxShadow(
                      color: Color(0x1F000000),
                      blurRadius: 4,
                      offset: Offset(0, 1),
                    ),
                  ],
                ),
                clipBehavior: Clip.antiAlias,
                child: SizedBox.fromSize(
                  size: size,
                  child: _buildSheet(
                    context,
                    sheet,
                    exact,
                    size,
                    _details[page],
                  ),
                ),
              ),
            ),
          ),
          SizedBox(
            height: _labelHeight,
            child: Center(
              child: Text(
                '${page + 1} / $_pageCount',
                style: TextStyle(fontSize: 12, color: colors.textSecondary),
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_selected.isEmpty) {
      return Center(
        child: widget.pageCount == null
            ? const WinProgressRing()
            : Text(PrintLocalizations.of(context).previewUnavailable),
      );
    }
    final dpr = MediaQuery.devicePixelRatioOf(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        // Each sheet fills the panel width, inside its card border, at 100%.
        _fitWidth = max(0.0, constraints.maxWidth - 2 * (_border + _side));
        _viewport = constraints.biggest;
        _dpr = dpr;
        final room = _roomAt(_zoom);
        // Zoomed in, the sheets stay at their 100% render: the details cover
        // the shown part.
        _onRoom(_roomAt(min(_zoom, 1.0)), dpr);
        _extent = _extentIn(room);
        _scheduleDetails();
        // Zoomed in, the sheets are wider than the panel: it scrolls sideways.
        final width = max(
          constraints.maxWidth,
          room.width + 2 * (_border + _side),
        );
        final color = WinTheme.of(context).colors.controlStrongStroke;
        return Focus(
          focusNode: _focus,
          autofocus: true,
          onKeyEvent: _onKey,
          child: Listener(
            key: _viewportKey,
            // A click focuses the preview, for the keys.
            onPointerDown: (_) => _focus.requestFocus(),
            // Where no sheet is, e.g. under the last one.
            onPointerSignal: _onPointerSignal,
            // The vertical scrollbar stays at the panel edge, outside the
            // sideways scroll view.
            child: ScrollConfiguration(
              behavior: ScrollConfiguration.of(
                context,
              ).copyWith(scrollbars: false),
              child: WinScrollbar(
                controller: _scroll,
                axis: Axis.vertical,
                color: color,
                nested: true,
                child: WinScrollbar(
                  controller: _hScroll,
                  axis: Axis.horizontal,
                  color: color,
                  child: SingleChildScrollView(
                    controller: _hScroll,
                    scrollDirection: Axis.horizontal,
                    child: SizedBox(
                      width: width,
                      height: constraints.maxHeight,
                      child: ListView.builder(
                        controller: _scroll,
                        itemExtent: _extent,
                        // Build, and so render, a sheet ahead each way.
                        scrollCacheExtent: ScrollCacheExtent.pixels(_extent),
                        itemCount: _selected.length,
                        itemBuilder: (context, i) =>
                            _buildPage(context, _selected[i], room, dpr),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
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

/// A render of part of a sheet: [region], in the pixels of the sheet at
/// [sheetWidth].
typedef _Detail = ({
  int sheetWidth,
  ({int left, int top, int right, int bottom}) region,
  Uint8List png,
});
