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

## Building from Linux (cross-build, unofficial)

Flutter officially refuses to build the Windows target on Linux, but the same
`setup.exe` can still be produced locally — `cross-build-windows.sh` drives
each piece by hand:

```bash
packaging/windows/cross-build-windows.sh
# -> dist/flutter-installer-0.1.0-setup.exe
```

| Step | Tool | What happens |
|------|------|--------------|
| engine artifacts | `flutter precache --windows` | downloads `flutter_windows.dll`, `gen_snapshot.exe`, the C++ client wrapper |
| Dart bundle + AOT | `flutter assemble` + **wine** | `gen_snapshot.exe` runs under wine (a generated shim rewrites unix paths); produces `flutter_assets` + `data/app.so` |
| C++ runner | **clang-cl + lld-link** | compiles `windows/runner/*` + the client wrapper against MSVC STL / Windows SDK headers fetched by [`xwin`](https://github.com/Jake-Shadle/xwin), links `flutter_installer_ui.exe` |
| installer | **Inno Setup under wine** | downloads Inno Setup once into the wine prefix and compiles the same `flutter-installer.iss` used on Windows/CI |

Prerequisites (Linux): `flutter`, `wine`, `clang-cl`, `lld-link` (LLVM),
`cargo` (for `xwin`). The script installs `xwin`'s SDK payload and Inno Setup
itself on first run (into `$XWIN` and `$WINEPREFIX`, defaulting to
`~/.cache/...`).

Caveats:

- Unofficial and fragile by nature: a Flutter upgrade can move any of these
  pieces. The supported path stays Windows or GitHub Actions.
- The produced installer was verified to install and put the app files in
  place. The runner links the CRT statically (`/MT`), matching
  `flutter_windows.dll`, so the app has no Visual C++ Redistributable
  dependency.
- Running the cross-built app under wine can crash inside wine's OpenGL
  stack (Impeller); that is a wine limitation, not a property of the exe —
  validate on real Windows.

## CI

`.github/workflows/windows-release.yml` runs the same script on
`windows-latest` on every `v*` tag push and uploads the `setup.exe` to the
GitHub Release. It can also be run manually via **Actions → Windows
installer → Run workflow**.

## Files

```
packaging/windows/
├── flutter-installer.iss    ← Inno Setup script (UI, shortcuts, uninstaller)
├── build-installer.ps1      ← build + compile driver (Windows)
├── build-installer.cmd      ← PowerShell wrapper for cmd/double-click
└── cross-build-windows.sh   ← Linux cross-build (wine + clang-cl + xwin)
```

Version comes from `version:` in `ui/pubspec.yaml`; change it there and rebuild.
