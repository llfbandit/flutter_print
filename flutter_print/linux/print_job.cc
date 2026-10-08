#include "print_job.h"

#include <cups/cups.h>

#include "cups_options.h"
#include "print_file.h"

typedef struct {
  gchar* file_path;
  FlutterPrintPrintOptions* options;  // May be null.
  FlutterPrintFlutterPrintApiResponseHandle* response_handle;
  const char* error_code;  // Null on success.
  gchar* error_message;
} PrintJob;

static void print_job_free(gpointer data) {
  PrintJob* job = static_cast<PrintJob*>(data);
  g_free(job->file_path);
  g_clear_object(&job->options);
  g_object_unref(job->response_handle);
  g_free(job->error_message);
  g_free(job);
}

// Takes ownership of |message|.
static void print_job_fail(PrintJob* job, const char* code, gchar* message) {
  job->error_code = code;
  job->error_message = message;
}

// Builds the CUPS options for |options|, on top of the |dest| printer's
// saved options. Returns the number of options.
static int build_options(FlutterPrintPrintOptions* options, cups_dest_t* dest,
                         cups_option_t** cups_opts) {
  int num_options = 0;
  for (int i = 0; i < dest->num_options; i++) {
    num_options = cupsAddOption(dest->options[i].name, dest->options[i].value,
                                num_options, cups_opts);
  }
  if (!options) return num_options;

  const int64_t* copies = flutter_print_print_options_get_copies(options);
  if (copies && *copies > 1) {
    g_autofree gchar* s = g_strdup_printf("%" G_GINT64_FORMAT, *copies);
    num_options = cupsAddOption("copies", s, num_options, cups_opts);
  }

  // Use the IPP option, not the old CUPS "landscape" option. 3 is portrait
  // and 4 is landscape.
  const gboolean* landscape = flutter_print_print_options_get_landscape(options);
  if (landscape) {
    num_options = cupsAddOption("orientation-requested", *landscape ? "4" : "3",
                                num_options, cups_opts);
  }

  // Send both values, so a printer that defaults to mono prints in colour.
  const gboolean* color = flutter_print_print_options_get_color(options);
  if (color) {
    num_options = cupsAddOption("print-color-mode",
                                *color ? "color" : "monochrome",
                                num_options, cups_opts);
  }

  if (const char* sides = duplex_sides(options)) {
    num_options = cupsAddOption("sides", sides, num_options, cups_opts);
  }

  // Send the name as is when CUPS doesn't know the paper.
  FlutterPrintPageSize* page_size =
      flutter_print_print_options_get_page_size(options);
  if (page_size) {
    pwg_media_t* media = page_size_media(page_size);
    const gchar* name = flutter_print_page_size_get_name(page_size);
    if (media) {
      num_options = cupsAddOption("media", media->pwg, num_options, cups_opts);
    } else if (name && name[0] != '\0') {
      num_options = cupsAddOption("media", name, num_options, cups_opts);
    }
  }

  g_autofree gchar* page_ranges = build_page_ranges(options);
  if (page_ranges) {
    num_options = cupsAddOption("page-ranges", page_ranges, num_options,
                                cups_opts);
  }
  return num_options;
}

// Runs on a worker thread.
static void print_job_run(PrintJob* job) {
  const char* code = nullptr;
  gchar* message = nullptr;
  PrintFile* file = print_file_prepare(job->file_path, &code, &message);
  if (!file) {
    print_job_fail(job, code, message);
    return;
  }

  // cupsGetNamedDest uses the user's default printer and saved options
  // (lpoptions). A null name gives the default printer.
  const gchar* printer_address =
      job->options ? flutter_print_print_options_get_printer_address(job->options)
                   : nullptr;
  if (printer_address && printer_address[0] == '\0') printer_address = nullptr;
  cups_dest_t* dest = cupsGetNamedDest(CUPS_HTTP_DEFAULT, printer_address,
                                       nullptr);
  if (!dest) {
    print_file_free(file);
    print_job_fail(job, "PRINTER_ERROR",
                   printer_address
                       ? g_strdup_printf("Unknown printer: %s", printer_address)
                       : g_strdup("No default printer"));
    return;
  }

  cups_option_t* cups_opts = nullptr;
  int num_options = build_options(job->options, dest, &cups_opts);
  int job_id = cupsPrintFile(dest->name, print_file_path(file),
                             "Flutter Print Job", num_options, cups_opts);
  cupsFreeOptions(num_options, cups_opts);
  cupsFreeDests(1, dest);
  print_file_free(file);

  if (job_id == 0) {
    print_job_fail(job, "PRINT_ERROR", g_strdup(cupsLastErrorString()));
  }
}

static void print_job_thread(GTask* task, gpointer source_object,
                             gpointer task_data, GCancellable* cancellable) {
  print_job_run(static_cast<PrintJob*>(task_data));
  g_task_return_boolean(task, TRUE);
}

// Runs on the main thread when the job is done.
static void print_job_done(GObject* source_object, GAsyncResult* result,
                           gpointer user_data) {
  PrintJob* job = static_cast<PrintJob*>(g_task_get_task_data(G_TASK(result)));
  if (job->error_code) {
    flutter_print_flutter_print_api_respond_error_print(
        job->response_handle, job->error_code, job->error_message, nullptr);
  } else {
    flutter_print_flutter_print_api_respond_print(job->response_handle);
  }
}

void print_job_start(const gchar* file_path, FlutterPrintPrintOptions* options,
                     FlutterPrintFlutterPrintApiResponseHandle* response_handle) {
  // The caller frees its arguments when this returns, so the job keeps its
  // own.
  PrintJob* job = g_new0(PrintJob, 1);
  job->file_path = g_strdup(file_path);
  job->options = options ? FLUTTER_PRINT_PRINT_OPTIONS(g_object_ref(options))
                         : nullptr;
  job->response_handle =
      FLUTTER_PRINT_FLUTTER_PRINT_API_RESPONSE_HANDLE(g_object_ref(response_handle));

  g_autoptr(GTask) task = g_task_new(nullptr, nullptr, print_job_done, nullptr);
  g_task_set_task_data(task, job, print_job_free);
  g_task_run_in_thread(task, print_job_thread);
}
