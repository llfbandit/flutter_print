import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'control.dart';
import 'scroll.dart';
import 'theme.dart';

// Item metrics, in logical pixels.
const _itemHeight = 32.0;
const _itemMarginX = 6.0;
const _itemMarginY = 3.0;
const _itemExtent = _itemHeight + 2 * _itemMarginY;
const _listPadding = 4.0;
const _maxPopupHeight = 504.0;

// The popup grows from the selected item, then its shadow fades in.
const _openDuration = Duration(milliseconds: 300);
const _growCurve = Interval(0, 0.6, curve: Curves.easeOutCubic);
const _shadowCurve = Interval(0.6, 1, curve: Curves.easeOut);

/// A WinUI combo box over [items], shown in map order. It fills the width it
/// gets. Disabled when [onChanged] is null.
class WinComboBox<T> extends StatefulWidget {
  const WinComboBox({
    super.key,
    required this.value,
    required this.items,
    required this.onChanged,
  });

  final T? value;
  final Map<T, String> items;
  final ValueChanged<T>? onChanged;

  @override
  State<WinComboBox<T>> createState() => _WinComboBoxState<T>();
}

class _WinComboBoxState<T> extends State<WinComboBox<T>> {
  final _popup = OverlayPortalController();
  final _focus = FocusNode();

  // Taps on the box and its popup don't close the popup.
  final _tapGroup = Object();

  List<T> get _values => widget.items.keys.toList();
  int get _selected => _values.indexOf(widget.value as T);

  bool get _enabled => widget.onChanged != null && widget.items.isNotEmpty;

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  void _toggle() {
    if (_popup.isShowing) {
      _close();
    } else {
      setState(_popup.show);
    }
  }

  void _close() {
    if (!_popup.isShowing) return;
    setState(_popup.hide);
    _focus.requestFocus();
  }

  void _select(T value) {
    _close();
    if (value != widget.value) widget.onChanged?.call(value);
  }

  // Selects the next or previous item without opening the popup, as WinUI.
  void _step(int delta) {
    final values = _values;
    if (values.isEmpty) return;
    final i = (_selected + delta).clamp(0, values.length - 1);
    _select(values[i]);
  }

  Widget _buildPopup(BuildContext context) {
    final box = this.context.findRenderObject()! as RenderBox;
    final overlay =
        Overlay.of(this.context).context.findRenderObject()! as RenderBox;
    final anchor = MatrixUtils.transformRect(
      box.getTransformTo(overlay),
      Offset.zero & box.size,
    );
    return TapRegion(
      groupId: _tapGroup,
      onTapOutside: (_) => _close(),
      child: _Popup<T>(
        anchor: anchor,
        items: widget.items,
        selected: _selected,
        onSelect: _select,
        onClose: _close,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = WinTheme.of(context);
    final c = theme.colors;
    final label = widget.items[widget.value] ?? '';
    return OverlayPortal(
      controller: _popup,
      overlayChildBuilder: _buildPopup,
      child: TapRegion(
        groupId: _tapGroup,
        child: ControlBuilder(
          onPressed: _enabled ? _toggle : null,
          focusNode: _focus,
          shortcuts: const {
            SingleActivator(LogicalKeyboardKey.arrowDown): _StepIntent(1),
            SingleActivator(LogicalKeyboardKey.arrowUp): _StepIntent(-1),
            SingleActivator(LogicalKeyboardKey.arrowDown, alt: true):
                ActivateIntent(),
            SingleActivator(LogicalKeyboardKey.f4): ActivateIntent(),
          },
          actions: {
            _StepIntent: CallbackAction<_StepIntent>(
              onInvoke: (i) => _step(i.delta),
            ),
          },
          builder: (context, s) {
            final open = _popup.isShowing;
            return FocusRing(
              visible: s.focused && !open,
              child: CustomPaint(
                painter: ControlPainter(
                  fill: s.disabled
                      ? c.controlFillDisabled
                      : s.pressed || open
                      ? c.controlFillTertiary
                      : s.hovered
                      ? c.controlFillSecondary
                      : c.controlFill,
                  stroke: c.controlStroke,
                  bottom: s.pressed || open ? null : c.controlStrokeSecondary,
                ),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 32),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(11, 5, 11, 6),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.typography.body.copyWith(
                              color: s.disabled
                                  ? c.textDisabled
                                  : c.textPrimary,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        WinIcon(
                          WinIcons.chevronDown,
                          size: 12,
                          color: s.disabled ? c.textDisabled : c.textSecondary,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

class _StepIntent extends Intent {
  const _StepIntent(this.delta);

  final int delta;
}

/// The item list, placed with the selected item over the box.
class _Popup<T> extends StatefulWidget {
  const _Popup({
    required this.anchor,
    required this.items,
    required this.selected,
    required this.onSelect,
    required this.onClose,
  });

  /// The box, in the overlay.
  final Rect anchor;
  final Map<T, String> items;

  /// Index of the selected item, -1 for none.
  final int selected;
  final ValueChanged<T> onSelect;
  final VoidCallback onClose;

  @override
  State<_Popup<T>> createState() => _PopupState<T>();
}

class _PopupState<T> extends State<_Popup<T>>
    with SingleTickerProviderStateMixin {
  ScrollController? _scroll;
  late int _highlight = math.max(0, widget.selected);
  late final _open = AnimationController(vsync: this, duration: _openDuration)
    ..forward();
  late final _grow = CurvedAnimation(parent: _open, curve: _growCurve);
  late final _shadow = CurvedAnimation(parent: _open, curve: _shadowCurve);

  // Takes the focus from the box. Autofocus wouldn't: the dialog scope
  // already has a focused control.
  final _focus = FocusNode();

  List<T> get _values => widget.items.keys.toList();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focus.requestFocus();
    });
  }

  @override
  void dispose() {
    _focus.dispose();
    _grow.dispose();
    _shadow.dispose();
    _open.dispose();
    _scroll?.dispose();
    super.dispose();
  }

  // Scrolls so the highlighted item shows.
  void _reveal(double viewport) {
    final scroll = _scroll;
    if (scroll == null || !scroll.hasClients) return;
    final top = _listPadding + _highlight * _itemExtent;
    if (top < scroll.offset) {
      scroll.jumpTo(top);
    } else if (top + _itemExtent > scroll.offset + viewport) {
      scroll.jumpTo(top + _itemExtent - viewport);
    }
  }

  KeyEventResult _onKey(FocusNode _, KeyEvent event, double viewport) {
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    final count = widget.items.length;
    void move(int to) {
      setState(() => _highlight = to.clamp(0, count - 1));
      _reveal(viewport);
    }

    switch (event.logicalKey) {
      case LogicalKeyboardKey.arrowDown:
        move(_highlight + 1);
      case LogicalKeyboardKey.arrowUp:
        move(_highlight - 1);
      case LogicalKeyboardKey.home:
        move(0);
      case LogicalKeyboardKey.end:
        move(count - 1);
      case LogicalKeyboardKey.enter:
      case LogicalKeyboardKey.space:
        widget.onSelect(_values[_highlight]);
      case LogicalKeyboardKey.escape:
      case LogicalKeyboardKey.tab:
        widget.onClose();
      default:
        return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final c = WinTheme.of(context).colors;
    return LayoutBuilder(
      builder: (context, constraints) {
        final screen = constraints.biggest;
        final anchor = widget.anchor;
        final count = widget.items.length;
        final content = count * _itemExtent + 2 * _listPadding + 2;
        final height = math.min(
          content,
          math.min(_maxPopupHeight, screen.height - 16),
        );

        // Center the selected item on the box, scrolling when the list is
        // taller than the popup.
        final sel = math.max(0, widget.selected);
        final selCenter =
            1 + _listPadding + sel * _itemExtent + _itemExtent / 2;
        final offset = (selCenter - height / 2).clamp(0.0, content - height);
        _scroll ??= ScrollController(initialScrollOffset: offset);
        final double top = (anchor.center.dy - (selCenter - offset)).clamp(
          8.0,
          math.max(8.0, screen.height - 8 - height),
        );
        final viewport = height - 2;

        // The popup starts as the selected item, over the box.
        const startHeight = _itemExtent + 2;
        final startTop = top + selCenter - offset - startHeight / 2;

        final list = ScrollConfiguration(
          behavior: WinScrollBehavior(c),
          child: ListView.builder(
            controller: _scroll,
            padding: const EdgeInsets.symmetric(vertical: _listPadding),
            itemExtent: _itemExtent,
            itemCount: count,
            itemBuilder: (context, i) => _Item(
              label: widget.items[_values[i]]!,
              selected: i == widget.selected,
              highlighted: i == _highlight,
              onHover: () => setState(() => _highlight = i),
              onTap: () => widget.onSelect(_values[i]),
            ),
          ),
        );

        return AnimatedBuilder(
          animation: _open,
          builder: (context, child) {
            final t = _grow.value;
            final shownTop = startTop + (top - startTop) * t;
            final shownHeight = startHeight + (height - startHeight) * t;
            return Stack(
              children: [
                Positioned(
                  // Align the item text with the box text.
                  left: anchor.left - 1 - _itemMarginX,
                  width: anchor.width + 2 * (1 + _itemMarginX),
                  top: shownTop,
                  height: shownHeight,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: c.flyoutBackground,
                      border: Border.all(color: c.flyoutStroke),
                      borderRadius: BorderRadius.circular(8),
                      boxShadow: [
                        BoxShadow(
                          color: Color.fromRGBO(0, 0, 0, 0.14 * _shadow.value),
                          blurRadius: 16,
                          offset: const Offset(0, 8),
                        ),
                      ],
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(7),
                      // Keep the list in its final place while the popup
                      // grows around it.
                      child: OverflowBox(
                        alignment: Alignment.topCenter,
                        minHeight: height - 2,
                        maxHeight: height - 2,
                        child: Transform.translate(
                          offset: Offset(0, top - shownTop),
                          child: child,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            );
          },
          child: Focus(
            focusNode: _focus,
            onKeyEvent: (node, event) => _onKey(node, event, viewport),
            child: list,
          ),
        );
      },
    );
  }
}

class _Item extends StatefulWidget {
  const _Item({
    required this.label,
    required this.selected,
    required this.highlighted,
    required this.onHover,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final bool highlighted;
  final VoidCallback onHover;
  final VoidCallback onTap;

  @override
  State<_Item> createState() => _ItemState();
}

class _ItemState extends State<_Item> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final c = WinTheme.of(context).colors;
    final fill = _pressed
        ? c.subtleFillTertiary
        : widget.highlighted || widget.selected
        ? c.subtleFillSecondary
        : const Color(0x00000000);
    return MouseRegion(
      onEnter: (_) => widget.onHover(),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (_) => setState(() => _pressed = true),
        onTapUp: (_) => setState(() => _pressed = false),
        onTapCancel: () => setState(() => _pressed = false),
        onTap: widget.onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: _itemMarginX,
            vertical: _itemMarginY,
          ),
          child: CustomPaint(
            painter: ControlPainter(fill: fill),
            child: Row(
              children: [
                // The selection mark.
                Container(
                  width: 3,
                  height: 16,
                  decoration: BoxDecoration(
                    color: widget.selected
                        ? c.accentFill
                        : const Color(0x00000000),
                    borderRadius: BorderRadius.circular(1.5),
                  ),
                ),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.only(left: 8, right: 11),
                    child: Text(
                      widget.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
