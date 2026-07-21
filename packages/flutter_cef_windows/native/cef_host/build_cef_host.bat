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
rem
rem Deterministic + incremental-safe: configure only when build.ninja is
rem missing; ninja no-ops when nothing changed.

setlocal
set SRC_DIR=%~dp0
if "%~1"=="" (set BUILD_DIR=%SRC_DIR%build) else (set BUILD_DIR=%~1)
if "%~2"=="" (set OUT_DIR=%BUILD_DIR%) else (set OUT_DIR=%~2)

rem MSVC env (cmake/ninja ship with VS2022 but are NOT on PATH — see
rem specs/windows-port dev notes).
call "C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvars64.bat" >nul
if errorlevel 1 exit /b 1
set CMAKE="C:\Program Files\Microsoft Visual Studio\2022\Community\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe"
set NINJA_DIR=C:\Program Files\Microsoft Visual Studio\2022\Community\Common7\IDE\CommonExtensions\Microsoft\CMake\Ninja
set PATH=%NINJA_DIR%;%PATH%

if not exist "%BUILD_DIR%\build.ninja" (
  %CMAKE% -G Ninja -DCMAKE_BUILD_TYPE=Release -S "%SRC_DIR%." -B "%BUILD_DIR%"
  if errorlevel 1 exit /b 2
)
%CMAKE% --build "%BUILD_DIR%" --target cef_host
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
