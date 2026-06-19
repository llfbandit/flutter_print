import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_print_platform_interface/flutter_print_platform_interface.dart';

import 'l10n/print_localizations.dart';
import 'widgets/print_preview_panel.dart';
import 'widgets/print_settings_panel.dart';

// ---------------------------------------------------------------------------
// Public entry point
// ---------------------------------------------------------------------------

Future<void> showWindowsPrintDialog(
  BuildContext context,
  String filePath,
  PrintOptions? initialOptions,
) {
  final locale = Localizations.maybeLocaleOf(context) ?? const Locale('en');

  // Use showGeneralDialog (Flutter core) instead of fluent_ui's showDialog,
  // which asserts FluentLocalizations on the *caller's* context.
  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: false,
    barrierLabel: 'Print',
    barrierColor: const Color(0x52000000),
    transitionDuration: const Duration(milliseconds: 150),
    transitionBuilder: (_, animation, _, child) =>
        FadeTransition(opacity: animation, child: child),
    pageBuilder: (ctx, _, _) => Localizations(
      locale: locale,
      delegates: [
        ...FluentLocalizations.localizationsDelegates,
        PrintLocalizations.delegate,
      ],
      child: FluentTheme(
        data: MediaQuery.platformBrightnessOf(ctx) == Brightness.dark
            ? FluentThemeData.dark()
            : FluentThemeData.light(),
        // Nested Navigator so ComboBox (rootNavigator:false) pushes its popup
        // route into this sub-tree, where FluentLocalizations is available.
        // Dialog close always uses rootNavigator:true to pop the outer route.
        child: Navigator(
          onGenerateRoute: (_) => PageRouteBuilder<void>(
            opaque: false,
            transitionDuration: Duration.zero,
            reverseTransitionDuration: Duration.zero,
            pageBuilder: (_, _, _) => _PrintDialog(
              filePath: filePath,
              initialOptions: initialOptions,
            ),
          ),
        ),
      ),
    ),
  );
}

// ---------------------------------------------------------------------------
// Dialog widget
// ---------------------------------------------------------------------------

class _PrintDialog extends StatefulWidget {
  const _PrintDialog({required this.filePath, this.initialOptions});

  final String filePath;
  final PrintOptions? initialOptions;

  @override
  State<_PrintDialog> createState() => _PrintDialogState();
}

class _PrintDialogState extends State<_PrintDialog> {
  final _api = FlutterPrintApi();

  late PrintOptions _options;
  bool _printing = false;

  @override
  void initState() {
    super.initState();
    _options = widget.initialOptions ?? PrintOptions();
  }

  @override
  Widget build(BuildContext context) {
    final theme = FluentTheme.of(context);
    final l10n = PrintLocalizations.of(context);
    final size = MediaQuery.sizeOf(context);
    final maxW = (size.width * 0.9).clamp(480.0, 1024.0);
    final maxH = (size.height * 0.85).clamp(480.0, 900.0);
    final contentH = (maxH - 174).clamp(280.0, double.infinity);

    return ContentDialog(
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
                initialOptions: _options,
                onOptionsChanged: (opts) => setState(() => _options = opts),
              ),
            ),
            const SizedBox(width: 16),
            Container(
              width: 1,
              color: theme.resources.dividerStrokeColorDefault,
            ),
            const SizedBox(width: 16),
            Expanded(
              child: PrintPreviewPanel(
                filePath: widget.filePath,
                options: _options,
              ),
            ),
          ],
        ),
      ),
      actions: [
        Button(
          onPressed: _printing
              ? null
              : () => Navigator.of(context, rootNavigator: true).pop(),
          child: Text(l10n.cancel),
        ),
        FilledButton(
          onPressed: (!_printing && _options.printerAddress != null)
              ? _print
              : null,
          child: Text(l10n.print),
        ),
      ],
    );
  }

  Future<void> _print() async {
    if (_options.printerAddress == null) return;
    setState(() => _printing = true);
    if (mounted) Navigator.of(context, rootNavigator: true).pop();
    try {
      await _api.print(widget.filePath, options: _options);
    } catch (_) {
      // Ignored.
    }
  }
}
