package com.llfbandit.flutter_print;

import android.app.Activity;
import android.content.Context;
import android.os.Bundle;
import android.os.CancellationSignal;
import android.os.ParcelFileDescriptor;
import android.print.PageRange;
import android.print.PrintAttributes;
import android.print.PrintDocumentAdapter;
import android.print.PrintDocumentInfo;
import android.print.PrintManager;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;

import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.util.ArrayList;
import java.util.List;

import io.flutter.embedding.engine.plugins.FlutterPlugin;
import io.flutter.embedding.engine.plugins.activity.ActivityAware;
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding;

public class FlutterPrintPlugin
    implements FlutterPlugin, ActivityAware, Messages.FlutterPrintApi {

  @Nullable
  private Activity activity;

  // -------------------------------------------------------------------------
  // FlutterPlugin
  // -------------------------------------------------------------------------

  @Override
  public void onAttachedToEngine(@NonNull FlutterPluginBinding binding) {
    Messages.FlutterPrintApi.setUp(binding.getBinaryMessenger(), this);
  }

  @Override
  public void onDetachedFromEngine(@NonNull FlutterPluginBinding binding) {
    Messages.FlutterPrintApi.setUp(binding.getBinaryMessenger(), null);
  }

  // -------------------------------------------------------------------------
  // ActivityAware
  // -------------------------------------------------------------------------

  @Override
  public void onAttachedToActivity(@NonNull ActivityPluginBinding binding) {
    activity = binding.getActivity();
  }

  @Override
  public void onDetachedFromActivityForConfigChanges() {
    activity = null;
  }

  @Override
  public void onReattachedToActivityForConfigChanges(@NonNull ActivityPluginBinding binding) {
    activity = binding.getActivity();
  }

  @Override
  public void onDetachedFromActivity() {
    activity = null;
  }

  // -------------------------------------------------------------------------
  // Messages.FlutterPrintApi
  // -------------------------------------------------------------------------

  @Override
  public void print(@NonNull String filePath, @NonNull Messages.PrintOptions options) {
    handlePrint(filePath, options);
  }

  @Override
  public void printPreview(@NonNull String filePath, @NonNull Messages.PrintOptions options) {
    // Android's PrintManager always shows a dialog with a preview.
    handlePrint(filePath, options);
  }

  @Override
  public void listPrinters(@NonNull Messages.Result<List<Messages.PrinterInfo>> result) {
    // Android does not expose a public API for enumerating printers.
    result.success(new ArrayList<>());
  }

  @Override
  public void pickPrinter(@NonNull Messages.NullableResult<Messages.PrinterInfo> result) {
    // No printer picker available on Android.
    result.success(null);
  }

  // -------------------------------------------------------------------------
  // Private helpers
  // -------------------------------------------------------------------------

  private void handlePrint(@NonNull String filePath, @NonNull Messages.PrintOptions options) {
    if (activity == null) {
      throw new Messages.FlutterError("NO_ACTIVITY", "Printing requires an active Activity", null);
    }

    File file = new File(filePath);
    if (!file.exists()) {
      throw new Messages.FlutterError("FILE_NOT_FOUND", "File not found: " + filePath, null);
    }

    PrintAttributes.Builder attrBuilder = new PrintAttributes.Builder();

    Boolean landscape = options.getLandscape();
    Messages.PageSize pageSize = options.getPageSize();

    if (pageSize != null) {
      PrintAttributes.MediaSize mediaSize = resolveMediaSize(pageSize);
      if (mediaSize != null) {
        attrBuilder.setMediaSize(
            landscape ? mediaSize.asLandscape() : mediaSize.asPortrait());
      } else if (landscape) {
        attrBuilder.setMediaSize(PrintAttributes.MediaSize.UNKNOWN_LANDSCAPE);
      }
    } else if (landscape) {
      attrBuilder.setMediaSize(PrintAttributes.MediaSize.UNKNOWN_LANDSCAPE);
    }

    Boolean color = options.getColor();
    attrBuilder.setColorMode(
        color ? PrintAttributes.COLOR_MODE_COLOR : PrintAttributes.COLOR_MODE_MONOCHROME);

    Messages.DuplexMode duplexMode = options.getDuplexMode();
    if (duplexMode != null) {
      switch (duplexMode) {
        case NONE:       attrBuilder.setDuplexMode(PrintAttributes.DUPLEX_MODE_NONE);       break;
        case LONG_EDGE:  attrBuilder.setDuplexMode(PrintAttributes.DUPLEX_MODE_LONG_EDGE);  break;
        case SHORT_EDGE: attrBuilder.setDuplexMode(PrintAttributes.DUPLEX_MODE_SHORT_EDGE); break;
      }
    }

    Messages.PageMargins margins = options.getMargins();
    if (margins != null) {
      // Android uses mils (1/1000 inch). 1 mm ≈ 39.37 mils.
      attrBuilder.setMinMargins(new PrintAttributes.Margins(
          mmToMils(margins.getLeft()),
          mmToMils(margins.getTop()),
          mmToMils(margins.getRight()),
          mmToMils(margins.getBottom())));
    }

    PrintManager pm = (PrintManager) activity.getSystemService(Context.PRINT_SERVICE);
    pm.print(file.getName(), new FilePrintDocumentAdapter(filePath), attrBuilder.build());
  }

  private static int mmToMils(double mm) {
    return (int) Math.round(mm * 39.37);
  }

  @Nullable
  private static PrintAttributes.MediaSize resolveMediaSize(@NonNull Messages.PageSize pageSize) {
    // Named sizes take priority per the API contract.
    PrintAttributes.MediaSize named = namedMediaSize(pageSize.getName());
    if (named != null) return named;

    // Fall back to explicit dimensions (mm → mils, 1 mil = 1/1000 inch).
    Double width = pageSize.getWidth();
    Double height = pageSize.getHeight();
    if (width != null && height != null && width > 0 && height > 0) {
      int wMils = (int) Math.round(width * 39.3701);
      int hMils = (int) Math.round(height * 39.3701);
      return new PrintAttributes.MediaSize("CUSTOM_" + wMils + "x" + hMils, "Custom", wMils, hMils);
    }
    return null;
  }

  @Nullable
  private static PrintAttributes.MediaSize namedMediaSize(@NonNull String name) {
    return switch (name.toUpperCase()) {
      // ISO A-series
      case "A0" -> PrintAttributes.MediaSize.ISO_A0;
      case "A1" -> PrintAttributes.MediaSize.ISO_A1;
      case "A2" -> PrintAttributes.MediaSize.ISO_A2;
      case "A3" -> PrintAttributes.MediaSize.ISO_A3;
      case "A4" -> PrintAttributes.MediaSize.ISO_A4;
      case "A5" -> PrintAttributes.MediaSize.ISO_A5;
      case "A6" -> PrintAttributes.MediaSize.ISO_A6;
      // ISO B-series
      case "B4" -> PrintAttributes.MediaSize.ISO_B4;
      case "B5" -> PrintAttributes.MediaSize.ISO_B5;
      // JIS B-series (different dimensions from ISO B)
      case "JIS B4" -> PrintAttributes.MediaSize.JIS_B4;
      case "JIS B5" -> PrintAttributes.MediaSize.JIS_B5;
      // North American
      case "LETTER" -> PrintAttributes.MediaSize.NA_LETTER;
      case "LEGAL" -> PrintAttributes.MediaSize.NA_LEGAL;
      case "TABLOID" -> PrintAttributes.MediaSize.NA_LEDGER;
      case "EXECUTIVE" -> new PrintAttributes.MediaSize(
          "NA_EXECUTIVE", "Executive", 7252, 10500);
      // Envelopes (no standard Android constants — use custom)
      case "C5" -> new PrintAttributes.MediaSize("ISO_C5", "C5", 6378, 9016);
      case "DL" -> new PrintAttributes.MediaSize("ISO_DL", "DL", 4331, 8661);
      default -> null;
    };
  }

  // -------------------------------------------------------------------------
  // PrintDocumentAdapter
  // -------------------------------------------------------------------------

  private static final class FilePrintDocumentAdapter extends PrintDocumentAdapter {
    private final String filePath;

    FilePrintDocumentAdapter(String filePath) {
      this.filePath = filePath;
    }

    @Override
    public void onLayout(PrintAttributes oldAttrs, PrintAttributes newAttrs,
                         CancellationSignal cancel, LayoutResultCallback callback,
                         Bundle extras) {

      if (cancel.isCanceled()) {
        callback.onLayoutCancelled();
        return;
      }

      PrintDocumentInfo info = new PrintDocumentInfo
          .Builder(new File(filePath).getName())
          .setContentType(PrintDocumentInfo.CONTENT_TYPE_DOCUMENT)
          .setPageCount(PrintDocumentInfo.PAGE_COUNT_UNKNOWN)
          .build();

      callback.onLayoutFinished(info, !newAttrs.equals(oldAttrs));
    }

    @Override
    public void onWrite(PageRange[] pages, ParcelFileDescriptor destination,
                        CancellationSignal cancel, WriteResultCallback callback) {

      try (InputStream in = new FileInputStream(filePath);
           OutputStream out = new FileOutputStream(destination.getFileDescriptor())) {

        byte[] buf = new byte[8192];
        int len;

        while ((len = in.read(buf)) > 0) {
          if (cancel.isCanceled()) {
            callback.onWriteCancelled();
            return;
          }
          out.write(buf, 0, len);
        }

        callback.onWriteFinished(new PageRange[]{PageRange.ALL_PAGES});
      } catch (IOException e) {
        callback.onWriteFailed(e.getMessage());
      }
    }
  }
}
