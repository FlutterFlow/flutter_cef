# fetch_cef.ps1 — resolve and print the root of the pinned CEF binary
# distribution for the Windows cef_host build.
#
# SLICE SKELETON: today this script only VERIFIES an already-extracted
# distribution and prints the resolved root (it does NOT download anything yet).
# TODO(builder-hostmain / P11): real fetch — download the pinned tarball from
# cef-builds.spotifycdn.com, verify its digest fail-closed, extract with
# native tar.exe (bsdtar handles .tar.bz2 — SPIKES.md S6), and cache under
# %LOCALAPPDATA%\flutter_cef with a hash-stamp short-circuit (PLAN §4.6).

$ErrorActionPreference = 'Stop'

# The pin (matches build_cef_host.sh:17 / SPIKES.md header).
$CefVersion = '144.0.27+g3fae261+chromium-144.0.7559.254'
$CefDistName = "cef_binary_${CefVersion}_windows64_minimal"

# Resolution order (shared with windows/CMakeLists.txt and
# native/cef_host/CMakeLists.txt): env CEF_ROOT > %LOCALAPPDATA%/flutter_cef/<dist>.
$Candidates = @()
if ($env:CEF_ROOT) { $Candidates += $env:CEF_ROOT }
$Candidates += (Join-Path $env:LOCALAPPDATA "flutter_cef\$CefDistName")

foreach ($root in $Candidates) {
  if (Test-Path (Join-Path $root 'cmake')) {
    Write-Host "CEF_ROOT resolved: $root"
    Write-Output $root
    exit 0
  }
}

Write-Error @"
CEF distribution '$CefDistName' not found. Checked:
$($Candidates -join "`n")
Either set CEF_ROOT to an extracted copy, or download
https://cef-builds.spotifycdn.com/$([uri]::EscapeDataString($CefDistName)).tar.bz2
and extract it to one of the paths above. (Automated fetch is a P11 TODO.)
"@
exit 1
