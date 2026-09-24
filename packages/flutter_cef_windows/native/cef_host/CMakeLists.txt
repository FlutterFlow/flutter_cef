# cef_host (Windows) — standalone CEF OSR host, built OUTSIDE the Flutter
# plugin build (driven by build_cef_host.bat, which the plugin CMakeLists
# invokes via add_custom_command).
#
# Ship shape: the host is a client
# DLL `cef_host.dll` exporting RunConsoleMain, loaded by CEF's prebuilt
# bootstrap. We ship bootstrapc.exe RENAMED to cef_host.exe beside the DLL (the
# rename selects the module — no --module flag needed; clean Task Manager
# names). The bootstrap owns the Chromium sandbox: it hands RunConsoleMain the
# sandbox_info the host forwards to CEF.
#
# CEF's own cmake config (find_package(CEF)) drives compiler flags (/MT):
# this target never links against Flutter, so the plugin's /MD rule (the CEF
# wrapper built against Flutter's runtime) does not apply here. The client
# DLL must link delayimp.lib (CEF's /DELAYLOAD list needs it).

cmake_minimum_required(VERSION 3.21)
project(cef_host_win LANGUAGES CXX)

# The pin and CEF_ROOT resolution are shared with ../../windows/CMakeLists.txt
# (cef_pin.cmake; the pin itself is cef_pin.txt). Order: -DCEF_ROOT= > env
# CEF_ROOT > %LOCALAPPDATA%/flutter_cef/<dist> > fetch_cef.ps1, and the result
# must be the pinned version.
include("${CMAKE_CURRENT_SOURCE_DIR}/cef_pin.cmake")
set(_explicit_cef_root "")
if(DEFINED CEF_ROOT)
  set(_explicit_cef_root "${CEF_ROOT}")
endif()
flutter_cef_resolve_cef_root(CEF_ROOT "${_explicit_cef_root}")
message(STATUS "cef_host: resolved CEF_ROOT = ${CEF_ROOT}")
list(APPEND CMAKE_MODULE_PATH "${CEF_ROOT}/cmake")
find_package(CEF REQUIRED)

# libcef_dll_wrapper: reuse a prebuilt (/MT, matching CEF's default flags)
# when provided, else build it in-tree. Resolution mirrors the CEF_ROOT
# env-first chain: -DCEF_WRAPPER_LIB=<path/to/.lib> > env CEF_WRAPPER_LIB.
if(NOT DEFINED CEF_WRAPPER_LIB AND DEFINED ENV{CEF_WRAPPER_LIB})
  set(CEF_WRAPPER_LIB "$ENV{CEF_WRAPPER_LIB}")
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
  cef_host_policy.h
  cef_host_protocol.h
  cef_host_opcodes.h
  document_start.h
)
SET_LIBRARY_TARGET_PROPERTIES(cef_host)
# NOMINMAX: cef_types_win.h pulls windows.h; without it std::min/max -> C2589.
# CEF's own configs may set it too — harmless twice.
target_compile_definitions(cef_host PRIVATE NOMINMAX)
target_include_directories(cef_host PRIVATE ${CEF_ROOT})
target_link_libraries(cef_host
  ${WRAPPER_LIB}
  "${CEF_ROOT}/Release/libcef.lib"
  delayimp.lib
  # The OnAcceleratedPaint NT->legacy bridge blit (the GPU pixel path).
  d3d11.lib
  dxgi.lib
)

# ---- pipe_probe: standalone IPC gate test (native/cef_host/test/) ----
# Plain Win32 + cef_host_protocol.h, NO CEF link. Acts as the plugin side of
# the named pipe: spawns cef_host.exe, drives kOpCreateBrowser/kOpNavigate/
# kOpShutdown and asserts kOpReady/kOpCreated/kOpPresent/events. Built on
# demand (`--target pipe_probe`; the windows-build CI job does) —
# build_cef_host.bat builds only cef_host, so plugin builds never compile it.
add_executable(pipe_probe EXCLUDE_FROM_ALL test/pipe_probe.cc)
target_include_directories(pipe_probe PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}")
target_compile_definitions(pipe_probe PRIVATE NOMINMAX)

# Stage the ship pair beside the build output: cef_host.dll + cef_host.exe
# (bootstrapc.exe renamed).
add_custom_command(TARGET cef_host POST_BUILD
  COMMAND ${CMAKE_COMMAND} -E copy_if_different
          "${CEF_ROOT}/Release/bootstrapc.exe"
          "$<TARGET_FILE_DIR:cef_host>/cef_host.exe"
  COMMENT "Staging bootstrapc.exe as cef_host.exe beside cef_host.dll"
)
