# Flutter Installer

A self-contained desktop application that downloads and manages the Flutter and
Dart SDKs. **It runs as one single process — no daemon, no server.** The Rust
core is compiled into a shared library (`libflutter_core.so`) and loaded
directly into the app via `dart:ffi`.

```
Flutter Installer
├── Flutter Desktop UI          (ui/ — Flutter app: Linux / Windows / macOS)
└── Tauri / Rust Core           (core/ — Rust workspace)
    ├── SDK Manager             sdk.rs    – orchestration of Flutter + Dart installs
    ├── Dart Manager            dart.rs   – standalone Dart SDK install / list
    ├── Flutter Manager         flutter.rs – Flutter SDK install / list / resolve
    ├── PATH Manager            path.rs   – shell-profile PATH manipulation
    ├── Process Manager         process.rs – spawn / stream / terminate sub-processes
    └── System Checker          system.rs  – OS, arch, prerequisites, network checks
```

## Architecture

```
Flutter app (single process, no server)
┌─────────────────────────────────────────────────────┐
│ Flutter UI (Dart)            dart:ffi      Rust core │
│  screens / AppState  ◀────┼────▶  libflutter_core.so │
│  CoreClient (JSON-RPC) ◀──┤──▶  ffi_core_call/poll   │
│  poll timer (~20ms)    ◀──┤──▶  shared output queue  │
│  download + PATH +      ────                       │
│  process management        (all inside this process)│
└─────────────────────────────────────────────────────┘
```

* The Rust `cdylib` exposes a tiny C ABI (`core/crates/core_ffi`):
  `ffi_core_new`, `ffi_core_call(method, params, id)`, `ffi_core_poll`,
  `ffi_core_free_string`, `ffi_core_destroy`.
* Each request runs on its own Rust thread, so long downloads never block the
  UI; responses and notifications (`progress`, `log`, `task.*`, `process.*`)
  flow through one shared queue that the UI drains on a ~20 ms timer.
* No ports, no sockets, no child processes: the download still happens directly
  from Flutter's official servers (`storage.googleapis.com`), as before.

## Quick start

```bash
# 1. Build the Rust core shared library (release for the app, debug for dev)
cargo build --manifest-path core/Cargo.toml --release

# 2. Run the Flutter app — it loads libflutter_core.so in-process
cd ui
flutter run -d linux
```

The app looks for the library in this order: `CORE_FFI` env override →
`../core/target/{release,debug}/` → bundled beside the executable.

**Fallback:** if the library is missing, the app falls back to the `daemon`
sidecar binary (`cargo build --release` in `core/`) so the debugging/CLI flow
keeps working without a rebuild.

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
cd core && cargo build && cargo clippy        # core + daemon + core_ffi
cd ui    && flutter analyze && flutter test    # UI + FFI round-trip tests
```

The `flutter test` suite drives the real in-process FFI bridge end-to-end
(ping, system info, sdk.known, notification stream).

### Using the daemon directly (CLI / debugging)

The same core also ships as a stdio JSON-RPC binary under `core/crates/daemon`;
each request line is handled concurrently and output is single-line JSON:

```bash
core/target/debug/daemon <<< '{"jsonrpc":"2.0","id":1,"method":"ping","params":{}}'
```

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