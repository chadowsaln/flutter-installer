# Flutter Installer

تطبيق سطح مكتب مكتفٍ ذاتياً لتنزيل وإدارة Flutter و Dart SDKs.
**بدون أي باك إند — لا Rust ولا سيرفر ولا daemon.** كل شيء بـ Dart وأوامر
النظام مباشرة: كشف النظام عبر `Platform`، التنزيل عبر `HttpClient`، الفك عبر
`tar`/`unzip`، والـ PATH عبر متغيرات البيئة (`export` في البروفايل أو `setx`).

```
Flutter Installer (Dart فقط — بدون باك إند)
└── Flutter Desktop UI          (ui/ — Flutter app: Linux / Windows / macOS)
    ├── services/platform.dart  – كشف النظام: linux/macos/windows + arch عبر uname
    ├── services/downloader.dart – تنزيل HttpClient + فك عبر tar/unzip (أوامر نظام)
    ├── services/flutter_service – resolve من release feed + install/list/uninstall
    ├── services/dart_service    – install/list/uninstall لـ Dart SDK
    ├── services/path_service    – PATH من Environment + export/setx عبر الأوامر
    ├── services/process_service – spawn/exec/terminate عبر Process
    └── services/system_service  – فحص المتطلبات عبر which/where
```

## Architecture

```
Flutter app (single process, no backend)
┌─────────────────────────────────────────────────────┐
│ Flutter UI (Dart)                                   │
│  screens / AppState  ──▶  services/*.dart           │
│  rpc(method)          ──▶  Platform + Process.run    │
│  downloadProgress/log ──▶  HttpClient + tar/unzip    │
│  PATH                 ──▶  Environment + export/setx │
└─────────────────────────────────────────────────────┘
```

* لا منافذ ولا سوكيتات ولا عمليات خلفية: التنزيل مباشرة من سيرفرات Flutter
  الرسمية (`storage.googleapis.com`).
* مجلد `core/` (Rust) موجود كمرجع تاريخي فقط وغير مطلوب لبناء أو تشغيل التطبيق.

## Quick start — بدون بناء أي باك إند

```bash
cd ui
flutter run -d linux
```

لا حاجة لـ `cargo build` ولا `CORE_FFI` ولا binary جانبي.

## الحزم والتنزيلات

مُغلف لكل التوزيعات من أمر واحد — `./packaging/build-packages.sh`:

| النظام | الحزمة | التثبيت |
|--------|--------|---------|
| Fedora / RHEL | `flutter-installer-*.rpm` | `sudo rpm -ivh …` |
| Debian / Ubuntu | `flutter-installer_*_amd64.deb` | `sudo apt install ./…` |
| أي لينكس | `flutter-installer-x86_64.AppImage` | `chmod +x && ./…` |
| Arch / AUR | `PKGBUILD` + `.SRCINFO` | `makepkg -si` |

التفاصيل الكاملة في [packaging/PACKAGING.md](packaging/PACKAGING.md).

## Screens

| Screen        | Backed by        | Purpose                                    |
|---------------|------------------|--------------------------------------------|
| Installer     | `flutter.install`| Channel/version → download → extract → PATH |
| SDK Manager   | `sdk.list/known` | Overview of every found SDK + latest versions |
| Flutter       | `flutter.list`   | Installed Flutter SDKs, PATH, uninstall    |
| Dart          | `dart.*`         | Standalone Dart SDK install / list        |
| PATH          | `path.*`         | PATH entries, shell profiles, add/remove  |
| Processes     | `process.*`      | Spawn / stream / terminate sub-processes  |
| System        | `system.check`   | Prerequisite matrix (curl, xz, GTK, ...)  |

## RPC surface

`system.info`, `system.check` ·
`sdk.list`, `sdk.known`, `sdk.install` ·
`flutter.latest`, `flutter.list`, `flutter.install`, `flutter.uninstall` ·
`dart.latest`, `dart.list`, `dart.install`, `dart.uninstall` ·
`path.get`, `path.profiles`, `path.ensure`, `path.remove` ·
`process.spawn`, `process.list`, `process.terminate`, `process.exec`

## Development

```bash
cd ui && flutter analyze && flutter test    # UI + local backend tests
```

The `flutter test` suite verifies the local backend end-to-end
(ping, system info, PATH, process.exec — all without any backend).

## Notes

* Flutter archives are `.tar.xz` (POSIX) / `.zip` (Windows); Dart SDKs ship as
  `.zip` everywhere — handled by `util::extract_archive`.
* Version detection reads `bin/cache/flutter.version.json` or the repo `version`
  file instead of running `flutter --version` (which triggers an engine
  download).
* `path.ensure` writes `export PATH="...:$PATH"` into `.bashrc`/`.zshrc`/`.profile`
  on POSIX and uses `setx` on Windows.
* Metadata fetches (release feed, HEADs) fail fast (~8–12 s timeouts) so the UI
  never sits on a silent spinner; failures surface an inline message + Retry.