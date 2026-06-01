#ifndef FLUTTER_PLUGIN_FLUTTER_PRINT_PLUGIN_H_
#define FLUTTER_PLUGIN_FLUTTER_PRINT_PLUGIN_H_

#include <windows.h>
#include <flutter/plugin_registrar_windows.h>

#include "messages.h"

#include <functional>
#include <memory>
#include <optional>
#include <string>

namespace flutter_print {

class FlutterPrintPlugin : public flutter::Plugin, public FlutterPrintApi {
 public:
  static void RegisterWithRegistrar(flutter::PluginRegistrarWindows* registrar);

  explicit FlutterPrintPlugin(HWND hwnd);
  ~FlutterPrintPlugin() override = default;

  FlutterPrintPlugin(const FlutterPrintPlugin&) = delete;
  FlutterPrintPlugin& operator=(const FlutterPrintPlugin&) = delete;

  // FlutterPrintApi
  std::optional<FlutterError> Print(const std::string& file_path,
                                     const PrintOptions& options) override;
  std::optional<FlutterError> PrintPreview(const std::string& file_path,
                                            const PrintOptions& options) override;
  void PickPrinter(
      std::function<void(ErrorOr<std::optional<PrinterInfo>>)> result) override;
  void ListPrinters(
      std::function<void(ErrorOr<flutter::EncodableList>)> result) override;

 private:
  HWND hwnd_;
};

}  // namespace flutter_print

#endif  // FLUTTER_PLUGIN_FLUTTER_PRINT_PLUGIN_H_
