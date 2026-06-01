import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_print/flutter_print.dart';
import 'package:path_provider/path_provider.dart';

import 'blob/blob_url.dart';
import 'widgets.dart';

enum _FileType { pdf, image, text }

// Available paper sizes for the dropdown.
final _paperSizes = [
  PaperSizes.a3,
  PaperSizes.a4,
  PaperSizes.a5,
  PaperSizes.letter,
  PaperSizes.legal,
  PaperSizes.tabloid,
  PaperSizes.executive,
  PageSize(name: 'Custom 100x150', width: 100, height: 150),
];

class PrintPage extends StatefulWidget {
  const PrintPage({super.key});

  @override
  State<PrintPage> createState() => _PrintPageState();
}

class _PrintPageState extends State<PrintPage> {
  // --- file selection
  _FileType _fileType = _FileType.pdf;

  // --- print options
  int _paperSizeIndex = 1; // A4
  int _copies = 1;
  bool _landscape = false;
  bool _color = true;
  DuplexMode? _duplexMode;

  // --- printer
  List<PrinterInfo> _printers = [];
  PrinterInfo? _selectedPrinter;
  bool _loadingPrinters = false;

  // --- status
  bool _busy = false;
  String? _status;
  bool _statusIsError = false;

  // ---------------------------------------------------------------------------

  String get _assetPath => switch (_fileType) {
    _FileType.pdf => 'assets/document.pdf',
    _FileType.image => 'assets/image.jpg',
    _FileType.text => 'assets/text.txt',
  };

  /// On web: creates a blob URL from the bundled asset bytes.
  /// On native: extracts the asset to a temp file and returns its path.
  Future<String> _resolveFilePath() async {
    final bytes = await rootBundle.load(_assetPath);
    final data = bytes.buffer.asUint8List();

    if (kIsWeb) {
      final mime = switch (_fileType) {
        _FileType.pdf => 'application/pdf',
        _FileType.image => 'image/jpeg',
        _FileType.text => 'text/plain',
      };
      return createBlobUrl(data, mime);
    }

    final dir = await getTemporaryDirectory();
    await dir.create(recursive: true);
    final file = File('${dir.path}/${_assetPath.split('/').last}');
    await file.writeAsBytes(data);
    return file.path;
  }

  PrintOptions get _options => PrintOptions(
    printerAddress: _selectedPrinter?.address,
    pageSize: _paperSizes[_paperSizeIndex],
    copies: _copies,
    landscape: _landscape,
    color: _color,
    duplexMode: _duplexMode,
  );

  // ---------------------------------------------------------------------------

  Future<void> _listPrinters() async {
    setState(() => _loadingPrinters = true);
    try {
      final printers = await FlutterPrint.listPrinters();
      setState(() {
        _printers = printers;
        if (printers.isNotEmpty) {
          _selectedPrinter ??= printers.firstWhere(
            (p) => p.isDefault,
            orElse: () => printers.first,
          );
        }
      });
      _show('Found ${printers.length} printer(s)');
    } on PlatformException catch (e) {
      _showError(e.message ?? 'listPrinters failed');
    } finally {
      setState(() => _loadingPrinters = false);
    }
  }

  // iOS only — shows UIPrinterPickerController.
  Future<void> _pickPrinterIOS() async {
    try {
      final printer = await FlutterPrint.ios?.pickPrinter();
      if (printer == null) return; // cancelled
      setState(() {
        if (!_printers.any((p) => p.address == printer.address)) {
          _printers = [printer, ..._printers];
        }
        _selectedPrinter = printer;
      });
      _show('Picked: ${printer.label}');
    } on PlatformException catch (e) {
      _showError(e.message ?? 'pickPrinter failed');
    }
  }

  Future<void> _print({required bool directPrint}) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _status = null;
    });
    try {
      final path = await _resolveFilePath();
      await FlutterPrint.print(
        path,
        options: _options,
        directPrint: directPrint,
      );
      _show(directPrint ? 'Job submitted' : 'Dialog closed');
    } on PlatformException catch (e) {
      _showError(e.message ?? 'print failed');
    } finally {
      setState(() => _busy = false);
    }
  }

  void _show(String msg) => setState(() {
    _status = msg;
    _statusIsError = false;
  });

  void _showError(String msg) => setState(() {
    _status = msg;
    _statusIsError = true;
  });

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('flutter_print example'),
        backgroundColor: cs.inversePrimary,
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // ---- sample file
          SectionCard(
            title: 'Sample file',
            child: RadioGroup<_FileType>(
              groupValue: _fileType,
              onChanged: (v) => setState(() => _fileType = v!),
              child: Row(
                children: [
                  Expanded(
                    child: RadioListTile<_FileType>(
                      title: const Text('PDF'),
                      value: _FileType.pdf,
                      contentPadding: EdgeInsets.zero,
                    ),
                  ),
                  Expanded(
                    child: RadioListTile<_FileType>(
                      title: const Text('Image'),
                      value: _FileType.image,
                      contentPadding: EdgeInsets.zero,
                    ),
                  ),
                  Expanded(
                    child: RadioListTile<_FileType>(
                      title: const Text('Other'),
                      value: _FileType.text,
                      contentPadding: EdgeInsets.zero,
                    ),
                  ),
                ],
              ),
            ),
          ),

          const SizedBox(height: 12),

          // ---- print options
          SectionCard(
            title: 'Print options',
            child: Column(
              children: [
                DropdownButtonFormField<int>(
                  decoration: const InputDecoration(labelText: 'Paper size'),
                  initialValue: _paperSizeIndex,
                  items: List.generate(
                    _paperSizes.length,
                    (i) => DropdownMenuItem(
                      value: i,
                      child: Text(_paperSizes[i].name),
                    ),
                  ),
                  onChanged: (v) => setState(() => _paperSizeIndex = v!),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    const Text('Copies'),
                    const Spacer(),
                    IconButton(
                      icon: const Icon(Icons.remove),
                      onPressed: _copies > 1
                          ? () => setState(() => _copies--)
                          : null,
                    ),
                    SizedBox(
                      width: 32,
                      child: Text(
                        '$_copies',
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.add),
                      onPressed: () => setState(() => _copies++),
                    ),
                  ],
                ),
                SwitchListTile(
                  title: const Text('Landscape'),
                  value: _landscape,
                  onChanged: (v) => setState(() => _landscape = v),
                  contentPadding: EdgeInsets.zero,
                ),
                SwitchListTile(
                  title: const Text('Color'),
                  value: _color,
                  onChanged: (v) => setState(() => _color = v),
                  contentPadding: EdgeInsets.zero,
                ),
                const SizedBox(height: 8),
                DropdownButtonFormField<DuplexMode?>(
                  decoration: const InputDecoration(labelText: 'Duplex'),
                  initialValue: _duplexMode,
                  items: [
                    const DropdownMenuItem(value: null,                  child: Text('Platform default')),
                    DropdownMenuItem(value: DuplexMode.none,       child: const Text('Single-sided')),
                    DropdownMenuItem(value: DuplexMode.longEdge,   child: const Text('Double-sided — long edge')),
                    DropdownMenuItem(value: DuplexMode.shortEdge,  child: const Text('Double-sided — short edge')),
                  ],
                  onChanged: (v) => setState(() => _duplexMode = v),
                ),
              ],
            ),
          ),

          const SizedBox(height: 12),

          // ---- printers
          SectionCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: FilledButton.tonal(
                        onPressed: _loadingPrinters ? null : _listPrinters,
                        child: _loadingPrinters
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Text('List printers'),
                      ),
                    ),
                    if (FlutterPrint.ios != null) ...[
                      const SizedBox(width: 8),
                      Expanded(
                        child: FilledButton.tonal(
                          onPressed: _pickPrinterIOS,
                          child: const Text('Pick printer'),
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<PrinterInfo?>(
                  decoration: const InputDecoration(
                    labelText: 'Target printer',
                  ),
                  initialValue: _selectedPrinter,
                  items: [
                    const DropdownMenuItem(
                      value: null,
                      child: Text('System default'),
                    ),
                    ..._printers.map(
                      (p) => DropdownMenuItem(
                        value: p,
                        child: Text(
                          p.isDefault ? '${p.label} ★' : p.label,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ),
                  ],
                  onChanged: (v) => setState(() => _selectedPrinter = v),
                ),
                if (_selectedPrinter?.capabilities.supportsColor != null ||
                    _selectedPrinter?.capabilities.supportsDuplex != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: CapabilitiesChips(_selectedPrinter!.capabilities),
                  ),
              ],
            ),
          ),

          const SizedBox(height: 12),

          // ---- actions
          SectionCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                FilledButton.icon(
                  onPressed: _busy ? null : () => _print(directPrint: true),
                  icon: const Icon(Icons.print),
                  label: const Text('Print — direct (no dialog)'),
                ),
                const SizedBox(height: 8),
                FilledButton.icon(
                  onPressed: _busy ? null : () => _print(directPrint: false),
                  icon: const Icon(Icons.print_outlined),
                  label: const Text('Print — show native dialog'),
                ),
              ],
            ),
          ),

          // ---- status
          if (_busy)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 16),
              child: Center(child: CircularProgressIndicator()),
            )
          else if (_status != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Text(
                _status!,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: _statusIsError ? cs.error : cs.primary,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
