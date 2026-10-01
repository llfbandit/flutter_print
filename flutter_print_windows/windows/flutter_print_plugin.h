#ifndef FLUTTER_PLUGIN_FLUTTER_PRINT_PLUGIN_H_
#define FLUTTER_PLUGIN_FLUTTER_PRINT_PLUGIN_H_

#include <windows.h>
#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>

#include "messages.h"

#include <atomic>
#include <functional>
#include <memory>
#include <optional>
#include <string>

namespace flutter_print {

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
  void HandleGetPageCount(const flutter::EncodableMap& args, WinResult result);
  void HandleRenderPageToPng(const flutter::EncodableMap& args, WinResult result);
  void HandleDecodeTextFile(const flutter::EncodableMap& args, WinResult result);
  void HandleGetMinimumMargins(const flutter::EncodableMap& args, WinResult result);
  void HandleGetDefaultPaperSize(const flutter::EncodableMap& args, WinResult result);
  void HandleOpenInDefaultApp(const flutter::EncodableMap& args, WinResult result);

  // Set to false on destruction: worker threads then drop their reply.
  std::shared_ptr<std::atomic<bool>> alive_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      windows_channel_;
};

}  // namespace flutter_print

#endif  // FLUTTER_PLUGIN_FLUTTER_PRINT_PLUGIN_H_
