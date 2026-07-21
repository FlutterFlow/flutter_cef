@echo off
rem build_cef_host.bat — build cef_host.dll + stage cef_host.exe (renamed
rem bootstrapc.exe, LAW 8). Invoked standalone by developers AND from the
rem plugin's windows/CMakeLists.txt add_custom_command during
rem `flutter build windows`.
rem
rem Usage: build_cef_host.bat [BUILD_DIR] [OUT_DIR]
rem   BUILD_DIR  cmake binary dir     (default: %~dp0build)
rem   OUT_DIR    where cef_host.dll + cef_host.exe land (default: BUILD_DIR)
rem Env overrides:
rem   CEF_ROOT         extracted cef_binary_144.0.27 windows64_minimal dir
rem   CEF_WRAPPER_LIB  prebuilt /MT libcef_dll_wrapper.lib to reuse
rem   VSINSTALLDIR     Visual Studio install root (skips the vswhere lookup)
rem   CMAKE            cmake.exe to use (default: VS-bundled, else on PATH)
rem   NINJA            ninja.exe to use (default: VS-bundled, else on PATH)
rem
rem Deterministic + incremental-safe: configure only when build.ninja is
rem missing; ninja no-ops when nothing changed.

setlocal enabledelayedexpansion
set "SRC_DIR=%~dp0"
if "%~1"=="" (set "BUILD_DIR=%SRC_DIR%build") else (set "BUILD_DIR=%~1")
if "%~2"=="" (set "OUT_DIR=%BUILD_DIR%") else (set "OUT_DIR=%~2")

rem --- MSVC toolchain: locate Visual Studio via vswhere (honor VSINSTALLDIR).
rem No hardcoded edition/year — any install with the VC++ x64 tools works.
if defined VSINSTALLDIR (
  set "VS_INSTALL=%VSINSTALLDIR%"
) else (
  set "VSWHERE=%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe"
  if not exist "!VSWHERE!" (
    echo build_cef_host: vswhere.exe not found - install Visual Studio or set VSINSTALLDIR 1>&2
    exit /b 1
  )
  for /f "usebackq tokens=*" %%i in (`"!VSWHERE!" -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath`) do set "VS_INSTALL=%%i"
)
if not defined VS_INSTALL (
  echo build_cef_host: no Visual Studio with the VC++ x64 tools found - set VSINSTALLDIR 1>&2
  exit /b 1
)
call "!VS_INSTALL!\VC\Auxiliary\Build\vcvars64.bat" >nul
if errorlevel 1 exit /b 1

rem --- cmake: honor a pre-set CMAKE, else the VS-bundled copy, else PATH.
if not defined CMAKE (
  set "CMAKE=!VS_INSTALL!\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe"
  if not exist "!CMAKE!" set "CMAKE=cmake"
)

rem --- ninja: honor a pre-set NINJA (pass it to cmake), else prepend the
rem VS-bundled ninja dir when present, else rely on ninja on PATH.
set "MAKE_PROG_ARG="
if defined NINJA (
  set MAKE_PROG_ARG=-DCMAKE_MAKE_PROGRAM="!NINJA!"
) else (
  set "NINJA_DIR=!VS_INSTALL!\Common7\IDE\CommonExtensions\Microsoft\CMake\Ninja"
  if exist "!NINJA_DIR!\ninja.exe" set "PATH=!NINJA_DIR!;%PATH%"
)

if not exist "%BUILD_DIR%\build.ninja" (
  "!CMAKE!" -G Ninja -DCMAKE_BUILD_TYPE=Release !MAKE_PROG_ARG! -S "%SRC_DIR%." -B "%BUILD_DIR%"
  if errorlevel 1 exit /b 2
)
"!CMAKE!" --build "%BUILD_DIR%" --target cef_host
if errorlevel 1 exit /b 3

if /i not "%OUT_DIR%"=="%BUILD_DIR%" (
  if not exist "%OUT_DIR%" mkdir "%OUT_DIR%"
  copy /y "%BUILD_DIR%\cef_host.dll" "%OUT_DIR%\cef_host.dll" >nul
  if errorlevel 1 exit /b 4
  copy /y "%BUILD_DIR%\cef_host.exe" "%OUT_DIR%\cef_host.exe" >nul
  if errorlevel 1 exit /b 5
)
echo cef_host staged: %OUT_DIR%\cef_host.dll + cef_host.exe
exit /b 0
