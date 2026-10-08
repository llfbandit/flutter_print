#include "print_portal.h"

#include <fcntl.h>
#include <gio/gunixfdlist.h>
#include <unistd.h>
#ifdef GDK_WINDOWING_X11
#include <gdk/gdkx.h>
#endif
#ifdef GDK_WINDOWING_WAYLAND
#include <gdk/gdkwayland.h>
#endif

#include "print_file.h"
#include "print_settings.h"

// The print portal: PreparePrint shows the dialog and returns a token.
// Print sends the file with the settings of that token. Each call answers
// with a Response signal on a request object.
#define PORTAL_BUS_NAME "org.freedesktop.portal.Desktop"
#define PORTAL_OBJECT_PATH "/org/freedesktop/portal/desktop"
#define PORTAL_PRINT_INTERFACE "org.freedesktop.portal.Print"
#define PORTAL_REQUEST_INTERFACE "org.freedesktop.portal.Request"

// Portal response codes.
enum { kPortalSuccess = 0, kPortalCancelled = 1 };

// Lives until the job is sent, or the user cancels, or a call fails.
typedef struct {
  PrintFile* file;
  GtkPrintSettings* settings;
  GtkPageSetup* page_setup;
  FlutterPrintFlutterPrintApiResponseHandle* response_handle;
  GDBusConnection* connection;
  guint signal_id;           // The Response signal we wait for, or 0.
  gchar* parent_handle;      // "x11:…", "wayland:…", or "".
  GdkWindow* exported;       // The Wayland window to unexport, or null.
} PortalRequest;

static void portal_request_free(PortalRequest* request) {
  if (request->signal_id) {
    g_dbus_connection_signal_unsubscribe(request->connection,
                                         request->signal_id);
  }
#ifdef GDK_WINDOWING_WAYLAND
  if (request->exported) {
    gdk_wayland_window_unexport_handle(request->exported);
  }
#endif
  g_clear_object(&request->exported);
  print_file_free(request->file);
  g_clear_object(&request->settings);
  g_clear_object(&request->page_setup);
  g_object_unref(request->response_handle);
  g_clear_object(&request->connection);
  g_free(request->parent_handle);
  g_free(request);
}

static void portal_request_succeed(PortalRequest* request) {
  flutter_print_flutter_print_api_respond_print_preview(
      request->response_handle);
  portal_request_free(request);
}

static void portal_request_fail(PortalRequest* request, const char* code,
                                const gchar* message) {
  flutter_print_flutter_print_api_respond_error_print_preview(
      request->response_handle, code, message, nullptr);
  portal_request_free(request);
}

bool print_portal_should_use() {
  return g_file_test("/.flatpak-info", G_FILE_TEST_EXISTS) ||
         g_getenv("SNAP") != nullptr ||
         g_strcmp0(g_getenv("GTK_USE_PORTAL"), "1") == 0;
}

// Waits for the Response signal of a new request, and returns its token. The
// portal builds the request path from our bus name and this token. Subscribe
// before the call, so the signal can't come first.
static gchar* wait_for_response(PortalRequest* request,
                                GDBusSignalCallback callback) {
  g_autofree gchar* sender =
      g_strdup(g_dbus_connection_get_unique_name(request->connection) + 1);
  g_strdelimit(sender, ".", '_');
  gchar* token = g_strdup_printf("flutter_print_%u", g_random_int());
  g_autofree gchar* path = g_strdup_printf(
      PORTAL_OBJECT_PATH "/request/%s/%s", sender, token);
  request->signal_id = g_dbus_connection_signal_subscribe(
      request->connection, PORTAL_BUS_NAME, PORTAL_REQUEST_INTERFACE,
      "Response", path, nullptr, G_DBUS_SIGNAL_FLAGS_NO_MATCH_RULE, callback,
      request, nullptr);
  return token;
}

// Stops waiting for the Response signal. Returns the response code and sets
// |results|.
static guint32 take_response(PortalRequest* request, GVariant* parameters,
                             GVariant** results) {
  g_dbus_connection_signal_unsubscribe(request->connection,
                                       request->signal_id);
  request->signal_id = 0;
  guint32 response = 2;
  g_variant_get(parameters, "(u@a{sv})", &response, results);
  return response;
}

// Fails the request when a portal call fails, for example when no portal
// runs.
static void call_done(GObject* source, GAsyncResult* result,
                      gpointer user_data) {
  PortalRequest* request = static_cast<PortalRequest*>(user_data);
  g_autoptr(GError) err = nullptr;
  g_autoptr(GVariant) reply = g_dbus_connection_call_with_unix_fd_list_finish(
      G_DBUS_CONNECTION(source), nullptr, result, &err);
  if (!reply) {
    g_autofree gchar* message =
        g_strdup_printf("Print portal failed: %s", err->message);
    portal_request_fail(request, "PREVIEW_ERROR", message);
  }
}

static void print_response(GDBusConnection* connection, const gchar* sender,
                           const gchar* path, const gchar* interface,
                           const gchar* signal, GVariant* parameters,
                           gpointer user_data) {
  PortalRequest* request = static_cast<PortalRequest*>(user_data);
  g_autoptr(GVariant) results = nullptr;
  guint32 response = take_response(request, parameters, &results);
  if (response == kPortalSuccess || response == kPortalCancelled) {
    portal_request_succeed(request);
  } else {
    portal_request_fail(request, "PRINT_ERROR", "The print portal failed");
  }
}

// Sends the file with the settings of |token|. The portal reads the file
// from a file descriptor, so it works for files inside the sandbox.
static void send_file(PortalRequest* request, guint32 token) {
  int fd = open(print_file_path(request->file), O_RDONLY | O_CLOEXEC);
  if (fd < 0) {
    portal_request_fail(request, "PRINT_ERROR", "Cannot open the file");
    return;
  }
  g_autoptr(GUnixFDList) fd_list = g_unix_fd_list_new_from_array(&fd, 1);

  g_autofree gchar* handle_token = wait_for_response(request, print_response);
  GVariantBuilder options;
  g_variant_builder_init(&options, G_VARIANT_TYPE_VARDICT);
  g_variant_builder_add(&options, "{sv}", "handle_token",
                        g_variant_new_string(handle_token));
  g_variant_builder_add(&options, "{sv}", "token", g_variant_new_uint32(token));

  g_dbus_connection_call_with_unix_fd_list(
      request->connection, PORTAL_BUS_NAME, PORTAL_OBJECT_PATH,
      PORTAL_PRINT_INTERFACE, "Print",
      g_variant_new("(ssh@a{sv})", request->parent_handle, "Flutter Print Job",
                    0, g_variant_builder_end(&options)),
      G_VARIANT_TYPE("(o)"), G_DBUS_CALL_FLAGS_NONE, -1, fd_list, nullptr,
      call_done, request);
}

static void prepare_response(GDBusConnection* connection, const gchar* sender,
                             const gchar* path, const gchar* interface,
                             const gchar* signal, GVariant* parameters,
                             gpointer user_data) {
  PortalRequest* request = static_cast<PortalRequest*>(user_data);
  g_autoptr(GVariant) results = nullptr;
  guint32 response = take_response(request, parameters, &results);
  guint32 token = 0;
  if (response == kPortalCancelled) {
    // Report a cancel as success, like on macOS and iOS.
    portal_request_succeed(request);
  } else if (response != kPortalSuccess ||
             !g_variant_lookup(results, "token", "u", &token)) {
    portal_request_fail(request, "PRINT_ERROR", "The print portal failed");
  } else {
    send_file(request, token);
  }
}

// Shows the dialog with the request settings.
static void prepare_print(PortalRequest* request) {
  g_autofree gchar* handle_token =
      wait_for_response(request, prepare_response);
  GVariantBuilder options;
  g_variant_builder_init(&options, G_VARIANT_TYPE_VARDICT);
  g_variant_builder_add(&options, "{sv}", "handle_token",
                        g_variant_new_string(handle_token));

  g_dbus_connection_call_with_unix_fd_list(
      request->connection, PORTAL_BUS_NAME, PORTAL_OBJECT_PATH,
      PORTAL_PRINT_INTERFACE, "PreparePrint",
      g_variant_new("(ss@a{sv}@a{sv}@a{sv})", request->parent_handle,
                    "Flutter Print Job",
                    gtk_print_settings_to_gvariant(request->settings),
                    gtk_page_setup_to_gvariant(request->page_setup),
                    g_variant_builder_end(&options)),
      G_VARIANT_TYPE("(o)"), G_DBUS_CALL_FLAGS_NONE, -1, nullptr, nullptr,
      call_done, request);
}

#ifdef GDK_WINDOWING_WAYLAND
static void wayland_handle_exported(GdkWindow* window, const char* handle,
                                    gpointer user_data) {
  PortalRequest* request = static_cast<PortalRequest*>(user_data);
  request->parent_handle = g_strdup_printf("wayland:%s", handle);
  prepare_print(request);
}
#endif

// Sets the parent window handle that the portal takes, then shows the
// dialog. On Wayland the handle comes later, in a callback. Without a known
// handle, the dialog opens without a parent.
static void prepare_print_for_window(PortalRequest* request,
                                     GtkWindow* parent) {
  GdkWindow* window =
      parent ? gtk_widget_get_window(GTK_WIDGET(parent)) : nullptr;
#ifdef GDK_WINDOWING_X11
  if (window && GDK_IS_X11_WINDOW(window)) {
    request->parent_handle =
        g_strdup_printf("x11:%lx", gdk_x11_window_get_xid(window));
    prepare_print(request);
    return;
  }
#endif
#ifdef GDK_WINDOWING_WAYLAND
  if (window && GDK_IS_WAYLAND_WINDOW(window) &&
      gdk_wayland_window_export_handle(window, wayland_handle_exported,
                                       request, nullptr)) {
    request->exported = GDK_WINDOW(g_object_ref(window));
    return;
  }
#endif
  request->parent_handle = g_strdup("");
  prepare_print(request);
}

void print_portal_show(GtkWindow* parent, const gchar* file_path,
                       FlutterPrintPrintOptions* options,
                       FlutterPrintFlutterPrintApiResponseHandle* response_handle) {
  PortalRequest* request = g_new0(PortalRequest, 1);
  // The caller frees the handle when this returns, so keep a ref.
  request->response_handle =
      FLUTTER_PRINT_FLUTTER_PRINT_API_RESPONSE_HANDLE(g_object_ref(response_handle));

  const char* code = nullptr;
  g_autofree gchar* message = nullptr;
  request->file = print_file_prepare(file_path, &code, &message);
  if (!request->file) {
    portal_request_fail(request, code, message);
    return;
  }

  g_autoptr(GError) err = nullptr;
  request->connection = g_bus_get_sync(G_BUS_TYPE_SESSION, nullptr, &err);
  if (!request->connection) {
    g_autofree gchar* bus_message =
        g_strdup_printf("No session bus: %s", err->message);
    portal_request_fail(request, "PREVIEW_ERROR", bus_message);
    return;
  }

  request->settings = gtk_print_settings_new();
  request->page_setup = gtk_page_setup_new();
  print_settings_fill(options, request->settings, request->page_setup);
  prepare_print_for_window(request, parent);
}
