#include "include/flutter_print/flutter_print_plugin_c_api.h"

#include <flutter/plugin_registrar_windows.h>

#include "flutter_print_plugin.h"

void FlutterPrintPluginCApiRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar) {
  flutter_print::FlutterPrintPlugin::RegisterWithRegistrar(
      flutter::PluginRegistrarManager::GetInstance()
          ->GetRegistrar<flutter::PluginRegistrarWindows>(registrar));
}
