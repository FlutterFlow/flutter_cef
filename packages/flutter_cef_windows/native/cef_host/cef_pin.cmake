# The Windows CEF pin and CEF_ROOT resolution, shared by the plugin's
# windows/CMakeLists.txt and native/cef_host/CMakeLists.txt so the two can't
# drift. The pin itself is cef_pin.txt beside this file.
#
# Sets FLUTTER_CEF_CEF_VERSION, FLUTTER_CEF_CEF_SHA256 and
# FLUTTER_CEF_DIST_NAME, and defines flutter_cef_resolve_cef_root().

set(FLUTTER_CEF_PIN_DIR "${CMAKE_CURRENT_LIST_DIR}")
set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS
             "${FLUTTER_CEF_PIN_DIR}/cef_pin.txt")
file(STRINGS "${FLUTTER_CEF_PIN_DIR}/cef_pin.txt" _flutter_cef_pin_lines
     REGEX "^CEF_[A-Z0-9_]+=")
foreach(_line IN LISTS _flutter_cef_pin_lines)
  string(REGEX REPLACE "^(CEF_[A-Z0-9_]+)=.*$" "\\1" _key "${_line}")
  string(REGEX REPLACE "^CEF_[A-Z0-9_]+=(.*)$" "\\1" _value "${_line}")
  string(STRIP "${_value}" _value)
  set(FLUTTER_CEF_${_key} "${_value}")
endforeach()
if(NOT FLUTTER_CEF_CEF_VERSION OR NOT FLUTTER_CEF_CEF_SHA256)
  message(FATAL_ERROR
    "flutter_cef: ${FLUTTER_CEF_PIN_DIR}/cef_pin.txt must set CEF_VERSION "
    "and CEF_SHA256.")
endif()
set(FLUTTER_CEF_DIST_NAME
    "cef_binary_${FLUTTER_CEF_CEF_VERSION}_windows64_minimal")

# flutter_cef_resolve_cef_root(<out_var> <explicit_root>)
#
# Resolution order: <explicit_root> (e.g. -DCEF_ROOT=) > env CEF_ROOT >
# %LOCALAPPDATA%/flutter_cef/<dist>; if none exists, fetch_cef.ps1 downloads
# and verifies the pinned tarball. Fails configure when nothing resolves, or
# when the resolved tree's include/cef_version.h is not the pinned version:
# building against a different CEF would silently ship it.
function(flutter_cef_resolve_cef_root out_var explicit_root)
  if(NOT "${explicit_root}" STREQUAL "")
    set(_root "${explicit_root}")
  elseif(DEFINED ENV{CEF_ROOT})
    set(_root "$ENV{CEF_ROOT}")
  elseif(EXISTS "$ENV{LOCALAPPDATA}/flutter_cef/${FLUTTER_CEF_DIST_NAME}/cmake")
    set(_root "$ENV{LOCALAPPDATA}/flutter_cef/${FLUTTER_CEF_DIST_NAME}")
  else()
    execute_process(
      COMMAND powershell -NoProfile -ExecutionPolicy Bypass -File
              "${FLUTTER_CEF_PIN_DIR}/fetch_cef.ps1"
      OUTPUT_VARIABLE _root
      OUTPUT_STRIP_TRAILING_WHITESPACE
      RESULT_VARIABLE _fetch_result)
    if(NOT _fetch_result EQUAL 0)
      set(_root "")
    endif()
  endif()
  # Normalize to forward slashes: %LOCALAPPDATA% (and env CEF_ROOT) come back
  # with backslashes, which CMake reads as escape sequences in later strings.
  file(TO_CMAKE_PATH "${_root}" _root)
  if(NOT EXISTS "${_root}/cmake")
    message(FATAL_ERROR
      "flutter_cef: CEF distribution not found (resolved '${_root}'). Run "
      "native/cef_host/fetch_cef.ps1 to stage '${FLUTTER_CEF_DIST_NAME}' under "
      "%LOCALAPPDATA%/flutter_cef/, or set CEF_ROOT (env or -DCEF_ROOT=) to an "
      "extracted copy.")
  endif()
  set(_version_h "${_root}/include/cef_version.h")
  set(_found "")
  if(EXISTS "${_version_h}")
    file(STRINGS "${_version_h}" _define REGEX "^#define CEF_VERSION \"")
    string(REGEX REPLACE "^#define CEF_VERSION \"([^\"]*)\".*$" "\\1" _found
           "${_define}")
  endif()
  if(NOT _found STREQUAL FLUTTER_CEF_CEF_VERSION)
    message(FATAL_ERROR
      "flutter_cef: CEF at '${_root}' is version '${_found}', but the build "
      "pins '${FLUTTER_CEF_CEF_VERSION}' (native/cef_host/cef_pin.txt). Point "
      "CEF_ROOT at the pinned distribution, or bump the pin.")
  endif()
  set(${out_var} "${_root}" PARENT_SCOPE)
endfunction()
