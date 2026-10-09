package com.llfbandit.flutter_print;

import android.app.Activity;
import android.content.Context;
import android.graphics.BitmapFactory;
import android.graphics.pdf.PdfRenderer;
import android.net.Uri;
import android.os.Bundle;
import android.os.CancellationSignal;
import android.os.Handler;
import android.os.Looper;
import android.os.ParcelFileDescriptor;
import android.print.PageRange;
import android.print.PrintAttributes;
import android.print.PrintDocumentAdapter;
import android.print.PrintDocumentInfo;
import android.print.PrintJob;
import android.print.PrintJobInfo;
import android.print.PrintManager;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;
import androidx.print.PrintHelper;

import java.io.File;
import java.io.FileInputStream;
import java.io.FileNotFoundException;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.List;

import io.flutter.embedding.engine.plugins.FlutterPlugin;
import io.flutter.embedding.engine.plugins.activity.ActivityAware;
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding;

public class FlutterPrintPlugin
    implements FlutterPlugin, ActivityAware, Messages.FlutterPrintApi {

  @Nullable
  private Activity activity;

  private final Handler handler = new Handler(Looper.getMainLooper());

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
    // Stop watching print jobs.
    handler.removeCallbacksAndMessages(null);
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
  public void print(@NonNull String filePath, @Nullable Messages.PrintOptions options,
                    @NonNull Messages.VoidResult result) {
    try {
      handlePrint(filePath, options, result);
    } catch (Throwable e) {
      result.error(e);
    }
  }

  @Override
  public void printPreview(@NonNull String filePath, @Nullable Messages.PrintOptions options,
                           @NonNull Messages.VoidResult result) {
    // Android's print UI always shows a dialog with a preview.
    try {
      handlePrint(filePath, options, result);
    } catch (Throwable e) {
      result.error(e);
    }
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

  private void handlePrint(@NonNull String filePath, @Nullable Messages.PrintOptions options,
                           @NonNull Messages.VoidResult result) throws FileNotFoundException {
    if (activity == null) {
      throw new Messages.FlutterError("NO_ACTIVITY", "Printing requires an active Activity", null);
    }

    File file = new File(filePath);
    if (!file.exists()) {
      throw new Messages.FlutterError("FILE_NOT_FOUND", "File not found: " + filePath, null);
    }

    if (isPdf(file)) {
      watchJob(printPdf(file, options), result);
    } else if (isImage(filePath)) {
      printImage(file, options, result);
    } else {
      throw new Messages.FlutterError(
          "UNSUPPORTED_FILE", "File type not supported for printing", null);
    }
  }

  // Prints a PDF via the framework's PrintManager, streaming the file as-is.
  @NonNull
  private PrintJob printPdf(@NonNull File file, @Nullable Messages.PrintOptions options) {
    PrintAttributes.Builder attrBuilder = new PrintAttributes.Builder();

    // When options are omitted, leave PrintAttributes empty so the system /
    // printer default settings apply.
    if (options != null) {
      // Each field is applied only when provided; unset fields keep the
      // system / printer default. A null landscape is treated as portrait.
      boolean landscape = Boolean.TRUE.equals(options.getLandscape());
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
      if (color != null) {
        attrBuilder.setColorMode(
            color ? PrintAttributes.COLOR_MODE_COLOR : PrintAttributes.COLOR_MODE_MONOCHROME);
      }

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
    }

    PrintManager pm = (PrintManager) activity.getSystemService(Context.PRINT_SERVICE);
    if (pm == null) {
      throw new Messages.FlutterError(
          "NO_PRINT_SERVICE", "Printing is not supported on this device", null);
    }
    return pm.print(
        file.getName(), new FilePrintDocumentAdapter(file.getPath()), attrBuilder.build());
  }

  // Prints an image via androidx PrintHelper, which loads/scales it off the main
  // thread and shows the system print UI. onFinish fires on completion or
  // cancellation (both success); PrintHelper exposes no failure signal.
  private void printImage(@NonNull File file, @Nullable Messages.PrintOptions options,
                          @NonNull Messages.VoidResult result) throws FileNotFoundException {
    PrintHelper helper = new PrintHelper(activity);
    helper.setScaleMode(PrintHelper.SCALE_MODE_FIT);

    if (options != null) {
      Boolean color = options.getColor();
      if (color != null) {
        helper.setColorMode(
            color ? PrintHelper.COLOR_MODE_COLOR : PrintHelper.COLOR_MODE_MONOCHROME);
      }
      Boolean landscape = options.getLandscape();
      if (landscape != null) {
        helper.setOrientation(
            landscape ? PrintHelper.ORIENTATION_LANDSCAPE : PrintHelper.ORIENTATION_PORTRAIT);
      }
    }

    helper.printBitmap(file.getName(), Uri.fromFile(file), result::success);
  }

  // Looks for the %PDF- marker, which may follow up to 1 KB of junk.
  private static boolean isPdf(@NonNull File file) {
    byte[] buf = new byte[1024];
    int len = 0;
    try (InputStream in = new FileInputStream(file)) {
      int n;
      while (len < buf.length && (n = in.read(buf, len, buf.length - len)) > 0) {
        len += n;
      }
    } catch (IOException e) {
      return false;
    }
    return new String(buf, 0, len, StandardCharsets.ISO_8859_1).contains("%PDF-");
  }

  // Treats anything BitmapFactory can read as an image. It can't read TIFF,
  // or HEIC before Android 9.
  private static boolean isImage(@NonNull String filePath) {
    BitmapFactory.Options opts = new BitmapFactory.Options();
    opts.inJustDecodeBounds = true;
    BitmapFactory.decodeFile(filePath, opts);
    return opts.outMimeType != null && opts.outMimeType.startsWith("image/");
  }

  // No callback exists for print jobs, so poll until the user closes the dialog.
  // A sent or cancelled job succeeds (as on iOS/macOS); only failure errors.
  // Don't wait for the printer: an offline printer keeps the job queued.
  private void watchJob(@NonNull PrintJob job, @NonNull Messages.VoidResult result) {
    handler.post(new Runnable() {
      @Override
      public void run() {
        if (job.isFailed()) {
          result.error(new Messages.FlutterError(
              "PRINT_FAILED", "Print job failed", null));
        } else if (job.getInfo().getState() != PrintJobInfo.STATE_CREATED) {
          result.success();
        } else {
          // The print dialog is still open.
          handler.postDelayed(this, 200);
        }
      }
    });
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
          .setPageCount(pageCount(filePath))
          .build();

      callback.onLayoutFinished(info, !newAttrs.equals(oldAttrs));
    }

    // Report the PDF page count so the dialog enables page-range selection.
    // Falls back to PAGE_COUNT_UNKNOWN for a non-PDF or unreadable file.
    private static int pageCount(String filePath) {
      try (ParcelFileDescriptor pfd = ParcelFileDescriptor.open(
              new File(filePath), ParcelFileDescriptor.MODE_READ_ONLY);
           PdfRenderer renderer = new PdfRenderer(pfd)) {
        return renderer.getPageCount();
      } catch (Exception e) {
        return PrintDocumentInfo.PAGE_COUNT_UNKNOWN;
      }
    }

    @Override
    public void onWrite(PageRange[] pages, ParcelFileDescriptor destination,
                        CancellationSignal cancel, WriteResultCallback callback) {

      // Copy off the main thread; post callbacks back to it.
      Handler handler = new Handler(Looper.getMainLooper());

      new Thread(() -> {
        try (InputStream in = new FileInputStream(filePath);
             OutputStream out = new FileOutputStream(destination.getFileDescriptor())) {

          byte[] buf = new byte[8192];
          int len;

          while ((len = in.read(buf)) > 0) {
            if (cancel.isCanceled()) {
              handler.post(callback::onWriteCancelled);
              return;
            }
            out.write(buf, 0, len);
          }

          handler.post(() -> callback.onWriteFinished(new PageRange[]{PageRange.ALL_PAGES}));
        } catch (IOException e) {
          handler.post(() -> callback.onWriteFailed(e.getMessage()));
        }
      }, "flutter_print-write").start();
    }
  }
}
