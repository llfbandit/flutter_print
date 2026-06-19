import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_print_platform_interface/flutter_print_platform_interface.dart';
import 'package:flutter_web_plugins/flutter_web_plugins.dart';
import 'package:web/web.dart' as web;

class FlutterPrintWeb extends FlutterPrintPlatform {
  FlutterPrintWeb();

  static void registerWith(Registrar registrar) {
    FlutterPrintPlatform.instance = FlutterPrintWeb();
  }

  static const _frameId = '__flutter_print__';
  static const _printFnId = '__flutter_print_invoke__';

  static Timer? _cleanupTimer;

  /// Loads [filePath] into a hidden `<iframe>` and triggers the browser's
  /// native print dialog via an injected JS helper.
  ///
  /// **Limitations**
  /// - [filePath] must be a URL (`https://…`, a blob URL, or a data URL).
  /// - [PrintOptions] fields are ignored — the browser does not expose a
  ///   programmatic API for page size, margins, copies, or printer selection.
  @override
  Future<void> print(String filePath, {PrintOptions? options}) =>
      _printUrl(filePath);

  /// Identical to [print] on web: the browser's print dialog is the preview.
  @override
  Future<void> printPreview(
    String filePath, {
    PrintOptions? options,
    required BuildContext context,
  }) => _printUrl(filePath);

  /// Always returns an empty list — the browser does not expose a
  /// printer-enumeration API.
  @override
  Future<List<PrinterInfo>> listPrinters() async => const [];

  /// Always returns `null` — no printer picker is available in the browser.
  @override
  Future<PrinterInfo?> pickPrinter() async => null;

  // ---------------------------------------------------------------------------

  Future<void> _printUrl(String url) async {
    final isBlobUrl = url.startsWith('blob:');
    final browser = _detectBrowser();

    // Mobile and unsupported browsers cannot use contentWindow.print(); open
    // the document in a new tab and let the user print from there instead.
    if (!browser.canPrint) {
      web.window.open(url, '_blank');
      if (isBlobUrl) web.URL.revokeObjectURL(url);
      return;
    }

    final mimeType = await _detectMimeType(url, isBlobUrl);
    // Raw image types need an HTML wrapper so the iframe has a printable
    // document. All other types (PDF, HTML, SVG, text, …) load directly.
    final contentUrl = mimeType.startsWith('image/') ? _wrapImageUrl(url) : url;

    final (script, frame) = _setupDom(isFirefox: browser.isFirefox);

    Duration elapsed = Duration.zero;
    try {
      elapsed = await _invokePrint(
        frame,
        contentUrl,
        isSafari: browser.isSafari,
      );
    } on PlatformException {
      rethrow;
    } catch (e) {
      throw PlatformException(code: 'PRINT_ERROR', message: '$e');
    } finally {
      _cleanup(
        frame: frame,
        script: script,
        contentUrl: contentUrl,
        originalUrl: url,
        isBlobUrl: isBlobUrl,
        elapsed: elapsed,
      );
    }
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  /// Parses the user-agent string and returns browser capabilities.
  static ({bool isSafari, bool isFirefox, bool canPrint}) _detectBrowser() {
    final ua = web.window.navigator.userAgent;
    final isChrome = ua.contains('Chrome');
    final isSafari = ua.contains('Safari') && !isChrome;
    final isFirefox = ua.contains('Firefox');
    final isMobile = ua.contains('Mobile');

    return (
      isSafari: isSafari,
      isFirefox: isFirefox,
      canPrint: !isMobile && (isChrome || isSafari || isFirefox),
    );
  }

  /// Injects the JS print helper script and creates (or reuses) the hidden
  /// iframe. The frame's `src` is NOT set here — [_invokePrint] does that
  /// after registering the load listener, avoiding a race condition.
  static (web.Element script, web.HTMLIFrameElement frame) _setupDom({
    required bool isFirefox,
  }) {
    // Cancel any pending cleanup from a previous call before reusing the frame.
    _cleanupTimer?.cancel();
    _cleanupTimer = null;

    final doc = web.document;

    // Inject once; reuse on subsequent calls.
    final script =
        doc.getElementById('${_printFnId}_script') ??
        doc.createElement('script');
    script.id = '${_printFnId}_script';
    script.setAttribute('type', 'text/javascript');
    // Calling print() through a global JS function (via window.callMethod)
    // keeps the call in the browser's JS event loop, which is required for
    // the print dialog to open reliably.
    script.innerHTML =
        'function $_printFnId(){'
                'var f=document.getElementById("$_frameId");'
                'f.focus();f.contentWindow.print();'
                '}'
            .toJS;
    doc.body!.append(script);

    final frame =
        (doc.getElementById(_frameId) ?? doc.createElement('iframe'))
            as web.HTMLIFrameElement;
    frame.id = _frameId;
    // Firefox requires a visible (but transparent) element with real height;
    // other browsers work with a zero-size hidden element.
    frame.setAttribute(
      'style',
      isFirefox
          ? 'width:1px;height:100px;position:fixed;left:0;top:0;'
                'opacity:0;border:0;margin:0;padding:0'
          : 'visibility:hidden;height:0;width:0;position:absolute',
    );

    return (script, frame);
  }

  /// Registers the load listener, then sets `frame.src` and appends to the
  /// DOM (listener-before-src prevents a race if the resource loads instantly).
  /// Returns the time spent inside `window.print()` — zero if the dialog was
  /// blocked, otherwise the duration the user kept the dialog open.
  static Future<Duration> _invokePrint(
    web.HTMLIFrameElement frame,
    String contentUrl, {
    required bool isSafari,
  }) {
    final completer = Completer<Duration>();
    final stopwatch = Stopwatch();

    web.EventListener? onLoad;
    onLoad = (web.Event _) {
      frame.removeEventListener('load', onLoad);
      // Safari needs a short delay for its PDF viewer to become ready.
      Timer(Duration(milliseconds: isSafari ? 500 : 0), () {
        try {
          stopwatch.start();
          web.window.callMethod<JSAny?>(_printFnId.toJS);
          stopwatch.stop();
          completer.complete(stopwatch.elapsed);
        } catch (e) {
          completer.completeError(
            PlatformException(
              code: 'PRINT_ERROR',
              message: 'Failed to print: $e',
            ),
          );
        }
      });
    }.toJS;

    frame.addEventListener('load', onLoad);
    frame.src = contentUrl;
    web.document.body!.append(frame);

    return completer.future;
  }

  /// Removes DOM elements and revokes blob URLs.
  /// `window.print()` is synchronous — if [elapsed] > 1 s the dialog was
  /// shown and closed; clean up immediately. Otherwise schedule cleanup so we
  /// don't destroy the frame while a slow dialog is still initialising.
  static void _cleanup({
    required web.HTMLIFrameElement frame,
    required web.Element script,
    required String contentUrl,
    required String originalUrl,
    required bool isBlobUrl,
    required Duration elapsed,
  }) {
    void remove() {
      frame.remove();
      script.remove();
    }

    if (elapsed.inMilliseconds > 1000) {
      remove();
    } else {
      _cleanupTimer = Timer(const Duration(minutes: 1), remove);
    }

    if (contentUrl != originalUrl) web.URL.revokeObjectURL(contentUrl);
    if (isBlobUrl) web.URL.revokeObjectURL(originalUrl);
  }

  // ---------------------------------------------------------------------------
  // Content helpers
  // ---------------------------------------------------------------------------

  /// Returns the MIME type of [url].
  /// Blob URLs are fetched (memory-only, no network round-trip) to read the
  /// real Content-Type set when the blob was created.
  /// Regular URLs are classified by file extension; unknown types return `''`.
  static Future<String> _detectMimeType(String url, bool isBlobUrl) async {
    if (isBlobUrl) {
      final resp = await web.window.fetch(url.toJS).toDart;
      return resp.headers.get('content-type') ?? '';
    }
    final path = url.split('?').first.toLowerCase();
    if (path.endsWith('.pdf')) return 'application/pdf';
    if (path.endsWith('.png')) return 'image/png';
    if (path.endsWith('.jpg') || path.endsWith('.jpeg')) return 'image/jpeg';
    if (path.endsWith('.gif')) return 'image/gif';
    if (path.endsWith('.webp')) return 'image/webp';
    if (path.endsWith('.svg')) return 'image/svg+xml';
    if (path.endsWith('.html') || path.endsWith('.htm')) return 'text/html';
    if (path.endsWith('.txt')) return 'text/plain';
    return ''; // unknown — load directly and let the browser decide
  }

  /// Wraps an image URL in a minimal HTML blob so it renders as a printable
  /// document inside the iframe.
  static String _wrapImageUrl(String imageUrl) {
    final html =
        '<!DOCTYPE html><html>'
        '<head><style>'
        '@page{margin:0}'
        'html,body{margin:0;padding:0;width:100%;height:100%;'
        'display:flex;align-items:center;justify-content:center}'
        'img{max-width:100%;max-height:100%;object-fit:contain}'
        '</style></head>'
        '<body><img src="$imageUrl"></body>'
        '</html>';
    final blob = web.Blob(
      [html.toJS].toJS,
      web.BlobPropertyBag(type: 'text/html'),
    );
    return web.URL.createObjectURL(blob);
  }
}
