import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_print_platform_interface/flutter_print_platform_interface.dart';

import '../windows_print_channel.dart';
import 'l10n/print_localizations.dart';
import 'print_dialog_utils.dart';
import 'widgets/print_preview_panel.dart';
import 'widgets/print_settings_panel.dart';

// ---------------------------------------------------------------------------
// Public entry point
// ---------------------------------------------------------------------------

Future<void> showWindowsPrintDialog(
  BuildContext context,
  String filePath,
  PrintOptions? initialOptions,
) async {
  // The in-app dialog can only preview (and apply settings to) PDF, image and
  // text files. For anything else, showing it would present a blank preview and
  // controls that the underlying shell-print path silently ignores. Instead,
  // open the file in its associated application, where the user gets a faithful
  // view and the app's own fully featured print flow.
  final mime = await WindowsPrintChannel.getMimeType(filePath);
  if (!mimeIsPdf(mime) && !mimeIsImage(mime) && !mimeIsText(mime)) {
    await WindowsPrintChannel.openInDefaultApp(filePath);
    return;
  }
  if (!context.mounted) return;

  final locale = Localizations.maybeLocaleOf(context) ?? const Locale('en');

  // Use showGeneralDialog (Flutter core) instead of fluent_ui's showDialog,
  // which asserts FluentLocalizations on the *caller's* context.
  final options = await showGeneralDialog<PrintOptions>(
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
        data: _buildTheme(MediaQuery.platformBrightnessOf(ctx)),
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
              mimeType: mime,
              initialOptions: initialOptions,
            ),
          ),
        ),
      ),
    ),
  );
  if (options == null) return;

  // Print here so errors reach the caller.
  await FlutterPrintApi().print(filePath, options: options);
}

// ComboBox items dim their text to textFillColorSecondary on hover, which
// looks unexpectedly faded. Override it to match primary so hover only
// changes the background, not the text opacity.
FluentThemeData _buildTheme(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  final base = dark ? FluentThemeData.dark() : FluentThemeData.light();
  final text = base.resources.textFillColorPrimary;
  return base.copyWith(
    resources: dark
        ? ResourceDictionary.dark(textFillColorSecondary: text)
        : ResourceDictionary.light(textFillColorSecondary: text),
  );
}

// ---------------------------------------------------------------------------
// Dialog widget
// ---------------------------------------------------------------------------

class _PrintDialog extends StatefulWidget {
  const _PrintDialog({
    required this.filePath,
    required this.mimeType,
    this.initialOptions,
  });

  final String filePath;
  final String mimeType;
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

  // Page count, loaded once for both panels. Null while loading, 0 when
  // unknown (text files are paged at print time).
  int? _pageCount;

  @override
  void initState() {
    super.initState();
    _options = widget.initialOptions ?? PrintOptions();
    _pagesValid = _options.pageRanges?.isEmpty ?? true;
    if (mimeIsPdf(widget.mimeType)) {
      _loadPageCount();
    } else {
      _pageCount = mimeIsImage(widget.mimeType) ? 1 : 0;
    }
  }

  Future<void> _loadPageCount() async {
    var count = 0;
    try {
      count = await WindowsPrintChannel.getPdfPageCount(widget.filePath);
    } catch (_) {
      // Show the preview as unavailable.
    }
    if (mounted) setState(() => _pageCount = count);
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
                pageCount: _pageCount,
                initialOptions: _options,
                onOptionsChanged: (opts) => setState(() => _options = opts),
                onPagesValidChanged: (valid) =>
                    setState(() => _pagesValid = valid),
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
                mimeType: widget.mimeType,
                pageCount: _pageCount,
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
          onPressed:
              (!_printing && _pagesValid && _options.printerAddress != null)
              ? _print
              : null,
          child: Text(l10n.print),
        ),
      ],
    );
  }

  void _print() {
    if (_printing) return;
    _printing = true;
    Navigator.of(context, rootNavigator: true).pop(_options);
  }
}
