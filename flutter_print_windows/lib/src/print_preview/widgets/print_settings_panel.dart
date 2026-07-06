import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_print_platform_interface/flutter_print_platform_interface.dart';

import '../../windows_print_channel.dart';
import '../l10n/print_localizations.dart';
import '../print_dialog_utils.dart';

class PrintSettingsPanel extends StatefulWidget {
  const PrintSettingsPanel({
    super.key,
    required this.filePath,
    required this.initialOptions,
    required this.onOptionsChanged,
  });

  final String filePath;
  final PrintOptions initialOptions;
  final ValueChanged<PrintOptions> onOptionsChanged;

  @override
  State<PrintSettingsPanel> createState() => _PrintSettingsPanelState();
}

class _PrintSettingsPanelState extends State<PrintSettingsPanel> {
  late PrintOptions _options;
  PageSize? _customPageSize;
  PrinterCapabilities? _caps;

  // Page-range selection. Only offered for multi-page (PDF) documents, so the
  // control stays hidden until the page count is known and greater than one.
  int _pageCount = 0;

  List<String> get _supportedPageSizeNames {
    final known = _caps?.supportedPageSizes.toSet();
    final List<String> base;
    if (known == null || known.isEmpty) {
      base = allPageSizes;
    } else {
      final filtered = allPageSizes.where(known.contains).toList();
      base = filtered.isEmpty ? allPageSizes : filtered;
    }
    final custom = _customPageSize;
    if (custom != null && !base.contains(custom.name)) {
      return [custom.name, ...base];
    }
    return base;
  }

  PageSize _resolvePageSize(String name) {
    return (_customPageSize != null && name == _customPageSize!.name)
        ? _customPageSize!
        : pageSizeFromName(name);
  }

  void _validateSettings() {
    final caps = _caps;
    if (caps == null) return;

    int copies = _options.copies ?? 1;
    if (caps.maxCopies != null && copies > caps.maxCopies!) {
      copies = caps.maxCopies!;
    }

    bool color = _options.color ?? true;
    switch (caps.colorCapability) {
      case ColorCapability.enforced:
        color = true;
      case ColorCapability.monochrome:
        color = false;
      default:
        break;
    }

    DuplexMode duplex = _options.duplexMode ?? DuplexMode.none;
    if (caps.supportsDuplex == false) duplex = DuplexMode.none;

    final sizes = _supportedPageSizeNames;
    final currentName = _options.pageSize?.name ?? 'A4';
    final validatedName = sizes.contains(currentName)
        ? currentName
        : sizes.first;

    _options = _options.copyWith(
      copies: copies,
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

    if (ps != null && !allPageSizes.contains(ps.name)) {
      _customPageSize = ps;
    }

    // Normalise unset fields to concrete display defaults so the dialog UI and
    // preview stay consistent; the user's choices are then sent explicitly.
    _options = opts.copyWith(
      copies: opts.copies ?? 1,
      landscape: opts.landscape ?? false,
      color: opts.color ?? true,
      pageSize: _resolvePageSize(ps?.name ?? 'A4'),
    );

    _loadPageCount();
  }

  Future<void> _loadPageCount() async {
    final mime = await WindowsPrintChannel.getMimeType(widget.filePath);
    if (!mounted || !mimeIsPdf(mime)) return;
    final count = await WindowsPrintChannel.getPdfPageCount(widget.filePath);
    if (mounted) setState(() => _pageCount = count);
  }

  void _emit(PrintOptions opts) {
    setState(() {
      _options = opts;
      _validateSettings();
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
              setState(() {
                _caps = info?.capabilities;
                _options = _options.copyWith(
                  printerAddress: info?.address ?? info?.label,
                );
                _validateSettings();
              });
              widget.onOptionsChanged(_options);
            },
          ),
          if (_caps?.maxCopies != 1) ...[
            const SizedBox(height: 14),
            _SectionLabel(l10n.copies),
            _CopiesSelector(
              value: _options.copies ?? 1,
              max: _caps?.maxCopies,
              onChanged: (v) => _emit(_options.copyWith(copies: v)),
            ),
          ],
          if (_pageCount > 1) ...[
            const SizedBox(height: 14),
            _SectionLabel(l10n.pages),
            _PagesSelector(
              pageCount: _pageCount,
              onChanged: (ranges) =>
                  _emit(_options.copyWith(pageRanges: ranges)),
            ),
          ],
          const SizedBox(height: 14),
          _SectionLabel(l10n.layout),
          _LayoutSelector(
            value: _options.landscape ?? false,
            onChanged: (v) => _emit(_options.copyWith(landscape: v)),
          ),
          if (_caps?.colorCapability != ColorCapability.monochrome &&
              _caps?.colorCapability != ColorCapability.enforced) ...[
            const SizedBox(height: 14),
            _SectionLabel(l10n.color),
            _ColorSelector(
              value: _options.color ?? true,
              onChanged: (v) => _emit(_options.copyWith(color: v)),
            ),
          ],
          const SizedBox(height: 14),
          _SectionLabel(l10n.paperSize),
          _PaperSizeSelector(
            value: _options.pageSize?.name,
            sizes: _supportedPageSizeNames,
            onChanged: (v) {
              _emit(_options.copyWith(pageSize: _resolvePageSize(v)));
            },
          ),
          if (_caps?.supportsDuplex != false) ...[
            const SizedBox(height: 14),
            _SectionLabel(l10n.twoSided),
            _DuplexSelector(
              value: _options.duplexMode ?? DuplexMode.none,
              onChanged: (v) => _emit(_options.copyWith(duplexMode: v)),
            ),
          ],
        ],
      ),
    );
  }
}

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

  PrinterInfo? get _selectedInfo {
    return _selectedAddress == null
        ? null
        : _printers
              .where((p) => (p.address ?? p.label) == _selectedAddress)
              .firstOrNull;
  }

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

      final PrinterInfo? def = printers.isEmpty
          ? null
          : printers.firstWhere(
              (p) => p.isDefault,
              orElse: () => printers.first,
            );

      setState(() {
        _printers = printers;
        _selectedAddress = def?.address ?? def?.label;
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
              value: p.address ?? p.label,
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
  const _PagesSelector({required this.pageCount, required this.onChanged});

  final int pageCount;

  /// Emits the selected ranges, or an empty list for "all pages" (which is also
  /// used while a custom expression is blank or not yet valid).
  final ValueChanged<List<PageRange>> onChanged;

  @override
  State<_PagesSelector> createState() => _PagesSelectorState();
}

class _PagesSelectorState extends State<_PagesSelector> {
  final _controller = TextEditingController();
  bool _custom = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _emit() {
    if (!_custom) {
      widget.onChanged(const []);
      return;
    }
    final ranges = parsePageRanges(_controller.text, pageCount: widget.pageCount);
    widget.onChanged(ranges ?? const []);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = PrintLocalizations.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ComboBox<bool>(
          isExpanded: true,
          value: _custom,
          onChanged: (v) {
            if (v == null) return;
            setState(() => _custom = v);
            _emit();
          },
          items: [
            ComboBoxItem<bool>(value: false, child: Text(l10n.allPages)),
            ComboBoxItem<bool>(value: true, child: Text(l10n.pageRangeCustom)),
          ],
        ),
        if (_custom) ...[
          const SizedBox(height: 8),
          TextBox(
            controller: _controller,
            placeholder: '2-6, 9, 15',
            keyboardType: TextInputType.text,
            onChanged: (_) => _emit(),
          ),
        ],
      ],
    );
  }
}

class _LayoutSelector extends StatelessWidget {
  const _LayoutSelector({required this.value, required this.onChanged});

  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = PrintLocalizations.of(context);
    return ComboBox<bool>(
      isExpanded: true,
      value: value,
      onChanged: (v) {
        if (v != null) onChanged(v);
      },
      items: [
        ComboBoxItem<bool>(value: false, child: Text(l10n.portrait)),
        ComboBoxItem<bool>(value: true, child: Text(l10n.landscape)),
      ],
    );
  }
}

class _ColorSelector extends StatelessWidget {
  const _ColorSelector({required this.value, required this.onChanged});

  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = PrintLocalizations.of(context);
    return ComboBox<bool>(
      isExpanded: true,
      value: value,
      onChanged: (v) {
        if (v != null) onChanged(v);
      },
      items: [
        ComboBoxItem<bool>(value: true, child: Text(l10n.colorMode)),
        ComboBoxItem<bool>(value: false, child: Text(l10n.grayscale)),
      ],
    );
  }
}

class _PaperSizeSelector extends StatelessWidget {
  const _PaperSizeSelector({
    required this.value,
    required this.sizes,
    required this.onChanged,
  });

  final String? value;
  final List<String> sizes;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    return ComboBox<String>(
      isExpanded: true,
      value: value,
      onChanged: (v) {
        if (v != null) onChanged(v);
      },
      items: sizes
          .map((n) => ComboBoxItem<String>(value: n, child: Text(n)))
          .toList(),
    );
  }
}

class _DuplexSelector extends StatelessWidget {
  const _DuplexSelector({required this.value, required this.onChanged});

  final DuplexMode value;
  final ValueChanged<DuplexMode> onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = PrintLocalizations.of(context);

    return ComboBox<DuplexMode>(
      isExpanded: true,
      value: value,
      onChanged: (v) {
        if (v != null) onChanged(v);
      },
      items: [
        ComboBoxItem<DuplexMode>(value: DuplexMode.none, child: Text(l10n.off)),
        ComboBoxItem<DuplexMode>(
          value: DuplexMode.longEdge,
          child: Text(l10n.longEdge),
        ),
        ComboBoxItem<DuplexMode>(
          value: DuplexMode.shortEdge,
          child: Text(l10n.shortEdge),
        ),
      ],
    );
  }
}
