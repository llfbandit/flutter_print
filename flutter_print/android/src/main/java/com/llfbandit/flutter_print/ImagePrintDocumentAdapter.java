package com.llfbandit.flutter_print;

import android.content.Context;
import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.graphics.Canvas;
import android.graphics.Matrix;
import android.graphics.Paint;
import android.graphics.Rect;
import android.graphics.RectF;
import android.graphics.pdf.PdfDocument;
import android.media.ExifInterface;
import android.os.Bundle;
import android.os.CancellationSignal;
import android.os.Handler;
import android.os.Looper;
import android.os.ParcelFileDescriptor;
import android.print.PageRange;
import android.print.PrintAttributes;
import android.print.PrintDocumentAdapter;
import android.print.PrintDocumentInfo;
import android.print.pdf.PrintedPdfDocument;

import androidx.annotation.NonNull;

import java.io.FileOutputStream;
import java.io.IOException;
import java.io.OutputStream;

// Prints an image on one page, with the paper and margins of the dialog. The
// image keeps its real size from its DPI (96 when it has none), and shrinks
// when it is larger than the page, but never grows. Photos print upright from
// their EXIF orientation.
final class ImagePrintDocumentAdapter extends PrintDocumentAdapter {
  private static final double POINTS_PER_INCH = 72;
  private static final double DEFAULT_DPI = 96;
  // Enough for print, and keeps large photos in memory.
  private static final double PRINT_DPI = 300;

  private final Context context;
  private final String filePath;
  private final String jobName;
  private PrintAttributes attributes;

  ImagePrintDocumentAdapter(@NonNull Context context, @NonNull String filePath,
                            @NonNull String jobName) {
    this.context = context.getApplicationContext();
    this.filePath = filePath;
    this.jobName = jobName;
  }

  @Override
  public void onLayout(PrintAttributes oldAttrs, PrintAttributes newAttrs,
                       CancellationSignal cancel, LayoutResultCallback callback,
                       Bundle extras) {
    if (cancel.isCanceled()) {
      callback.onLayoutCancelled();
      return;
    }
    attributes = newAttrs;
    PrintDocumentInfo info = new PrintDocumentInfo.Builder(jobName)
        .setContentType(PrintDocumentInfo.CONTENT_TYPE_PHOTO)
        .setPageCount(1)
        .build();
    callback.onLayoutFinished(info, !newAttrs.equals(oldAttrs));
  }

  @Override
  public void onWrite(PageRange[] pages, ParcelFileDescriptor destination,
                      CancellationSignal cancel, WriteResultCallback callback) {
    PrintAttributes attrs = attributes;
    Handler handler = new Handler(Looper.getMainLooper());

    // Decode off the main thread; post callbacks back to it.
    new Thread(() -> {
      PrintedPdfDocument pdf = new PrintedPdfDocument(context, attrs);
      try {
        PdfDocument.Page page = pdf.startPage(0);
        boolean drawn = draw(page.getCanvas(), page.getInfo().getContentRect());
        pdf.finishPage(page);
        if (!drawn) {
          handler.post(() -> callback.onWriteFailed("Cannot decode image"));
          return;
        }
        if (cancel.isCanceled()) {
          handler.post(callback::onWriteCancelled);
          return;
        }
        try (OutputStream out = new FileOutputStream(destination.getFileDescriptor())) {
          pdf.writeTo(out);
        }
        handler.post(() -> callback.onWriteFinished(new PageRange[]{new PageRange(0, 0)}));
      } catch (IOException | RuntimeException e) {
        handler.post(() -> callback.onWriteFailed(e.getMessage()));
      } finally {
        pdf.close();
      }
    }, "flutter_print-image").start();
  }

  // Draws the image centered in |area| (points). Returns false when it can't
  // be decoded.
  private boolean draw(@NonNull Canvas canvas, @NonNull Rect area) {
    BitmapFactory.Options bounds = new BitmapFactory.Options();
    bounds.inJustDecodeBounds = true;
    BitmapFactory.decodeFile(filePath, bounds);
    int width = bounds.outWidth, height = bounds.outHeight;
    if (width <= 0 || height <= 0 || area.isEmpty()) return false;

    int orientation = ExifInterface.ORIENTATION_NORMAL;
    double dpi = DEFAULT_DPI;
    try {
      ExifInterface exif = new ExifInterface(filePath);
      orientation = exif.getAttributeInt(
          ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_NORMAL);
      dpi = dpi(exif);
    } catch (IOException | RuntimeException ignored) {
      // No EXIF: upright, at the default DPI.
    }

    Matrix upright = uprightMatrix(orientation);
    RectF turned = new RectF(0, 0, width, height);
    upright.mapRect(turned);

    // Real size in points, shrunk to the area.
    double realWidth = turned.width() / dpi * POINTS_PER_INCH;
    double realHeight = turned.height() / dpi * POINTS_PER_INCH;
    double scale = Math.min(1, Math.min(area.width() / realWidth, area.height() / realHeight));
    float drawWidth = (float) (realWidth * scale);
    float drawHeight = (float) (realHeight * scale);

    // Decode no more pixels than the page shows at PRINT_DPI.
    double needed = Math.max(drawWidth, drawHeight) / POINTS_PER_INCH * PRINT_DPI;
    double ratio = Math.max(turned.width(), turned.height()) / needed;
    BitmapFactory.Options decode = new BitmapFactory.Options();
    decode.inSampleSize = 1;
    while (decode.inSampleSize * 2 <= ratio) decode.inSampleSize *= 2;
    Bitmap bitmap = BitmapFactory.decodeFile(filePath, decode);
    if (bitmap == null) return false;

    Matrix matrix = uprightMatrix(orientation);
    RectF placed = new RectF(0, 0, bitmap.getWidth(), bitmap.getHeight());
    matrix.mapRect(placed);
    matrix.postTranslate(-placed.left, -placed.top);
    matrix.postScale(drawWidth / placed.width(), drawHeight / placed.height());
    matrix.postTranslate(area.exactCenterX() - drawWidth / 2,
                         area.exactCenterY() - drawHeight / 2);
    canvas.drawBitmap(bitmap, matrix, new Paint(Paint.FILTER_BITMAP_FLAG));
    bitmap.recycle();
    return true;
  }

  // Returns the EXIF resolution in dots per inch, or the default.
  private static double dpi(@NonNull ExifInterface exif) {
    double resolution = exif.getAttributeDouble(ExifInterface.TAG_X_RESOLUTION, 0);
    if (resolution <= 0) return DEFAULT_DPI;
    // Unit 3 is centimetres; 2, the default, is inches.
    int unit = exif.getAttributeInt(ExifInterface.TAG_RESOLUTION_UNIT, 2);
    return unit == 3 ? resolution * 2.54 : resolution;
  }

  // Turns the image as its EXIF orientation says to show it.
  @NonNull
  private static Matrix uprightMatrix(int orientation) {
    Matrix m = new Matrix();
    switch (orientation) {
      case ExifInterface.ORIENTATION_FLIP_HORIZONTAL -> m.setScale(-1, 1);
      case ExifInterface.ORIENTATION_ROTATE_180 -> m.setRotate(180);
      case ExifInterface.ORIENTATION_FLIP_VERTICAL -> m.setScale(1, -1);
      case ExifInterface.ORIENTATION_TRANSPOSE -> {
        m.setRotate(90);
        m.postScale(-1, 1);
      }
      case ExifInterface.ORIENTATION_ROTATE_90 -> m.setRotate(90);
      case ExifInterface.ORIENTATION_TRANSVERSE -> {
        m.setRotate(-90);
        m.postScale(-1, 1);
      }
      case ExifInterface.ORIENTATION_ROTATE_270 -> m.setRotate(-90);
      default -> {
      }
    }
    return m;
  }
}
