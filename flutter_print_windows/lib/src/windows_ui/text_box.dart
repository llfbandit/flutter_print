import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'button.dart';
import 'control.dart';
import 'theme.dart';

/// A WinUI text box. [error] marks its content as invalid.
class WinTextBox extends StatefulWidget {
  const WinTextBox({
    super.key,
    required this.controller,
    this.focusNode,
    this.placeholder,
    this.error = false,
    this.onChanged,
    this.onSubmitted,
    this.inputFormatters,
    this.trailing,
  });

  final TextEditingController controller;
  final FocusNode? focusNode;
  final String? placeholder;
  final bool error;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final List<TextInputFormatter>? inputFormatters;

  /// Shown at the end of the box, e.g. buttons.
  final Widget? trailing;

  @override
  State<WinTextBox> createState() => _WinTextBoxState();
}

class _WinTextBoxState extends State<WinTextBox>
    implements TextSelectionGestureDetectorBuilderDelegate {
  @override
  final editableTextKey = GlobalKey<EditableTextState>();

  @override
  bool get forcePressEnabled => false;

  @override
  bool get selectionEnabled => true;

  late final _gestures = TextSelectionGestureDetectorBuilder(delegate: this);
  FocusNode? _ownFocus;
  bool _hovered = false;

  FocusNode get _focus => widget.focusNode ?? (_ownFocus ??= FocusNode());

  @override
  void initState() {
    super.initState();
    _focus.addListener(_onFocus);
  }

  @override
  void didUpdateWidget(WinTextBox old) {
    super.didUpdateWidget(old);
    if (old.focusNode != widget.focusNode) {
      (old.focusNode ?? _ownFocus)?.removeListener(_onFocus);
      _focus.addListener(_onFocus);
    }
  }

  @override
  void dispose() {
    _focus.removeListener(_onFocus);
    _ownFocus?.dispose();
    super.dispose();
  }

  void _onFocus() => setState(() {});

  @override
  Widget build(BuildContext context) {
    final theme = WinTheme.of(context);
    final c = theme.colors;
    final focused = _focus.hasFocus;
    final underline = widget.error
        ? c.critical
        : focused
        ? c.accentFill
        : c.controlStrongStroke;

    final field = Padding(
      padding: const EdgeInsets.fromLTRB(11, 6, 11, 6),
      child: Stack(
        children: [
          if (widget.placeholder != null)
            ValueListenableBuilder(
              valueListenable: widget.controller,
              builder: (context, value, _) => value.text.isEmpty
                  ? Text(
                      widget.placeholder!,
                      maxLines: 1,
                      style: theme.typography.body.copyWith(
                        color: c.textTertiary,
                      ),
                    )
                  : const SizedBox.shrink(),
            ),
          EditableText(
            key: editableTextKey,
            controller: widget.controller,
            focusNode: _focus,
            style: theme.typography.body,
            cursorColor: c.textPrimary,
            backgroundCursorColor: c.textDisabled,
            selectionColor: c.accentFill.withValues(alpha: 0.4),
            cursorWidth: 1,
            maxLines: 1,
            rendererIgnoresPointer: true,
            inputFormatters: widget.inputFormatters,
            onChanged: widget.onChanged,
            onSubmitted: widget.onSubmitted,
            // Keep the focus on Enter, as Windows text boxes do.
            onEditingComplete: () {},
          ),
        ],
      ),
    );

    // Clicks anywhere on the box, its buttons included, keep the focus.
    return TextFieldTapRegion(
      child: MouseRegion(
        cursor: SystemMouseCursors.text,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: CustomPaint(
          painter: ControlPainter(
            fill: focused
                ? c.controlFillInputActive
                : _hovered
                ? c.controlFillSecondary
                : c.controlFill,
            stroke: c.controlStroke,
            bottom: underline,
            bottomWidth: focused ? 2 : 1,
          ),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 32),
            child: Row(
              children: [
                Expanded(
                  child: _gestures.buildGestureDetector(
                    behavior: HitTestBehavior.translucent,
                    child: field,
                  ),
                ),
                ?widget.trailing,
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _StepIntent extends Intent {
  const _StepIntent(this.delta);

  final int delta;
}

/// A WinUI number box for whole numbers, with inline spin buttons. Applies
/// the typed value on Enter or when it loses focus, clamped to [min] and
/// [max].
class WinNumberBox extends StatefulWidget {
  const WinNumberBox({
    super.key,
    required this.value,
    required this.onChanged,
    this.min = 0,
    this.max = 1 << 31,
  });

  final int value;
  final int min;
  final int max;
  final ValueChanged<int> onChanged;

  @override
  State<WinNumberBox> createState() => _WinNumberBoxState();
}

class _WinNumberBoxState extends State<WinNumberBox> {
  late final _controller = TextEditingController(text: '${widget.value}');
  final _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    _focus.addListener(() {
      if (!_focus.hasFocus) _commit();
    });
  }

  @override
  void didUpdateWidget(WinNumberBox old) {
    super.didUpdateWidget(old);
    if (widget.value != old.value) _controller.text = '${widget.value}';
  }

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _set(int value) {
    final v = value.clamp(widget.min, widget.max);
    _controller.text = '$v';
    if (v != widget.value) widget.onChanged(v);
  }

  // Applies the typed value, or restores the current one.
  void _commit() => _set(int.tryParse(_controller.text) ?? widget.value);

  void _step(int delta) =>
      _set((int.tryParse(_controller.text) ?? widget.value) + delta);

  @override
  Widget build(BuildContext context) {
    return Shortcuts(
      shortcuts: const {
        SingleActivator(LogicalKeyboardKey.arrowUp): _StepIntent(1),
        SingleActivator(LogicalKeyboardKey.arrowDown): _StepIntent(-1),
      },
      child: Actions(
        actions: {
          _StepIntent: CallbackAction<_StepIntent>(
            onInvoke: (i) => _step(i.delta),
          ),
        },
        child: WinTextBox(
          controller: _controller,
          focusNode: _focus,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          onSubmitted: (_) => _commit(),
          trailing: Padding(
            padding: const EdgeInsets.only(right: 4),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _SpinButton(
                  glyph: WinIcons.chevronUp,
                  onPressed: widget.value < widget.max ? () => _step(1) : null,
                ),
                _SpinButton(
                  glyph: WinIcons.chevronDown,
                  onPressed: widget.value > widget.min ? () => _step(-1) : null,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SpinButton extends StatelessWidget {
  const _SpinButton({required this.glyph, required this.onPressed});

  final int glyph;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    // Keep the focus in the text box.
    return ExcludeFocus(
      child: WinIconButton(
        glyph: glyph,
        onPressed: onPressed,
        size: const Size(28, 24),
      ),
    );
  }
}
