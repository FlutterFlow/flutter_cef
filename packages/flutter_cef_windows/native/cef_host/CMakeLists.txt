# cef_host (Windows) — standalone CEF OSR host, built OUTSIDE the Flutter
# plugin build (driven by build_cef_host.bat, which the plugin CMakeLists
# invokes via add_custom_command).
#
# Ship shape (LAW 8, S2): the host is a client DLL `cef_host.dll` exporting
# RunConsoleMain, loaded by CEF's prebuilt bootstrap. We ship bootstrapc.exe
# RENAMED to cef_host.exe beside the DLL (the rename selects the module —
# no --module flag needed; clean Task Manager names). The slice runs
# no_sandbox=1 (sandbox is P11), but the bootstrap layout is the shipping
# contract from day one so P11 is a settings flip, not a restructure.
#
# CEF's own cmake config (find_package(CEF)) drives compiler flags (/MT):
# this target never links against Flutter, so the plugin's /MD rule (S6a)
# does not apply here. The client DLL must link delayimp.lib (CEF's
# /DELAYLOAD list — SPIKES.md S2).

cmake_minimum_required(VERSION 3.21)
project(cef_host_win LANGUAGES CXX)

# CEF_ROOT: -DCEF_ROOT=... > env CEF_ROOT > the dev-box spike extraction.
if(NOT DEFINED CEF_ROOT)
  if(DEFINED ENV{CEF_ROOT})
    set(CEF_ROOT "$ENV{CEF_ROOT}")
  else()
    set(CEF_ROOT "C:/dev/flutter_cef_spikes/cef/cef_binary_144.0.27+g3fae261+chromium-144.0.7559.254_windows64_minimal")
  endif()
endif()
if(NOT EXISTS "${CEF_ROOT}/cmake")
  message(FATAL_ERROR
    "CEF_ROOT not found at '${CEF_ROOT}'. Run fetch_cef.ps1 or set CEF_ROOT "
    "(env or -DCEF_ROOT=) to the extracted cef_binary_144.0.27 windows64_minimal dir.")
endif()
list(APPEND CMAKE_MODULE_PATH "${CEF_ROOT}/cmake")
find_package(CEF REQUIRED)

# libcef_dll_wrapper: reuse a prebuilt (/MT, matching CEF's default flags)
# when provided, else build it in-tree. -DCEF_WRAPPER_LIB=<path/to/.lib>.
if(NOT DEFINED CEF_WRAPPER_LIB)
  set(_default_prebuilt
      "C:/dev/flutter_cef_spikes/cefbuild/libcef_dll_wrapper/libcef_dll_wrapper.lib")
  if(EXISTS "${_default_prebuilt}")
    set(CEF_WRAPPER_LIB "${_default_prebuilt}")
  endif()
endif()
if(DEFINED CEF_WRAPPER_LIB AND EXISTS "${CEF_WRAPPER_LIB}")
  set(WRAPPER_LIB "${CEF_WRAPPER_LIB}")
else()
  add_subdirectory("${CEF_LIBCEF_DLL_WRAPPER_PATH}" libcef_dll_wrapper)
  set(WRAPPER_LIB libcef_dll_wrapper)
endif()

# The client DLL (loaded by the renamed bootstrapc.exe).
add_library(cef_host SHARED
  cef_host_win.cc
  cef_host_protocol.h
)
SET_LIBRARY_TARGET_PROPERTIES(cef_host)
# NOMINMAX: cef_types_win.h pulls windows.h; without it std::min/max -> C2589
# (S6a). CEF's own configs may set it too — harmless twice.
target_compile_definitions(cef_host PRIVATE NOMINMAX)
target_include_directories(cef_host PRIVATE ${CEF_ROOT})
target_link_libraries(cef_host
  ${WRAPPER_LIB}
  "${CEF_ROOT}/Release/libcef.lib"
  delayimp.lib
  # The OnAcceleratedPaint NT->legacy bridge blit (S1 pixel path).
  d3d11.lib
  dxgi.lib
)

# ---- pipe_probe: standalone IPC gate test (native/cef_host/test/) ----
# Plain Win32 + cef_host_protocol.h, NO CEF link. Acts as the plugin side of
# the named pipe: spawns cef_host.exe, drives kOpCreateBrowser/kOpNavigate/
# kOpShutdown and asserts kOpReady/kOpCreated/kOpPresent/events. Built on
# demand (`--target pipe_probe`); build_cef_host.bat builds only cef_host, so
# plugin builds never compile this.
add_executable(pipe_probe EXCLUDE_FROM_ALL test/pipe_probe.cc)
target_include_directories(pipe_probe PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}")
target_compile_definitions(pipe_probe PRIVATE NOMINMAX)

# Stage the ship pair beside the build output: cef_host.dll + cef_host.exe
# (bootstrapc.exe renamed — LAW 8).
add_custom_command(TARGET cef_host POST_BUILD
  COMMAND ${CMAKE_COMMAND} -E copy_if_different
          "${CEF_ROOT}/Release/bootstrapc.exe"
          "$<TARGET_FILE_DIR:cef_host>/cef_host.exe"
  COMMENT "Staging bootstrapc.exe as cef_host.exe beside cef_host.dll"
)
