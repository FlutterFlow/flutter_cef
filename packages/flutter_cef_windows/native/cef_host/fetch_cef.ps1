# fetch_cef.ps1 - resolve (and, when missing, DOWNLOAD) the root of the pinned
# CEF binary distribution for the Windows cef_host build. Prints the resolved
# root on stdout (Write-Output) so windows/CMakeLists.txt and
# native/cef_host/CMakeLists.txt can capture it via execute_process; all
# progress goes to Info so it never pollutes the captured value.
#
# Resolution order (shared with both CMakeLists): env CEF_ROOT, then
# %LOCALAPPDATA%/flutter_cef/<dist>. If neither exists, download the pinned
# tarball from cef-builds.spotifycdn.com, verify it against the SHA-1 pinned
# below (fail closed), extract with native tar.exe (bsdtar handles .tar.bz2,
# SPIKES.md S6), and cache it under %LOCALAPPDATA%/flutter_cef for later builds.

$ErrorActionPreference = 'Stop'

# Progress goes to STDERR — Info lands on STDOUT under `powershell -File`,
# which would pollute the resolved path CMake captures via OUTPUT_VARIABLE.
# ONLY the final Write-Output (the CEF root) may reach stdout.
function Info($m) { [Console]::Error.WriteLine($m) }

# The pin (matches build_cef_host.sh:17 / SPIKES.md header).
$CefVersion = '144.0.27+g3fae261+chromium-144.0.7559.254'
$CefDistName = "cef_binary_${CefVersion}_windows64_minimal"
# SHA-1 of that tarball, from the CEF builds index (index.json and the .sha1
# beside the tarball agree). Pinned here, not fetched from the host that
# serves the tarball, so a tampered mirror can't vouch for itself. Update it
# with $CefVersion.
$CefDistSha1 = '4bdedf91fb973c99570728d228098638f004c5e9'

$Candidates = @()
if ($env:CEF_ROOT) { $Candidates += $env:CEF_ROOT }
$Candidates += (Join-Path $env:LOCALAPPDATA "flutter_cef\$CefDistName")

foreach ($root in $Candidates) {
  if (Test-Path (Join-Path $root 'cmake')) {
    Info "fetch_cef: CEF_ROOT resolved: $root"
    Write-Output $root
    exit 0
  }
}

# Not cached: download + verify + extract into the cache.
$CacheRoot = Join-Path $env:LOCALAPPDATA 'flutter_cef'
$Dest = Join-Path $CacheRoot $CefDistName
New-Item -ItemType Directory -Force $CacheRoot | Out-Null

$enc = [uri]::EscapeDataString("$CefDistName.tar.bz2")
$url = "https://cef-builds.spotifycdn.com/$enc"
$tarball = Join-Path $CacheRoot "$CefDistName.tar.bz2"

Info "fetch_cef: CEF not cached; downloading $url"
& curl.exe -fL --retry 3 -o $tarball $url
if ($LASTEXITCODE -ne 0) {
  Write-Error "fetch_cef: download failed"
  exit 1
}

# Fail-closed SHA-1 check against the pinned digest.
$actual = (Get-FileHash -Algorithm SHA1 -Path $tarball).Hash.ToLower()
if ($actual -ne $CefDistSha1) {
  Remove-Item $tarball -Force -ErrorAction SilentlyContinue
  Write-Error "fetch_cef: SHA-1 mismatch (got $actual, pinned $CefDistSha1)"
  exit 1
}
Info "fetch_cef: SHA-1 verified $actual"

# Extract into a temp dir, then move into place, so a partial extract is never
# resolved by a concurrent build.
$tmp = Join-Path $CacheRoot ".extract-$PID"
if (Test-Path $tmp) { Remove-Item -Recurse -Force $tmp }
New-Item -ItemType Directory -Force $tmp | Out-Null
Info "fetch_cef: extracting"
# Use the Windows system bsdtar by FULL PATH. A bare `tar` on a CI runner
# resolves to Git's bundled MSYS GNU tar, which reads "C:\...tarball" as a
# host:path remote spec ("Cannot connect to C:"). System32\tar.exe is libarchive
# (bsdtar), handles .tar.bz2 and drive-letter paths natively (SPIKES.md S6).
$SystemTar = Join-Path $env:SystemRoot 'System32\tar.exe'
if (-not (Test-Path $SystemTar)) { $SystemTar = 'tar.exe' }
& $SystemTar -xf $tarball -C $tmp
if ($LASTEXITCODE -ne 0) {
  Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
  Write-Error "fetch_cef: tar extract failed"
  exit 1
}
$extracted = Join-Path $tmp $CefDistName
if (-not (Test-Path (Join-Path $extracted 'cmake'))) {
  Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
  Write-Error "fetch_cef: extracted tree missing cmake"
  exit 1
}
if (Test-Path $Dest) { Remove-Item -Recurse -Force $Dest -ErrorAction SilentlyContinue }
Move-Item $extracted $Dest
Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
Remove-Item $tarball -Force -ErrorAction SilentlyContinue

if (Test-Path (Join-Path $Dest 'cmake')) {
  Info "fetch_cef: CEF_ROOT resolved (downloaded): $Dest"
  Write-Output $Dest
  exit 0
}
Write-Error "fetch_cef: post-download resolve failed"
exit 1
