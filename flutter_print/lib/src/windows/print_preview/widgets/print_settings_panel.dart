import 'package:flutter/widgets.dart';
import 'package:flutter_print_platform_interface/flutter_print_platform_interface.dart';

import '../../windows_print_channel.dart';
import '../l10n/print_localizations.dart';
import '../print_dialog_utils.dart';
import '../../windows_ui/windows_ui.dart';

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

  /// True while the user picks pages rather than all of them.
  bool _customPages = false;

  /// Use the printer's default paper until the caller or the user sets one.
  late bool _followPrinterPaper;

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

    // No limit on copies: the plugin draws those the driver can't make.
    _options = _options.copyWith(
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
    _customPages = _presetRanges != null;
    _followPrinterPaper = ps == null;

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

  // Always show custom pages, so the user can see and fix them, even when a
  // new layout leaves a single page.
  bool get _showPages {
    final count = widget.pageCount;
    return count != null && (count > 1 || _customPages);
  }

  // Counts printer changes, to drop the paper of an older printer.
  int _printerChange = 0;

  // Emits the printer once with its paper, so the preview is laid out once.
  Future<void> _onPrinterChanged(PrinterInfo? info) async {
    final change = ++_printerChange;
    final printer = info?.address ?? info?.label;
    PageSize? paper;
    if (_followPrinterPaper && printer != null) {
      try {
        final name = await WindowsPrintChannel.getDefaultPaperSize(printer);
        if (name != null) paper = _resolvePageSize(name);
      } catch (_) {
        // Keep the current paper.
      }
      if (!mounted || change != _printerChange) return;
    }
    _caps = info?.capabilities;
    // Keep the paper the user picked meanwhile.
    _emit(
      _options.copyWith(
        printerAddress: printer,
        pageSize: _followPrinterPaper ? paper : null,
      ),
    );
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
      // Room for the focus rings, and the scrollbar on the right.
      padding: const EdgeInsets.fromLTRB(3, 3, 10, 3),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _SectionLabel(l10n.printer),
          _PrinterSelector(
            initialAddress: _options.printerAddress,
            onChanged: _onPrinterChanged,
          ),
          ..._section(
            l10n.copies,
            _CopiesSelector(
              value: _options.copies ?? 1,
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
                  setState(
                    () => _customPages = ranges == null || ranges.isNotEmpty,
                  );
                  widget.onPagesValidChanged(ranges != null);
                  if (ranges != null) {
                    _emit(_options.copyWith(pageRanges: ranges));
                  }
                },
              ),
            ),
          ..._section(
            l10n.layout,
            WinComboBox(
              value: _options.landscape ?? false,
              items: {false: l10n.portrait, true: l10n.landscape},
              onChanged: (v) => _emit(_options.copyWith(landscape: v)),
            ),
          ),
          if (_caps?.colorCapability != ColorCapability.monochrome &&
              _caps?.colorCapability != ColorCapability.enforced)
            ..._section(
              l10n.color,
              WinComboBox(
                value: _options.color ?? true,
                items: {true: l10n.colorMode, false: l10n.grayscale},
                onChanged: (v) => _emit(_options.copyWith(color: v)),
              ),
            ),
          ..._section(
            l10n.paperSize,
            WinComboBox(
              value: _options.pageSize?.name,
              items: {for (final n in _supportedPageSizeNames) n: n},
              onChanged: (v) {
                _followPrinterPaper = false;
                _emit(_options.copyWith(pageSize: _resolvePageSize(v)));
              },
            ),
          ),
          if (_caps?.supportsDuplex != false)
            ..._section(
              l10n.twoSided,
              WinComboBox(
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
      child: Text(text, style: WinTheme.of(context).typography.bodyStrong),
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

      // Keep the caller's printer when it exists, else take the default.
      final def =
          printers.where((p) => _keyOf(p) == _selectedAddress).firstOrNull ??
          printers.where((p) => p.isDefault).firstOrNull ??
          printers.firstOrNull;

      setState(() {
        _printers = printers;
        _selectedAddress = def == null ? null : _keyOf(def);
        _loading = false;
      });

      widget.onChanged(_selectedInfo);
    } catch (_) {
      if (!mounted) return;
      setState(() => _loading = false);
      // Still emit, so the dialog shows the preview.
      widget.onChanged(null);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const WinProgressRing(size: 20, strokeWidth: 2);

    final l10n = PrintLocalizations.of(context);
    if (_printers.isEmpty) return Text(l10n.noPrintersFound);

    return WinComboBox<String>(
      value: _selectedAddress,
      onChanged: (v) {
        setState(() => _selectedAddress = v);
        widget.onChanged(_selectedInfo);
      },
      items: {
        for (final p in _printers)
          _keyOf(p): l10n.printerDisplayName(p.label, isDefault: p.isDefault),
      },
    );
  }
}

class _CopiesSelector extends StatelessWidget {
  const _CopiesSelector({required this.value, required this.onChanged});

  final int value;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    return WinNumberBox(
      value: value,
      min: 1,
      max: 999,
      onChanged: onChanged,
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
  void didUpdateWidget(_PagesSelector oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A new layout can change the page count: check the ranges again, once
    // the parent is built.
    if (_custom && widget.pageCount != oldWidget.pageCount) {
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        WinComboBox(
          value: _custom,
          items: {false: l10n.allPages, true: l10n.pageRangeCustom},
          onChanged: (v) {
            _custom = v;
            _emit();
          },
        ),
        if (_custom) ...[
          const SizedBox(height: 8),
          WinTextBox(
            controller: _controller,
            placeholder: '2-6, 9, 15',
            error: _invalid,
            onChanged: (_) => _emit(),
          ),
        ],
      ],
    );
  }
}
