import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import 'messages.g.dart';

/// Points per millimetre (72 pt/inch ÷ 25.4 mm/inch).
const double _ptsPerMm = 72.0 / 25.4;

/// Renders the widget returned by [builder] off-screen and returns a minimal
/// single-page PDF.
///
/// [builder] receives the caller's [BuildContext], giving access to inherited
/// widgets such as [Theme] and [Localizations]. The renderer automatically
/// wraps the result with a page-sized [MediaQuery] (inheriting all other fields
/// from [context]) and the [Directionality] of [context].
///
/// The widget is laid out with **tight** constraints equal to the printable
/// area. Widgets that use [LayoutBuilder] receive these as both min and max,
/// so [BoxConstraints.maxWidth] and [BoxConstraints.maxHeight] always reflect
/// the page dimensions. The renderer centres the captured image on the page,
/// so a widget that constrains itself to a smaller size (via [SizedBox] inside
/// a [LayoutBuilder]) will be centred automatically.
///
/// The printable area is derived from [pageSize] and [margins]:
///   `printableWidth  = pageSize.width  - margins.left - margins.right`
///   `printableHeight = pageSize.height - margins.top  - margins.bottom`
///
/// Layout uses 72 logical pixels per inch (1 lp = 1 pt). The capture pixel
/// ratio is `dpi / 72`, producing exactly [dpi] dots per inch at physical size.
Future<Uint8List> renderWidgetToPdf({
  required WidgetBuilder builder,
  required BuildContext context,
  required double dpi,
  PageSize? pageSize,
  PageSize? contentSize,
  PageMargins? margins,
}) async {
  final s = _computeSetup(
    dpi: dpi,
    pageSize: pageSize,
    contentSize: contentSize,
    margins: margins,
  );

  final image = await _renderViaOverlay(
    _wrapWidget(builder, context, s.logicalSize, s.pixelRatio),
    context,
    s.logicalSize,
    s.pixelRatio,
  );

  final rgbBytes = await _toRgbBytes(image);
  final imageWidth = image.width;
  final imageHeight = image.height;
  image.dispose();

  return _buildPdf(
    imageWidth: imageWidth,
    imageHeight: imageHeight,
    rgbBytes: rgbBytes,
    pageWidthPts: s.pageWidthPts,
    pageHeightPts: s.pageHeightPts,
    imageWidthPts: s.logicalSize.width,
    imageHeightPts: s.logicalSize.height,
    printWidthPts: s.printWidthPts,
    printHeightPts: s.printHeightPts,
    marginLeftPts: s.marginLeftPts,
    marginBottomPts: s.marginBottomPts,
  );
}

/// Renders the widget returned by [builder] off-screen and returns the result
/// as PNG image bytes, suitable for display with [Image.memory].
///
/// Parameters mirror [renderWidgetToPdf]: [contentSize] sets the widget's
/// layout dimensions (defaults to [pageSize] printable area when omitted),
/// and [dpi] controls pixel density (72 = one logical pixel per point,
/// appropriate for on-screen previews; use higher values for crisp output on
/// high-density displays).
Future<Uint8List> renderWidgetToImage({
  required WidgetBuilder builder,
  required BuildContext context,
  double dpi = 72,
  PageSize? pageSize,
  PageSize? contentSize,
  PageMargins? margins,
}) async {
  final s = _computeSetup(
    dpi: dpi,
    pageSize: pageSize,
    contentSize: contentSize,
    margins: margins,
  );

  final image = await _renderViaOverlay(
    _wrapWidget(builder, context, s.logicalSize, s.pixelRatio),
    context,
    s.logicalSize,
    s.pixelRatio,
  );

  final pngData = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  return pngData!.buffer.asUint8List();
}

// Shared dimension setup for all render functions.
typedef _Setup = ({
  Size logicalSize,
  double pixelRatio,
  double pageWidthPts,
  double pageHeightPts,
  double printWidthPts,
  double printHeightPts,
  double marginLeftPts,
  double marginBottomPts,
});

_Setup _computeSetup({
  required double dpi,
  PageSize? pageSize,
  PageSize? contentSize,
  PageMargins? margins,
}) {
  final double pageWidthMm = pageSize?.width ?? 210.0; // A4 fallback
  final double pageHeightMm = pageSize?.height ?? 297.0;
  final double marginLeftMm = margins?.left ?? 0.0;
  final double marginRightMm = margins?.right ?? 0.0;
  final double marginTopMm = margins?.top ?? 0.0;
  final double marginBottomMm = margins?.bottom ?? 0.0;

  // Printable area on the page (used for centering the content image in PDF).
  final double printWidthMm = pageWidthMm - marginLeftMm - marginRightMm;
  final double printHeightMm = pageHeightMm - marginTopMm - marginBottomMm;

  // Content area: if contentSize is given the widget renders at that size and
  // is centred within the printable area; otherwise it fills the printable area.
  final double contentWidthMm = contentSize?.width ?? printWidthMm;
  final double contentHeightMm = contentSize?.height ?? printHeightMm;

  return (
    logicalSize: Size(contentWidthMm * _ptsPerMm, contentHeightMm * _ptsPerMm),
    pixelRatio: dpi / 72.0,
    pageWidthPts: pageWidthMm * _ptsPerMm,
    pageHeightPts: pageHeightMm * _ptsPerMm,
    printWidthPts: printWidthMm * _ptsPerMm,
    printHeightPts: printHeightMm * _ptsPerMm,
    marginLeftPts: marginLeftMm * _ptsPerMm,
    marginBottomPts: marginBottomMm * _ptsPerMm,
  );
}

// Wraps [builder] in a content-sized MediaQuery and the caller's Directionality.
Widget _wrapWidget(
  WidgetBuilder builder,
  BuildContext context,
  Size logicalSize,
  double pixelRatio,
) => MediaQuery(
  data: MediaQuery.of(
    context,
  ).copyWith(size: logicalSize, devicePixelRatio: pixelRatio),
  child: Directionality(
    textDirection: Directionality.of(context),
    child: builder(context),
  ),
);

// ---------------------------------------------------------------------------
// Overlay-based render capture
// ---------------------------------------------------------------------------

// Renders [widget] by inserting it into the app's Overlay off-screen via
// Transform.translate, waiting for the Flutter pipeline to lay out and
// paint it, then capturing via RepaintBoundary.toImage().
//
// Why Transform.translate instead of a negative Positioned offset:
// _compositeChild sets childOffsetLayer.offset to the paint-time offset passed
// by the parent. OffsetLayer.toImage() compensates with
// `(-offset.dx) * pixelRatio`, but addToScene then pushes `offset.dx` in
// physical pixels — at print pixelRatio (300/72 ≈ 4.17) these don't cancel,
// shifting all content outside the image bounds → blank.
//
// Transform.translate is different: it creates a TransformLayer that wraps the
// RepaintBoundary. Inside that layer, the RepaintBoundary's OffsetLayer gets
// offset = Offset.zero (its local position within the TransformLayer).
// toImage() composites from the OffsetLayer alone, skipping the TransformLayer,
// so the content is always at (0,0) in the output image regardless of pixelRatio.
Future<ui.Image> _renderViaOverlay(
  Widget widget,
  BuildContext context,
  Size logicalSize,
  double pixelRatio,
) async {
  final repaintKey = GlobalKey();

  final entry = OverlayEntry(
    builder: (_) => Positioned(
      left: 0,
      top: 0,
      width: logicalSize.width,
      height: logicalSize.height,
      child: IgnorePointer(
        child: Opacity(
          opacity: 0.005,
          child: RepaintBoundary(key: repaintKey, child: widget),
        ),
      ),
    ),
  );

  Overlay.of(context).insert(entry);

  // First frame: build + layout + initial paint.
  // Second frame: picks up async image decodes that completed after frame 1.
  await WidgetsBinding.instance.endOfFrame;
  await WidgetsBinding.instance.endOfFrame;

  final boundary =
      repaintKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  final image = await boundary.toImage(pixelRatio: pixelRatio);

  entry.remove();
  return image;
}

// ---------------------------------------------------------------------------
// RGBA → RGB strip
// ---------------------------------------------------------------------------

Future<Uint8List> _toRgbBytes(ui.Image image) async {
  final byteData = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  if (byteData == null) throw StateError('Failed to read image pixels');

  final rgba = byteData.buffer.asUint8List();
  final rgb = Uint8List(image.width * image.height * 3);
  for (int i = 0, j = 0; i < rgba.length; i += 4, j += 3) {
    // rawRgba uses premultiplied alpha. Composite over white:
    //   out = premul_rgb + 255 * (1 - a/255)  =  premul_rgb + 255 - a
    final int a = rgba[i + 3];
    rgb[j] = (rgba[i] + 255 - a).clamp(0, 255);
    rgb[j + 1] = (rgba[i + 1] + 255 - a).clamp(0, 255);
    rgb[j + 2] = (rgba[i + 2] + 255 - a).clamp(0, 255);
  }
  return rgb;
}

// ---------------------------------------------------------------------------
// Minimal single-page PDF writer
// ---------------------------------------------------------------------------

Uint8List _buildPdf({
  required int imageWidth,
  required int imageHeight,
  required Uint8List rgbBytes,
  required double pageWidthPts,
  required double pageHeightPts,
  required double imageWidthPts,
  required double imageHeightPts,
  required double printWidthPts,
  required double printHeightPts,
  required double marginLeftPts,
  required double marginBottomPts,
}) {
  final buf = BytesBuilder(copy: false);

  // Append a Latin-1 string as raw bytes (all chars are in 0x00–0xFF range).
  void w(String s) => buf.add(s.codeUnits);

  // Track byte offsets for the xref table.
  final offsets = <int>[];

  String pts(double v) => v.toStringAsFixed(4);

  // Header — the 4 high-bit bytes signal binary content to PDF tools.
  w('%PDF-1.4\n');
  w('%\xE2\xE3\xCF\xD3\n');

  // obj 1: Catalog
  offsets.add(buf.length);
  w('1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n');

  // obj 2: Pages
  offsets.add(buf.length);
  w('2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n');

  // obj 3: Page
  offsets.add(buf.length);
  w('3 0 obj\n');
  w('<< /Type /Page /Parent 2 0 R\n');
  w('   /MediaBox [0 0 ${pts(pageWidthPts)} ${pts(pageHeightPts)}]\n');
  w('   /Resources << /XObject << /Im0 4 0 R >> >>\n');
  w('   /Contents 5 0 R\n');
  w('>>\nendobj\n');

  // obj 4: Image XObject (uncompressed DeviceRGB).
  // Length counts only the raw pixel bytes; the \n before endstream is the
  // required EOL marker and is excluded per the PDF spec (§3.2.7).
  offsets.add(buf.length);
  w('4 0 obj\n');
  w('<< /Type /XObject /Subtype /Image\n');
  w('   /Width $imageWidth /Height $imageHeight\n');
  w('   /ColorSpace /DeviceRGB /BitsPerComponent 8\n');
  w('   /Length ${rgbBytes.length}\n');
  w('>>\nstream\n');
  buf.add(rgbBytes);
  w('\nendstream\nendobj\n');

  // obj 5: Page content stream.
  // Centre the image within the printable area. PDF origin is bottom-left.
  final double x = marginLeftPts + (printWidthPts - imageWidthPts) / 2;
  final double y = marginBottomPts + (printHeightPts - imageHeightPts) / 2;
  final cs =
      'q ${pts(imageWidthPts)} 0 0 ${pts(imageHeightPts)} '
      '${pts(x)} ${pts(y)} cm /Im0 Do Q';
  offsets.add(buf.length);
  w('5 0 obj\n<< /Length ${cs.length} >>\nstream\n');
  w(cs);
  w('\nendstream\nendobj\n');

  // Cross-reference table — each entry is exactly 20 bytes.
  final xrefOffset = buf.length;
  w('xref\n0 ${offsets.length + 1}\n');
  w('0000000000 65535 f \n'); // free-object sentinel
  for (final off in offsets) {
    w('${off.toString().padLeft(10, '0')} 00000 n \n');
  }

  w('trailer\n<< /Size ${offsets.length + 1} /Root 1 0 R >>\n');
  w('startxref\n$xrefOffset\n%%EOF\n');

  return buf.toBytes();
}
