cmake_minimum_required(VERSION 3.14)

set(PROJECT_NAME "flutter_print")
project(${PROJECT_NAME} LANGUAGES CXX)

cmake_policy(VERSION 3.14...3.25)

set(PLUGIN_NAME "flutter_print_plugin")

# ---------------------------------------------------------------------------
# PDFium — prebuilt binaries from https://github.com/bblanchon/pdfium-binaries
# ---------------------------------------------------------------------------
include(FetchContent)
FetchContent_Declare(
  pdfium
  URL      "https://github.com/bblanchon/pdfium-binaries/releases/download/chromium/7857/pdfium-win-x64.tgz"
  URL_HASH "SHA256=b904e3898f952984fb744e0c8eb36512b5ee527124796108ed419a5b4da3c6d9"
)
FetchContent_MakeAvailable(pdfium)

# ---------------------------------------------------------------------------
# Plugin sources
# ---------------------------------------------------------------------------
list(APPEND PLUGIN_SOURCES
  "flutter_print_plugin.cpp"
  "flutter_print_plugin.h"
  "flutter_print_utils.cpp"
  "flutter_print_utils.h"
  "messages.cpp"
  "messages.h"
)

add_library(${PLUGIN_NAME} SHARED
  "include/flutter_print/flutter_print_plugin_c_api.h"
  "flutter_print_plugin_c_api.cpp"
  ${PLUGIN_SOURCES}
)

apply_standard_settings(${PLUGIN_NAME})

set_target_properties(${PLUGIN_NAME} PROPERTIES
  CXX_VISIBILITY_PRESET hidden)
target_compile_definitions(${PLUGIN_NAME} PRIVATE FLUTTER_PLUGIN_IMPL)

target_include_directories(${PLUGIN_NAME} INTERFACE
  "${CMAKE_CURRENT_SOURCE_DIR}/include")
target_include_directories(${PLUGIN_NAME} PRIVATE
  "${pdfium_SOURCE_DIR}/include")

target_link_libraries(${PLUGIN_NAME} PRIVATE
  flutter
  flutter_wrapper_plugin
  gdiplus
  "${pdfium_SOURCE_DIR}/lib/pdfium.dll.lib"
)

# pdfium.dll must ship alongside the plugin.
set(flutter_print_bundled_libraries
  "${pdfium_SOURCE_DIR}/bin/pdfium.dll"
  PARENT_SCOPE
)
