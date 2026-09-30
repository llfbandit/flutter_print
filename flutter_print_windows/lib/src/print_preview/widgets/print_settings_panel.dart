import 'dart:math' show min;

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_print_platform_interface/flutter_print_platform_interface.dart';

import '../l10n/print_localizations.dart';
import '../print_dialog_utils.dart';

class PrintSettingsPanel extends StatefulWidget {
  const PrintSettingsPanel({
    super.key,
    required this.pageCount,
    required this.initialOptions,
    required this.onOptionsChanged,
    required this.onPagesValidChanged,
  });

  /// Null while loading, 0 when unknown.
  final int? pageCount;
  final PrintOptions initialOptions;
  final ValueChanged<PrintOptions> onOptionsChanged;
  final ValueChanged<bool> onPagesValidChanged;

  @override
  State<PrintSettingsPanel> createState() => _PrintSettingsPanelState();
}

class _PrintSettingsPanelState extends State<PrintSettingsPanel> {
  late PrintOptions _options;
  PageSize? _customPageSize;
  PrinterCapabilities? _caps;
  List<PageRange>? _presetRanges;

  List<String> get _supportedPageSizeNames {
    final known = _caps?.supportedPageSizes.toSet() ?? const {};
    final filtered = allPageSizes.where(known.contains).toList();
    final base = filtered.isEmpty ? allPageSizes : filtered;
    final custom = _customPageSize;
    if (custom != null && !base.contains(custom.name)) {
      return [custom.name, ...base];
    }
    return base;
  }

  PageSize _resolvePageSize(String name) {
    final custom = _customPageSize;
    return name == custom?.name ? custom! : pageSizeFromName(name);
  }

  // Limits the options to what the printer supports.
  void _fitToCapabilities() {
    final caps = _caps;
    if (caps == null) return;

    final copies = _options.copies ?? 1;
    final color = switch (caps.colorCapability) {
      ColorCapability.enforced => true,
      ColorCapability.monochrome => false,
      _ => _options.color ?? true,
    };
    final duplex = caps.supportsDuplex == false
        ? DuplexMode.none
        : _options.duplexMode ?? DuplexMode.none;

    final sizes = _supportedPageSizeNames;
    final currentName = _options.pageSize?.name ?? 'A4';
    final validatedName = sizes.contains(currentName)
        ? currentName
        : sizes.first;

    _options = _options.copyWith(
      copies: min(copies, caps.maxCopies ?? copies),
      color: color,
      duplexMode: duplex,
      pageSize: _resolvePageSize(validatedName),
    );
  }

  @override
  void initState() {
    super.initState();

    final opts = widget.initialOptions;
    final ps = opts.pageSize;
    if (opts.pageRanges?.isNotEmpty ?? false) _presetRanges = opts.pageRanges;

    if (ps != null && !allPageSizes.contains(ps.name)) {
      _customPageSize = ps;
    }

    // Fill unset fields with the values the UI shows, so the preview and the
    // print job match them.
    _options = opts.copyWith(
      copies: opts.copies ?? 1,
      landscape: opts.landscape ?? false,
      color: opts.color ?? true,
      pageSize: _resolvePageSize(ps?.name ?? 'A4'),
    );
  }

  // Always show a preset range, so the user can see and fix it.
  bool get _showPages {
    final count = widget.pageCount;
    return count != null && (count > 1 || _presetRanges != null);
  }

  void _emit(PrintOptions opts) {
    setState(() {
      _options = opts;
      _fitToCapabilities();
    });

    widget.onOptionsChanged(_options);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = PrintLocalizations.of(context);

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _SectionLabel(l10n.printer),
          _PrinterSelector(
            initialAddress: _options.printerAddress,
            onChanged: (info) {
              _caps = info?.capabilities;
              _emit(
                _options.copyWith(printerAddress: info?.address ?? info?.label),
              );
            },
          ),
          if (_caps?.maxCopies != 1)
            ..._section(
              l10n.copies,
              _CopiesSelector(
                value: _options.copies ?? 1,
                max: _caps?.maxCopies,
                onChanged: (v) => _emit(_options.copyWith(copies: v)),
              ),
            ),
          if (_showPages)
            ..._section(
              l10n.pages,
              _PagesSelector(
                pageCount: widget.pageCount!,
                initialRanges: _presetRanges,
                onChanged: (ranges) {
                  widget.onPagesValidChanged(ranges != null);
                  if (ranges != null) {
                    _emit(_options.copyWith(pageRanges: ranges));
                  }
                },
              ),
            ),
          ..._section(
            l10n.layout,
            _Choice(
              value: _options.landscape ?? false,
              items: {false: l10n.portrait, true: l10n.landscape},
              onChanged: (v) => _emit(_options.copyWith(landscape: v)),
            ),
          ),
          if (_caps?.colorCapability != ColorCapability.monochrome &&
              _caps?.colorCapability != ColorCapability.enforced)
            ..._section(
              l10n.color,
              _Choice(
                value: _options.color ?? true,
                items: {true: l10n.colorMode, false: l10n.grayscale},
                onChanged: (v) => _emit(_options.copyWith(color: v)),
              ),
            ),
          ..._section(
            l10n.paperSize,
            _Choice(
              value: _options.pageSize?.name,
              items: {for (final n in _supportedPageSizeNames) n: n},
              onChanged: (v) =>
                  _emit(_options.copyWith(pageSize: _resolvePageSize(v))),
            ),
          ),
          if (_caps?.supportsDuplex != false)
            ..._section(
              l10n.twoSided,
              _Choice(
                value: _options.duplexMode ?? DuplexMode.none,
                items: {
                  DuplexMode.none: l10n.off,
                  DuplexMode.longEdge: l10n.longEdge,
                  DuplexMode.shortEdge: l10n.shortEdge,
                },
                onChanged: (v) => _emit(_options.copyWith(duplexMode: v)),
              ),
            ),
        ],
      ),
    );
  }
}

List<Widget> _section(String label, Widget child) => [
  const SizedBox(height: 14),
  _SectionLabel(label),
  child,
];

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Text(text, style: FluentTheme.of(context).typography.bodyStrong),
    );
  }
}

class _PrinterSelector extends StatefulWidget {
  const _PrinterSelector({
    required this.initialAddress,
    required this.onChanged,
  });

  final String? initialAddress;
  final ValueChanged<PrinterInfo?> onChanged;

  @override
  State<_PrinterSelector> createState() => _PrinterSelectorState();
}

class _PrinterSelectorState extends State<_PrinterSelector> {
  final _api = FlutterPrintApi();
  List<PrinterInfo> _printers = [];
  bool _loading = true;
  String? _selectedAddress;

  static String _keyOf(PrinterInfo p) => p.address ?? p.label;

  PrinterInfo? get _selectedInfo =>
      _printers.where((p) => _keyOf(p) == _selectedAddress).firstOrNull;

  @override
  void initState() {
    super.initState();
    _selectedAddress = widget.initialAddress;
    _loadPrinters();
  }

  Future<void> _loadPrinters() async {
    try {
      final printers = await _api.listPrinters();
      if (!mounted) return;

      final def =
          printers.where((p) => p.isDefault).firstOrNull ??
          printers.firstOrNull;

      setState(() {
        _printers = printers;
        _selectedAddress = def == null ? null : _keyOf(def);
        _loading = false;
      });

      widget.onChanged(_selectedInfo);
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const ProgressRing(strokeWidth: 2);

    final l10n = PrintLocalizations.of(context);
    if (_printers.isEmpty) return Text(l10n.noPrintersFound);

    return ComboBox<String>(
      isExpanded: true,
      value: _selectedAddress,
      onChanged: (v) {
        if (v == null) return;
        setState(() => _selectedAddress = v);
        widget.onChanged(_selectedInfo);
      },
      items: _printers
          .map(
            (p) => ComboBoxItem<String>(
              value: _keyOf(p),
              child: Text(
                l10n.printerDisplayName(p.label, isDefault: p.isDefault),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          )
          .toList(),
    );
  }
}

class _CopiesSelector extends StatelessWidget {
  const _CopiesSelector({
    required this.value,
    required this.onChanged,
    this.max,
  });

  final int value;
  final int? max;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    return NumberBox<int>(
      value: value,
      min: 1,
      max: max ?? 99,
      onChanged: (v) {
        if (v != null) onChanged(v);
      },
      mode: SpinButtonPlacementMode.inline,
    );
  }
}

class _PagesSelector extends StatefulWidget {
  const _PagesSelector({
    required this.pageCount,
    required this.initialRanges,
    required this.onChanged,
  });

  /// 0 when unknown.
  final int pageCount;
  final List<PageRange>? initialRanges;

  /// Emits an empty list for all pages, or null when the custom text is blank
  /// or invalid.
  final ValueChanged<List<PageRange>?> onChanged;

  @override
  State<_PagesSelector> createState() => _PagesSelectorState();
}

class _PagesSelectorState extends State<_PagesSelector> {
  final _controller = TextEditingController();
  bool _custom = false;
  bool _invalid = false;

  @override
  void initState() {
    super.initState();
    final ranges = widget.initialRanges;
    if (ranges != null) {
      _custom = true;
      _controller.text = formatPageRanges(ranges);
      // Check the preset against the page count once the parent is built.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _emit();
      });
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _emit() {
    if (!_custom) {
      setState(() => _invalid = false);
      widget.onChanged(const []);
      return;
    }
    final ranges = parsePageRanges(
      _controller.text,
      pageCount: widget.pageCount,
    );
    // Keep blank text neutral; the parent still disables Print.
    setState(
      () => _invalid = ranges == null && _controller.text.trim().isNotEmpty,
    );
    widget.onChanged(ranges);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = PrintLocalizations.of(context);
    final errorColor = FluentTheme.of(
      context,
    ).resources.systemFillColorCritical;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _Choice(
          value: _custom,
          items: {false: l10n.allPages, true: l10n.pageRangeCustom},
          onChanged: (v) {
            _custom = v;
            _emit();
          },
        ),
        if (_custom) ...[
          const SizedBox(height: 8),
          TextBox(
            controller: _controller,
            placeholder: '2-6, 9, 15',
            keyboardType: TextInputType.text,
            highlightColor: _invalid ? errorColor : null,
            unfocusedColor: _invalid ? errorColor : null,
            onChanged: (_) => _emit(),
          ),
        ],
      ],
    );
  }
}

/// A full-width ComboBox over [items], shown in map order.
class _Choice<T> extends StatelessWidget {
  const _Choice({
    required this.value,
    required this.items,
    required this.onChanged,
  });

  final T? value;
  final Map<T, String> items;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    return ComboBox<T>(
      isExpanded: true,
      value: value,
      onChanged: (v) {
        if (v != null) onChanged(v);
      },
      items: [
        for (final MapEntry(:key, :value) in items.entries)
          ComboBoxItem<T>(value: key, child: Text(value)),
      ],
    );
  }
}
