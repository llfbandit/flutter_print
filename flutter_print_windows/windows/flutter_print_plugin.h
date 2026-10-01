#ifndef FLUTTER_PLUGIN_FLUTTER_PRINT_PLUGIN_H_
#define FLUTTER_PLUGIN_FLUTTER_PRINT_PLUGIN_H_

#include <windows.h>
#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>

#include "flutter_print_utils.h"
#include "messages.h"

#include <atomic>
#include <functional>
#include <map>
#include <memory>
#include <optional>
#include <string>

namespace flutter_print {

class Preview;

using WinResult =
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>;

class FlutterPrintPlugin : public flutter::Plugin, public FlutterPrintApi {
 public:
  static void RegisterWithRegistrar(flutter::PluginRegistrarWindows* registrar);

  FlutterPrintPlugin();
  ~FlutterPrintPlugin() override;

  FlutterPrintPlugin(const FlutterPrintPlugin&) = delete;
  FlutterPrintPlugin& operator=(const FlutterPrintPlugin&) = delete;

  // FlutterPrintApi
  void Print(const std::string& file_path, const PrintOptions* options,
             std::function<void(std::optional<FlutterError> reply)> result) override;
  void PrintPreview(const std::string& file_path, const PrintOptions* options,
                    std::function<void(std::optional<FlutterError> reply)> result) override;
  void PickPrinter(
      std::function<void(ErrorOr<std::optional<PrinterInfo>>)> result) override;
  void ListPrinters(
      std::function<void(ErrorOr<flutter::EncodableList>)> result) override;

 private:
  std::optional<FlutterError> PrintInternal(const std::string& file_path,
                                            const PrintOptions* options);

  // Windows channel, used by the Dart print dialog.
  void HandleWindowsMethod(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      WinResult result);
  void HandleGetFileKind(const flutter::EncodableMap& args, WinResult result);
  void HandleOpenPreview(const flutter::EncodableMap& args, WinResult result);
  void HandleRenderPreviewPage(const flutter::EncodableMap& args, WinResult result);
  void HandleClosePreview(const flutter::EncodableMap& args, WinResult result);
  void HandleGetDefaultPaperSize(const flutter::EncodableMap& args, WinResult result);
  void HandleOpenInDefaultApp(const flutter::EncodableMap& args, WinResult result);

  // Runs |work| on the preview worker, then replies with its value if the
  // plugin still exists.
  void PostPreviewTask(WinResult result,
                       std::function<flutter::EncodableValue()> work);

  // Set to false on destruction: worker threads then drop their reply.
  std::shared_ptr<std::atomic<bool>> alive_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      windows_channel_;

  // The open previews, by id. Only the preview worker uses them.
  std::map<int64_t, std::unique_ptr<Preview>> previews_;
  int64_t last_preview_id_ = 0;
  SerialWorker preview_worker_;
};

}  // namespace flutter_print

#endif  // FLUTTER_PLUGIN_FLUTTER_PRINT_PLUGIN_H_
