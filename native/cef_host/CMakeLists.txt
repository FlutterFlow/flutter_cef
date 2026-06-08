cmake_minimum_required(VERSION 3.21)
project(cef_host CXX OBJCXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_OBJCXX_STANDARD 17)

# CEF SDK root — fetched by native/build_cef_host.sh.
if(NOT DEFINED CEF_ROOT)
  message(FATAL_ERROR "CEF_ROOT not set — run native/build_cef_host.sh (it fetches CEF).")
endif()
set(CMAKE_MODULE_PATH "${CEF_ROOT}/cmake")
set(USE_SANDBOX OFF CACHE BOOL "" FORCE)  # runtime no_sandbox (non-sandboxed host)
find_package(CEF REQUIRED)
add_subdirectory("${CEF_ROOT}/libcef_dll" libcef_dll_wrapper)

# Default ad-hoc. Pass a real Apple Development / Developer ID identity via
# -DCODESIGN_ID=<hash|name> (required for multi-process: the Mach-port peer
# validator wants a hardened-runtime signature on every nested process).
if(NOT DEFINED CODESIGN_ID)
  set(CODESIGN_ID "-")
endif()
set(ENT "${CMAKE_CURRENT_SOURCE_DIR}/entitlements.plist")

# Multi-process is the DEFAULT: it spawns the CEF helper subprocesses (GPU/Viz +
# OnAcceleratedPaint shared-IOSurface render) and isolates renderer/utility
# crashes, so heavy SPAs (e.g. Google sign-in) render and survive — single
# process CHECK-crashes on them. Chromium 144's Mach-port peer validation is
# disabled for the process tree via an env var in main.mm (works ad-hoc, no
# notarization); the production-hardening is correct inside-out Developer-ID
# signing so that env var can be dropped. Set -DCEF_MULTI_PROCESS=OFF for the
# simpler single-process build (first-party content only).
option(CEF_MULTI_PROCESS "Spawn CEF helper subprocesses (vs --single-process)" ON)

# cef_host: the BROWSER process. A .app bundle (CEF needs a real bundle). The CEF
# framework (and, in multi-process, the helper apps) live in Contents/Frameworks.
add_executable(cef_host MACOSX_BUNDLE main.mm)
SET_EXECUTABLE_TARGET_PROPERTIES(cef_host)
set_target_properties(cef_host PROPERTIES
  MACOSX_BUNDLE_INFO_PLIST "${CMAKE_CURRENT_SOURCE_DIR}/Info.plist")
add_dependencies(cef_host libcef_dll_wrapper)
target_link_libraries(cef_host libcef_dll_wrapper ${CEF_STANDARD_LIBS}
  "-framework IOSurface" "-framework Metal" "-framework CoreVideo")
if(CEF_MULTI_PROCESS)
  target_compile_definitions(cef_host PRIVATE CEF_HOST_MULTIPROCESS)
endif()

set(APP_DIR "${CMAKE_CURRENT_BINARY_DIR}/cef_host.app")

# In multi-process, build the CEF helper subprocess, bundled once per child type
# (base + GPU/Renderer/Plugin/Alerts) with distinct bundle ids. Same tiny
# process_helper binary; CEF dispatches on --type=.
set(_helper_apps "")
if(CEF_MULTI_PROCESS)
  foreach(_suffixes ${CEF_HELPER_APP_SUFFIXES})
    string(REPLACE ":" ";" _suffixes "${_suffixes}")
    list(GET _suffixes 0 _name_suffix)
    list(GET _suffixes 1 _target_suffix)
    list(GET _suffixes 2 _plist_suffix)
    set(_helper_target "cef_host_helper${_target_suffix}")
    set(_helper_output_name "cef_host Helper${_name_suffix}")
    set(CEF_HELPER_NAME "${_helper_output_name}")
    set(CEF_HELPER_BUNDLE_ID "dev.flutter_cef.cef_host.helper${_plist_suffix}")
    set(_helper_plist "${CMAKE_CURRENT_BINARY_DIR}/helper${_plist_suffix}-Info.plist")
    configure_file("${CMAKE_CURRENT_SOURCE_DIR}/helper-Info.plist.in"
      "${_helper_plist}" @ONLY)
    add_executable(${_helper_target} MACOSX_BUNDLE process_helper.mm)
    SET_EXECUTABLE_TARGET_PROPERTIES(${_helper_target})
    add_dependencies(${_helper_target} libcef_dll_wrapper)
    target_link_libraries(${_helper_target} libcef_dll_wrapper ${CEF_STANDARD_LIBS})
    set_target_properties(${_helper_target} PROPERTIES
      MACOSX_BUNDLE_INFO_PLIST "${_helper_plist}"
      OUTPUT_NAME "${_helper_output_name}")
    add_dependencies(cef_host ${_helper_target})
    list(APPEND _helper_apps "${CMAKE_CURRENT_BINARY_DIR}/${_helper_output_name}.app")
  endforeach()
endif()

# Assemble cef_host.app: CEF framework + (multi-process) helpers, then sign
# inside-out. CEF's copied framework needs a resource seal, so sign it the
# versioned way (inner dylibs -> Versions/A) — NOT --deep on the root, which
# breaks the Versions/ seal on Xcode 26.
COPY_MAC_FRAMEWORK(cef_host "${CEF_BINARY_DIR}" "${APP_DIR}")
foreach(_happ ${_helper_apps})
  get_filename_component(_hname "${_happ}" NAME)
  add_custom_command(TARGET cef_host POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E copy_directory
      "${_happ}" "${APP_DIR}/Contents/Frameworks/${_hname}"
    VERBATIM)
endforeach()
set(_sign_helpers "")
if(CEF_MULTI_PROCESS)
  set(_sign_helpers "for h in '${APP_DIR}'/Contents/Frameworks/*Helper*.app; do codesign --force --options runtime --timestamp=none --entitlements '${ENT}' --sign '${CODESIGN_ID}' \"$h\"; done;")
endif()
add_custom_command(TARGET cef_host POST_BUILD COMMAND /bin/sh -c
  "set -e; \
   FW='${APP_DIR}/Contents/Frameworks/Chromium Embedded Framework.framework'; \
   codesign --force --timestamp=none --sign '${CODESIGN_ID}' \"$FW/Versions/A/Libraries/\"*.dylib; \
   codesign --force --timestamp=none --sign '${CODESIGN_ID}' \"$FW/Versions/A\"; \
   ${_sign_helpers} \
   codesign --force --options runtime --timestamp=none --entitlements '${ENT}' --sign '${CODESIGN_ID}' '${APP_DIR}'"
  VERBATIM)
