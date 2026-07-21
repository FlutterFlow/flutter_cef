# flutter_cef_windows plugin build.
#
# S6a/S6b findings baked in (specs/windows-port/SPIKES.md):
#  - keep apply_standard_settings (CEF headers are NOT linked here — the
#    plugin talks to cef_host over IPC; CEF lives only in native/cef_host);
#  - NOMINMAX per target (any TU that ever includes cef_types_win.h needs it,
#    and windows.h's min/max macros break std::min/max regardless);
#  - out-of-tree sources under ../native/ build fine through
#    flutter/ephemeral/.plugin_symlinks (Developer Mode required);
#  - <plugin>_bundled_libraries PARENT_SCOPE lands extra files beside the
#    runner exe.
#
# The cef_host build is DRIVEN FROM HERE via build_cef_host.bat (its own
# CMake/Ninja project against CEF's cmake config — see
# ../native/cef_host/CMakeLists.txt). Deterministic + incremental-safe: the
# bat configures once and ninja no-ops when nothing changed.

cmake_minimum_required(VERSION 3.14)
set(PROJECT_NAME "flutter_cef_windows")
project(${PROJECT_NAME} LANGUAGES CXX)
cmake_policy(VERSION 3.14...3.25)

# This value is used when generating builds using this plugin, so it must
# not be changed.
set(PLUGIN_NAME "flutter_cef_windows_plugin")

list(APPEND PLUGIN_SOURCES
  "flutter_cef_plugin.cpp"
  "flutter_cef_plugin.h"
  "texture_bridge.cpp"
  "texture_bridge.h"
  "host_process.cpp"
  "host_process.h"
  "ipc_pipe.cpp"
  "ipc_pipe.h"
  "cdp_relay.cpp"
  "cdp_relay.h"
)

add_library(${PLUGIN_NAME} SHARED
  "include/flutter_cef_windows/flutter_cef_plugin.h"
  ${PLUGIN_SOURCES}
)

apply_standard_settings(${PLUGIN_NAME})

set_target_properties(${PLUGIN_NAME} PROPERTIES
  CXX_VISIBILITY_PRESET hidden)
target_compile_definitions(${PLUGIN_NAME} PRIVATE FLUTTER_PLUGIN_IMPL)
# S6a: NOMINMAX everywhere windows.h is reachable.
target_compile_definitions(${PLUGIN_NAME} PRIVATE NOMINMAX)

target_include_directories(${PLUGIN_NAME} INTERFACE
  "${CMAKE_CURRENT_SOURCE_DIR}/include")
# Shared wire-protocol constants (cef_host_protocol.h) live with the host.
target_include_directories(${PLUGIN_NAME} PRIVATE
  "${CMAKE_CURRENT_SOURCE_DIR}/../native/cef_host")
target_link_libraries(${PLUGIN_NAME} PRIVATE
  flutter
  flutter_wrapper_plugin
  d3d11
  dxgi
  # Agent-control CDP relay (P9): winsock (loopback HTTP+WS server) + bcrypt
  # (SHA-1 Sec-WebSocket-Accept + BCryptGenRandom token). cdp_relay.cpp.
  ws2_32
  bcrypt
)

# ---- cef_host: build + stage (LAW 8 ship pair: cef_host.dll + renamed
# bootstrapc.exe as cef_host.exe) ----

set(CEF_HOST_SRC_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../native/cef_host")
set(CEF_HOST_BUILD_DIR "${CMAKE_CURRENT_BINARY_DIR}/cef_host_build")
set(CEF_HOST_DIST_DIR "${CMAKE_CURRENT_BINARY_DIR}/cef_host_dist")

# CEF_DIST_NAME: the pinned distribution (keep in lockstep with
# ../native/cef_host/fetch_cef.ps1, build_cef_host.sh:17 and SPIKES.md). The
# LOCALAPPDATA candidate below is exactly what fetch_cef.ps1 advertises.
set(CEF_DIST_NAME
    "cef_binary_144.0.27+g3fae261+chromium-144.0.7559.254_windows64_minimal")

# CEF_ROOT resolution — ONE shared order, mirrored in
# ../native/cef_host/CMakeLists.txt and fetch_cef.ps1:
#   (1) env CEF_ROOT, (2) %LOCALAPPDATA%/flutter_cef/<dist>. If neither exists,
#   ask fetch_cef.ps1 to resolve/print it; still unresolved -> fail configure.
if(DEFINED ENV{CEF_ROOT})
  set(FLUTTER_CEF_CEF_ROOT "$ENV{CEF_ROOT}")
elseif(EXISTS "$ENV{LOCALAPPDATA}/flutter_cef/${CEF_DIST_NAME}/cmake")
  set(FLUTTER_CEF_CEF_ROOT "$ENV{LOCALAPPDATA}/flutter_cef/${CEF_DIST_NAME}")
else()
  # Last resort: let fetch_cef.ps1 resolve (and, in a future P11, download) it.
  execute_process(
    COMMAND powershell -NoProfile -ExecutionPolicy Bypass -File
            "${CEF_HOST_SRC_DIR}/fetch_cef.ps1"
    OUTPUT_VARIABLE FLUTTER_CEF_CEF_ROOT
    OUTPUT_STRIP_TRAILING_WHITESPACE
    RESULT_VARIABLE _fetch_cef_result)
  if(NOT _fetch_cef_result EQUAL 0)
    set(FLUTTER_CEF_CEF_ROOT "")
  endif()
endif()
# Normalize to forward slashes: %LOCALAPPDATA% (and env CEF_ROOT) come back with
# backslashes, which CMake reads as escape sequences (\U -> CMP0010) in the
# bundled-library string list.
file(TO_CMAKE_PATH "${FLUTTER_CEF_CEF_ROOT}" FLUTTER_CEF_CEF_ROOT)

if(NOT EXISTS "${FLUTTER_CEF_CEF_ROOT}/cmake")
  message(FATAL_ERROR
    "flutter_cef_windows: CEF distribution not found. Set the CEF_ROOT env var "
    "to an extracted '${CEF_DIST_NAME}', or run "
    "native/cef_host/fetch_cef.ps1 to stage it under "
    "%LOCALAPPDATA%/flutter_cef/. (Resolved candidate: "
    "'${FLUTTER_CEF_CEF_ROOT}'.)")
endif()
message(STATUS "flutter_cef_windows: resolved CEF_ROOT = ${FLUTTER_CEF_CEF_ROOT}")

# CEF is guaranteed present at this point (resolution FATALs otherwise).
# Invoke build_cef_host.bat DIRECTLY (no explicit `cmd /c`) so paths with
# spaces survive: Ninja already wraps the whole command line in `cmd /c "..."`,
# so a bare `"C:\Users\a b\repo\build_cef_host.bat" "arg" "arg"` becomes the
# safe `cmd /c ""...bat" "arg" "arg""` outer-quoted form (cmd strips only the
# outer pair). An extra explicit `cmd /c` here would nest a second cmd whose
# leading-quote stripping mangles a "C:\Users\a b\..." path.
file(TO_NATIVE_PATH "${CEF_HOST_SRC_DIR}/build_cef_host.bat" _cef_host_bat)
file(TO_NATIVE_PATH "${CEF_HOST_BUILD_DIR}" _cef_host_build_native)
file(TO_NATIVE_PATH "${CEF_HOST_DIST_DIR}" _cef_host_dist_native)
add_custom_command(
  OUTPUT
    "${CEF_HOST_DIST_DIR}/cef_host.dll"
    "${CEF_HOST_DIST_DIR}/cef_host.exe"
  COMMAND "${_cef_host_bat}" "${_cef_host_build_native}" "${_cef_host_dist_native}"
  DEPENDS
    "${CEF_HOST_SRC_DIR}/cef_host_win.cc"
    "${CEF_HOST_SRC_DIR}/cef_host_protocol.h"
    "${CEF_HOST_SRC_DIR}/CMakeLists.txt"
    "${CEF_HOST_SRC_DIR}/build_cef_host.bat"
  COMMENT "Building cef_host (CEF OSR host) via build_cef_host.bat"
  VERBATIM
)
add_custom_target(flutter_cef_windows_host ALL
  DEPENDS
    "${CEF_HOST_DIST_DIR}/cef_host.dll"
    "${CEF_HOST_DIST_DIR}/cef_host.exe"
)
add_dependencies(${PLUGIN_NAME} flutter_cef_windows_host)

# Files the app needs beside its exe: the host pair + the CEF runtime.
# (Flat CEF layout on Windows; libcef.dll etc. resolve from the exe dir.
# Set from what cef_leg (S1) needed to run windowless+GPU.)
set(flutter_cef_windows_bundled_libraries
  "${CEF_HOST_DIST_DIR}/cef_host.exe"
  "${CEF_HOST_DIST_DIR}/cef_host.dll"
  "${FLUTTER_CEF_CEF_ROOT}/Release/libcef.dll"
  "${FLUTTER_CEF_CEF_ROOT}/Release/chrome_elf.dll"
  "${FLUTTER_CEF_CEF_ROOT}/Release/d3dcompiler_47.dll"
  "${FLUTTER_CEF_CEF_ROOT}/Release/libEGL.dll"
  "${FLUTTER_CEF_CEF_ROOT}/Release/libGLESv2.dll"
  "${FLUTTER_CEF_CEF_ROOT}/Release/dxcompiler.dll"
  "${FLUTTER_CEF_CEF_ROOT}/Release/dxil.dll"
  "${FLUTTER_CEF_CEF_ROOT}/Release/vk_swiftshader.dll"
  "${FLUTTER_CEF_CEF_ROOT}/Release/vk_swiftshader_icd.json"
  "${FLUTTER_CEF_CEF_ROOT}/Release/vulkan-1.dll"
  "${FLUTTER_CEF_CEF_ROOT}/Release/v8_context_snapshot.bin"
  "${FLUTTER_CEF_CEF_ROOT}/Resources/icudtl.dat"
  "${FLUTTER_CEF_CEF_ROOT}/Resources/resources.pak"
  "${FLUTTER_CEF_CEF_ROOT}/Resources/chrome_100_percent.pak"
  "${FLUTTER_CEF_CEF_ROOT}/Resources/chrome_200_percent.pak"
  PARENT_SCOPE
)

# Locales must live in <exe dir>/locales/, which the flat bundled_libraries
# list can't express. Use the exe dir directly via the same generator
# expression the app template's BUILD_BUNDLE_DIR uses (a relative
# DESTINATION would resolve against CMAKE_INSTALL_PREFIX, whose genex is
# NOT re-evaluated inside this subdirectory's install script). BINARY_NAME
# is set by the app-level CMakeLists before generated_plugins.cmake runs.
# TODO(builder-plugin): ship the full locale set (or make it configurable)
# once the slice is green — en-US is the required minimum.
install(FILES "${FLUTTER_CEF_CEF_ROOT}/Resources/locales/en-US.pak"
        DESTINATION "$<TARGET_FILE_DIR:${BINARY_NAME}>/locales"
        COMPONENT Runtime)
