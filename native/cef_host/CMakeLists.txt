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
set(USE_SANDBOX OFF CACHE BOOL "" FORCE)  # runtime no_sandbox / single-process
find_package(CEF REQUIRED)
add_subdirectory("${CEF_ROOT}/libcef_dll" libcef_dll_wrapper)

# Ad-hoc by default; the consuming app re-signs cef_host.app with its own
# identity. Pass -DCODESIGN_ID=<hash|name> to sign here (e.g. standalone use).
if(NOT DEFINED CODESIGN_ID)
  set(CODESIGN_ID "-")
endif()

# cef_host: a .app bundle (CEF needs a proper bundle; a plain exe trips an early
# Chromium check). The CEF framework lives at its own Contents/Frameworks so
# CefScopedLibraryLoader::LoadInMain resolves <exe>/../Frameworks.
add_executable(cef_host MACOSX_BUNDLE main.mm)
SET_EXECUTABLE_TARGET_PROPERTIES(cef_host)
set_target_properties(cef_host PROPERTIES
  MACOSX_BUNDLE_INFO_PLIST "${CMAKE_CURRENT_SOURCE_DIR}/Info.plist")
add_dependencies(cef_host libcef_dll_wrapper)
target_link_libraries(cef_host libcef_dll_wrapper ${CEF_STANDARD_LIBS}
  "-framework IOSurface")

set(APP_DIR "${CMAKE_CURRENT_BINARY_DIR}/cef_host.app")
COPY_MAC_FRAMEWORK(cef_host "${CEF_BINARY_DIR}" "${APP_DIR}")
add_custom_command(TARGET cef_host POST_BUILD
  COMMAND codesign --force --deep --sign ${CODESIGN_ID}
    "${APP_DIR}/Contents/Frameworks/Chromium Embedded Framework.framework"
  COMMAND codesign --force --sign ${CODESIGN_ID}
    --entitlements "${CMAKE_CURRENT_SOURCE_DIR}/entitlements.plist" "${APP_DIR}"
  VERBATIM)
