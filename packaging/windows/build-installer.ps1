# Flutter Installer - Windows setup.exe builder
#
# Builds the Windows release bundle and wraps it into a single
# click-to-install setup.exe with Inno Setup.
#
# Usage (from anywhere):
#   pwsh packaging/windows/build-installer.ps1
#   powershell -ExecutionPolicy Bypass -File packaging/windows/build-installer.ps1
#
# Optional environment overrides:
#   VERSION=0.2.0            force the app version (default: ui/pubspec.yaml)
#   ISCC="C:\path\ISCC.exe"  path to the Inno Setup compiler

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$Root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$Ui   = Join-Path $Root 'ui'
$Iss  = Join-Path $PSScriptRoot 'flutter-installer.iss'
$Bundle = Join-Path $Ui 'build\windows\x64\runner\Release'

function Step($msg) { Write-Host "`n==> $msg" -ForegroundColor Cyan }
function Die($msg)  { Write-Host "`n!! $msg" -ForegroundColor Red; exit 1 }

# --- version from pubspec.yaml (semver part only, drops +build) ---------------
$Version = $env:VERSION
if (-not $Version) {
    $pubspec = Get-Content (Join-Path $Ui 'pubspec.yaml') -Raw
    if ($pubspec -match '(?m)^version:\s*([0-9][^\s+]*)') { $Version = $Matches[1] }
}
if (-not $Version) { Die 'cannot determine version (set VERSION=...)' }

# --- locate flutter -----------------------------------------------------------
if (-not (Get-Command flutter -ErrorAction SilentlyContinue)) { Die 'flutter not on PATH' }

# --- build the release bundle -------------------------------------------------
Step "Building release bundle (flutter build windows --release)"
Push-Location $Ui
try { & flutter build windows --release } finally { Pop-Location }
$exe = Join-Path $Bundle 'flutter_installer_ui.exe'
if (-not (Test-Path $exe)) { Die "release bundle missing $exe" }

# --- verify the static CRT made it into the generated projects ----------------
Write-Host "    --- ui/windows/CMakeLists.txt ---"
Select-String -Path (Join-Path $Ui 'windows\CMakeLists.txt') `
    -Pattern 'CMAKE_MSVC_RUNTIME_LIBRARY|CMAKE_POLICY_DEFAULT_CMP0091|add_subdirectory' |
    ForEach-Object { Write-Host "    $($_.LineNumber): $($_.Line.Trim())" }
Write-Host "    --- CMakeCache MSVC_RUNTIME ---"
Select-String -Path (Join-Path $Ui 'build\windows\x64\CMakeCache.txt') -Pattern 'MSVC_RUNTIME' |
    ForEach-Object { Write-Host "    $($_.Line)" }
Get-ChildItem (Join-Path $Ui 'build\windows') -Recurse -Filter '*.vcxproj' | ForEach-Object {
    $c = Get-Content $_.FullName -Raw
    $rs = ([regex]::Matches($c, '<RuntimeLibrary[^>]*>([^<]+)<')) |
        ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique
    Write-Host "    $($_.Name) -> [$($rs -join ', ')]"
}

# --- locate Inno Setup compiler (ISCC.exe) ------------------------------------
function Find-Iscc {
    if ($env:ISCC -and (Test-Path $env:ISCC)) { return $env:ISCC }
    if (Get-Command ISCC.exe -ErrorAction SilentlyContinue) { return (Get-Command ISCC.exe).Source }
    $candidates = @(
        "$env:ProgramFiles\Inno Setup 6\ISCC.exe",
        "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe",
        "$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe"
    )
    foreach ($c in $candidates) { if ($c -and (Test-Path $c)) { return $c } }
    return $null
}

$iscc = Find-Iscc
if (-not $iscc) {
    $msg = @'
Inno Setup compiler (ISCC.exe) not found.
Install it with one of:
  winget install --id JRSoftware.InnoSetup -e
  choco install innosetup
Then re-run this script (or set ISCC="C:\path\to\ISCC.exe").
'@
    Die $msg
}

# --- compile the setup.exe ----------------------------------------------------
Step "Compiling setup.exe (Inno Setup $Version)"
& $iscc "/DMyAppVersion=$Version" $Iss
if ($LASTEXITCODE -ne 0) { Die "ISCC failed with exit code $LASTEXITCODE" }

$out = Join-Path $Root 'dist'
Step 'Done - artifacts in dist'
Get-ChildItem $out -Filter 'flutter-installer-*-setup.exe' | Select-Object Name, Length, LastWriteTime
