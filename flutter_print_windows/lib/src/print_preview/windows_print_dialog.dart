import 'package:flutter/widgets.dart';
import 'package:flutter_print_platform_interface/flutter_print_platform_interface.dart';

import '../windows_print_channel.dart';
import '../windows_ui/windows_ui.dart';
import 'l10n/print_localizations.dart';
import 'print_dialog_utils.dart';
import 'widgets/print_preview_panel.dart';
import 'widgets/print_settings_panel.dart';

/// Shows the print dialog, then prints [filePath] with the chosen options.
Future<void> showWindowsPrintDialog(
  BuildContext context,
  String filePath,
  PrintOptions? initialOptions,
) async {
  // Open the files the plugin can't print in their default app, which has its
  // own print flow.
  final (kind, accentShades) = await (
    WindowsPrintChannel.getFileKind(filePath),
    WindowsPrintChannel.getAccentColors().catchError((Object _) => null),
  ).wait;
  if (kind == FileKind.other) {
    await WindowsPrintChannel.openInDefaultApp(filePath);
    return;
  }
  if (!context.mounted) return;
  final accent = AccentPalette.fromShades(accentShades);

  final options = await showGeneralDialog<PrintOptions>(
    context: context,
    barrierDismissible: false,
    barrierLabel: 'Print',
    barrierColor: const Color(0x52000000),
    transitionDuration: const Duration(milliseconds: 150),
    // Fade in while shrinking to size, as WinUI dialogs.
    transitionBuilder: (_, animation, _, child) {
      final curved = CurvedAnimation(parent: animation, curve: Curves.easeOut);
      return FadeTransition(
        opacity: curved,
        child: ScaleTransition(
          scale: Tween(begin: 1.05, end: 1.0).animate(curved),
          child: child,
        ),
      );
    },
    pageBuilder: (ctx, _, _) {
      final theme = WinThemeData(
        brightness: MediaQuery.platformBrightnessOf(ctx),
        accent: accent,
      );
      return Localizations.override(
        context: ctx,
        delegates: const [PrintLocalizations.delegate],
        child: WinTheme(
          data: theme,
          child: ScrollConfiguration(
            behavior: WinScrollBehavior(theme.colors),
            child: _PrintDialog(
              filePath: filePath,
              kind: kind,
              initialOptions: initialOptions,
            ),
          ),
        ),
      );
    },
  );
  if (options == null) return;

  // Print here so errors reach the caller.
  await FlutterPrintApi().print(filePath, options: options);
}

class _PrintDialog extends StatefulWidget {
  const _PrintDialog({
    required this.filePath,
    required this.kind,
    this.initialOptions,
  });

  final String filePath;
  final FileKind kind;
  final PrintOptions? initialOptions;

  @override
  State<_PrintDialog> createState() => _PrintDialogState();
}

class _PrintDialogState extends State<_PrintDialog> {
  late PrintOptions _options;

  // Guard against a double pop on a double click.
  bool _printing = false;

  // A preset range stays invalid until the page count confirms it.
  late bool _pagesValid;

  // The file laid out for the current printer and paper, kept open for fast
  // page turns. Null while opening or when it can't be previewed.
  PreviewSession? _preview;

  // Page count for both panels: text pages depend on the layout. Null while
  // loading, 0 when unknown.
  int? _pageCount;

  // Drop previews that open after a newer request.
  int _previewRequest = 0;

  @override
  void initState() {
    super.initState();
    _options = widget.initialOptions ?? PrintOptions();
    _pagesValid = _options.pageRanges?.isEmpty ?? true;
  }

  @override
  void dispose() {
    final preview = _preview;
    if (preview != null) WindowsPrintChannel.closePreview(preview.id);
    super.dispose();
  }

  // Keeps the old preview until the new one is open, so the panels don't
  // flash.
  Future<void> _openPreview() async {
    final request = ++_previewRequest;
    PreviewSession? preview;
    try {
      preview = await WindowsPrintChannel.openPreview(
        widget.filePath,
        widget.kind,
        _options,
      );
    } catch (_) {
      // Show the preview as unavailable.
    }
    if (!mounted || request != _previewRequest) {
      if (preview != null) WindowsPrintChannel.closePreview(preview.id);
      return;
    }
    final old = _preview;
    setState(() {
      _preview = preview;
      _pageCount = preview?.pageCount ?? 0;
    });
    if (old != null) WindowsPrintChannel.closePreview(old.id);
  }

  void _onOptionsChanged(PrintOptions options) {
    // Lay out on the first options, which name the printer and its paper.
    final relayout = _previewRequest == 0 || !sameLayout(options, _options);
    setState(() => _options = options);
    if (relayout) _openPreview();
  }

  @override
  Widget build(BuildContext context) {
    final colors = WinTheme.of(context).colors;
    final l10n = PrintLocalizations.of(context);
    final size = MediaQuery.sizeOf(context);
    final maxW = (size.width * 0.9).clamp(480.0, 1024.0);
    final maxH = (size.height * 0.85).clamp(480.0, 900.0);
    final contentH = (maxH - 174).clamp(280.0, double.infinity);

    // Escape cancels, as in WinUI dialogs.
    return Actions(
      actions: {
        DismissIntent: CallbackAction<DismissIntent>(
          onInvoke: (_) => _cancel(),
        ),
      },
      child: FocusScope(
        autofocus: true,
        child: _buildDialog(l10n, colors, maxW, maxH, contentH),
      ),
    );
  }

  Widget _buildDialog(
    PrintLocalizations l10n,
    WinColors colors,
    double maxW,
    double maxH,
    double contentH,
  ) {
    return WinDialog(
      constraints: BoxConstraints(maxWidth: maxW, maxHeight: maxH),
      title: Text(l10n.title),
      content: SizedBox(
        height: contentH,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              width: 260,
              child: PrintSettingsPanel(
                pageCount: _pageCount,
                initialOptions: _options,
                onOptionsChanged: _onOptionsChanged,
                onPagesValidChanged: (valid) =>
                    setState(() => _pagesValid = valid),
              ),
            ),
            const SizedBox(width: 16),
            Container(width: 1, color: colors.divider),
            const SizedBox(width: 16),
            Expanded(
              child: PrintPreviewPanel(
                preview: _preview,
                pageCount: _pageCount,
                options: _options,
              ),
            ),
          ],
        ),
      ),
      actions: [
        WinButton(
          onPressed: _printing ? null : _cancel,
          child: Text(l10n.cancel),
        ),
        WinButton(
          accent: true,
          onPressed:
              (!_printing && _pagesValid && _options.printerAddress != null)
              ? _print
              : null,
          child: Text(l10n.print),
        ),
      ],
    );
  }

  void _cancel() {
    if (!_printing) Navigator.of(context).pop();
  }

  void _print() {
    if (_printing) return;
    _printing = true;
    Navigator.of(context).pop(_options);
  }
}
