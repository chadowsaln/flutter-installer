# Windows setup.exe — Flutter Installer

Builds a single click-to-install Windows installer (`setup.exe`) around the
Flutter Windows release bundle. The installer is produced by
[Inno Setup](https://jrsoftware.org/isinfo.php).

```
ui/build/windows/x64/runner/Release/   ← flutter build windows --release
        │
        └── flutter-installer.iss  ──▶  dist/flutter-installer-<ver>-setup.exe
```

## Prerequisites (on a Windows machine or CI runner)

| Tool | Install |
|------|---------|
| Flutter (with Windows desktop enabled) | `flutter config --enable-windows-desktop` |
| Visual Studio 2022 + "Desktop development with C++" | [vs installer](https://visualstudio.microsoft.com/) |
| Inno Setup 6.3+ | `winget install --id JRSoftware.InnoSetup -e` |

## Build

```powershell
# from the repo root
.\packaging\windows\build-installer.ps1

# or force a version
$env:VERSION = "0.2.0"; .\packaging\windows\build-installer.ps1
```

The script:

1. reads the version from `ui/pubspec.yaml` (`0.1.0` in `0.1.0+1`),
2. runs `flutter build windows --release`,
3. compiles `flutter-installer.iss` with `ISCC.exe`,
4. writes `dist/flutter-installer-<ver>-setup.exe`.

The result is a per-user installer (`PrivilegesRequired=lowest`) — no admin
prompt — that places the app under `%LOCALAPPDATA%\Programs\Flutter Installer`,
adds Start Menu (and optional desktop) shortcuts, and offers to launch it.

`build-installer.cmd` is a thin wrapper for double-click / plain `cmd`.

## CI

`.github/workflows/windows-release.yml` runs the same script on
`windows-latest` on every `v*` tag push and uploads the `setup.exe` to the
GitHub Release. It can also be run manually via **Actions → Windows
installer → Run workflow**.

## Files

```
packaging/windows/
├── flutter-installer.iss    ← Inno Setup script (UI, shortcuts, uninstaller)
├── build-installer.ps1      ← build + compile driver
└── build-installer.cmd      ← PowerShell wrapper for cmd/double-click
```

Version comes from `version:` in `ui/pubspec.yaml`; change it there and rebuild.
