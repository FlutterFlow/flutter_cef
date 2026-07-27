# publish-cef-host.ps1 - CI / maintainer publish of a prebuilt Windows cef_host
# to public GCS, keyed by a content hash of the build inputs. Mirrors the macOS
# packages/flutter_cef_macos/tool/publish-cef-host.sh (+ the Makefile
# publish-cef-host target). Run when native/cef_host or the CEF pin changes so
# consumers FETCH a matching host (fetch_cef_host.ps1) instead of compiling it.
# Idempotent: re-running with an unchanged tree is a no-op.
#
# ---------------------------------------------------------------------------
# SIGNING (STUBBED-BUT-REAL)
# ---------------------------------------------------------------------------
# If FLUTTER_CEF_SIGN_THUMBPRINT is set, signtool signs cef_host.exe +
# cef_host.dll (SHA-256 file digest + RFC3161 timestamp) before packaging, then
# verifies them. Otherwise it prints "signing skipped (no cert; unsigned
# artifact)" and publishes UNSIGNED -- expected today, since the certificate is
# not procured yet. The consumer (fetch_cef_host.ps1) only accepts an unsigned
# host when FLUTTER_CEF_ALLOW_UNSIGNED_HOST=1.
#   FLIP WHEN SIGNING SHIPS: make signing mandatory (fail if
#   FLUTTER_CEF_SIGN_THUMBPRINT is unset) and drop the consumer's unsigned opt-in.
# ---------------------------------------------------------------------------
#
# Requires: gsutil (Google Cloud SDK) authed with object-create on the bucket.
# Env: GCS_BUCKET (default flutterflow-downloads), GCS_PREFIX (default
#   campus_prebuilt_cef_host), FLUTTER_CEF_SIGN_THUMBPRINT, FLUTTER_CEF_SIGN_TIMESTAMP_URL.
#
# STDERR-only progress (Info); no intended stdout value. ASCII-ONLY (PS 5.1).

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function Info($m) { [Console]::Error.WriteLine($m) }
function Fail($m) { Info $m; exit 1 }

# Locate signtool.exe: PATH first, else the newest x64 copy under the Windows SDK.
function Resolve-Signtool {
  $c = Get-Command signtool.exe -ErrorAction SilentlyContinue
  if ($c) { return $c.Source }
  $roots = @("${env:ProgramFiles(x86)}\Windows Kits\10\bin", "$env:ProgramFiles\Windows Kits\10\bin")
  foreach ($r in $roots) {
    if (Test-Path -LiteralPath $r) {
      $hit = Get-ChildItem -LiteralPath $r -Recurse -Filter signtool.exe -ErrorAction SilentlyContinue |
             Where-Object { $_.FullName -match '\\x64\\' } |
             Sort-Object FullName -Descending | Select-Object -First 1
      if ($hit) { return $hit.FullName }
    }
  }
  return $null
}

# Read the CEF version pin ($CefVersion) out of fetch_cef.ps1 for provenance.
function Get-CefVersionPin {
  param([Parameter(Mandatory = $true)][string]$CefHostDir)
  foreach ($ln in (Get-Content -LiteralPath (Join-Path $CefHostDir 'fetch_cef.ps1'))) {
    if ($ln -match "CefVersion\s*=\s*'([^']+)'") { return $Matches[1] }
  }
  return 'unknown'
}

# --- Self-locate. ---
$here = $PSScriptRoot
$pkg = (Resolve-Path -LiteralPath (Join-Path $here '..')).Path
$cefHost = Join-Path $pkg 'native\cef_host'

# --- Guard: gsutil present. ---
if (-not (Get-Command gsutil -ErrorAction SilentlyContinue)) {
  Info "[publish] gsutil not found. Install the Google Cloud SDK, then authenticate:"
  Info "[publish]   https://cloud.google.com/sdk/docs/install"
  Info "[publish]   gcloud auth login   (needs object-create on the target bucket)"
  exit 2
}

# --- Content hash / object key (shared with the consumer). ---
. (Join-Path $here 'cef_host_hash.ps1')
$hash = Get-CefHostInputHash -CefHostDir $cefHost
Info "[publish] cef_host input hash: $hash"

$bucket = if ($env:GCS_BUCKET) { $env:GCS_BUCKET } else { 'flutterflow-downloads' }
$prefix = if ($env:GCS_PREFIX) { $env:GCS_PREFIX } else { 'campus_prebuilt_cef_host' }
$file = 'cef_host-windows-x64.zip'
$dst = "gs://$bucket/$prefix/$hash/$file"

# --- Idempotency: this exact tree is already published -> nothing to do. ---
# NOTE (flip when signing ships): mirror macOS and download + verify the remote
# artifact's Authenticode signature here before trusting the skip, to defeat a
# planted object pre-staged at a future content hash. Stubbed while unsigned.
& gsutil -q stat $dst
if ($LASTEXITCODE -eq 0) {
  Info "[publish] $dst already exists - nothing to do (idempotent skip)."
  exit 0
}

$work = Join-Path ([System.IO.Path]::GetTempPath()) ("cef_host_publish_" + [System.Guid]::NewGuid().ToString('N'))
$buildDir = Join-Path $work 'build'
$out = Join-Path $work 'out'
try {
  New-Item -ItemType Directory -Force $out | Out-Null

  # --- Build cef_host.dll + stage cef_host.exe via the existing build script. ---
  Info "[publish] building cef_host via build_cef_host.bat ..."
  & (Join-Path $cefHost 'build_cef_host.bat') $buildDir $out
  if ($LASTEXITCODE -ne 0) { Fail "[publish] build_cef_host.bat failed (exit $LASTEXITCODE)." }
  $exe = Join-Path $out 'cef_host.exe'
  $dll = Join-Path $out 'cef_host.dll'
  if (-not (Test-Path -LiteralPath $exe) -or -not (Test-Path -LiteralPath $dll)) {
    Fail "[publish] build did not produce cef_host.exe + cef_host.dll."
  }

  # --- Sign (STUBBED-BUT-REAL). ---
  if ($env:FLUTTER_CEF_SIGN_THUMBPRINT) {
    $signtool = Resolve-Signtool
    if (-not $signtool) {
      Fail "[publish] FLUTTER_CEF_SIGN_THUMBPRINT set but signtool.exe not found (install the Windows SDK)."
    }
    $tsUrl = if ($env:FLUTTER_CEF_SIGN_TIMESTAMP_URL) { $env:FLUTTER_CEF_SIGN_TIMESTAMP_URL }
             else { 'http://timestamp.digicert.com' }
    Info "[publish] signing cef_host.exe + cef_host.dll (thumbprint $($env:FLUTTER_CEF_SIGN_THUMBPRINT)) ..."
    & $signtool sign /sha1 $env:FLUTTER_CEF_SIGN_THUMBPRINT /fd SHA256 /tr $tsUrl /td SHA256 $exe $dll
    if ($LASTEXITCODE -ne 0) { Fail "[publish] signtool sign failed (exit $LASTEXITCODE)." }
    & $signtool verify /pa $exe $dll
    if ($LASTEXITCODE -ne 0) { Fail "[publish] signtool verify failed after signing." }
  }
  else {
    Info "[publish] signing skipped (no cert; unsigned artifact). Set FLUTTER_CEF_SIGN_THUMBPRINT to sign."
  }

  # --- Provenance stamps beside the binaries (informational; the URL is the hash). ---
  $srcSha = 'unknown'
  if (Get-Command git -ErrorAction SilentlyContinue) {
    $rev = & git -C $pkg rev-parse HEAD
    if ($LASTEXITCODE -eq 0 -and $rev) { $srcSha = ([string]$rev).Trim() }
  }
  Set-Content -LiteralPath (Join-Path $out 'cef_host_input_hash.txt') -Value $hash -Encoding ascii
  Set-Content -LiteralPath (Join-Path $out 'cef_version.txt') -Value (Get-CefVersionPin -CefHostDir $cefHost) -Encoding ascii
  Set-Content -LiteralPath (Join-Path $out 'cef_host_source_sha.txt') -Value $srcSha -Encoding ascii

  # --- Package + sha256 sidecar. The zip's own bytes need not be deterministic:
  #     the URL is keyed by the INPUT hash, and the consumer verifies the download
  #     against this sidecar. ---
  $stage = Join-Path $work 'stage'
  New-Item -ItemType Directory -Force $stage | Out-Null
  $zip = Join-Path $stage $file
  Info "[publish] packaging $file ..."
  Compress-Archive -Force -DestinationPath $zip -Path @(
    (Join-Path $out 'cef_host.exe'),
    (Join-Path $out 'cef_host.dll'),
    (Join-Path $out 'cef_host_input_hash.txt'),
    (Join-Path $out 'cef_version.txt'),
    (Join-Path $out 'cef_host_source_sha.txt')
  )
  $zipSha = (Get-FileHash -Algorithm SHA256 -LiteralPath $zip).Hash.ToLowerInvariant()
  $shaSidecar = "$zip.sha256"
  Set-Content -LiteralPath $shaSidecar -Value ("{0}  {1}" -f $zipSha, $file) -Encoding ascii

  # --- Upload (re-check to close a publish race; objects are immutable). ---
  & gsutil -q stat $dst
  if ($LASTEXITCODE -eq 0) {
    Info "[publish] $dst appeared during build - skipping upload."
    exit 0
  }
  $cacheHdr = 'Cache-Control:public,max-age=31536000,immutable'
  & gsutil -h $cacheHdr cp $zip $dst
  if ($LASTEXITCODE -ne 0) { Fail "[publish] upload of $dst failed (exit $LASTEXITCODE)." }
  & gsutil -h $cacheHdr cp $shaSidecar "$dst.sha256"
  if ($LASTEXITCODE -ne 0) { Fail "[publish] upload of $dst.sha256 failed (exit $LASTEXITCODE)." }
  Info "[publish] uploaded $dst (zip sha256 $zipSha)."
  exit 0
}
finally {
  Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}
