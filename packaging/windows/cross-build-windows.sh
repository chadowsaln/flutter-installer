#!/usr/bin/env bash
# Flutter Installer — cross-build the Windows app + setup.exe from Linux.
#
# Unofficial path: Flutter itself does not support building Windows on Linux,
# so this script drives the pieces by hand:
#
#   1. flutter precache --windows          → Windows engine artifacts
#   2. flutter assemble (windows release)  → flutter_assets + AOT app.so
#         gen_snapshot.exe runs under wine (a shim converts path arguments)
#   3. clang-cl + lld-link                 → flutter_installer_ui.exe
#         against MSVC STL + Windows SDK headers/libs fetched by `xwin`
#   4. Inno Setup under wine              → flutter-installer-<ver>-setup.exe
#
# Requirements:
#   flutter, clang-cl, lld-link, wine, xwin  (cargo install xwin)
# Inno Setup is downloaded and installed into the wine prefix automatically.
#
# Usage:
#   packaging/windows/cross-build-windows.sh
#   XWIN=$HOME/.cache/xwin WINEPREFIX=$HOME/.cache/wine-cross \
#     packaging/windows/cross-build-windows.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
UI="$ROOT/ui"
XWIN="${XWIN:-$HOME/.cache/xwin}"
WINEPREFIX="${WINEPREFIX:-$HOME/.cache/wine-cross}"
export WINEPREFIX
FLUTTER_ROOT="${FLUTTER_ROOT:-$(dirname "$(command -v flutter)")/..}"
FLUTTER_ROOT="$(cd "$FLUTTER_ROOT" && pwd)"
ENGINE="$FLUTTER_ROOT/bin/cache/artifacts/engine"
EPH="$UI/windows/flutter/ephemeral"
RUNNER="$UI/windows/runner"
WRAPPER="$EPH/cpp_client_wrapper"
OBJ="$UI/build/windows-cross/obj"
BUNDLE="$UI/build/windows/x64/runner/Release"
OUT="$ROOT/dist"

VERSION="$(sed -n 's/^version: *\([0-9][^ ]*\).*/\1/p' "$UI/pubspec.yaml" | head -1 | cut -d+ -f1)"

CLANG_CL="${CLANG_CL:-clang-cl}"
LLD_LINK="${LLD_LINK:-lld-link}"

step() { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }
die()  { printf '\n\033[1;31m!!\033[0m %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- checks ----
for t in flutter wine; do
    command -v "$t" >/dev/null || die "$t not found on PATH"
done
command -v "$CLANG_CL" >/dev/null || die "$CLANG_CL not found (install clang / LLVM)"
command -v "$LLD_LINK" >/dev/null || die "$LLD_LINK not found (install lld)"
[ -d "$XWIN/crt/include" ] || die "MSVC headers not found in $XWIN — run: cargo install xwin && xwin --accept-license splat --output $XWIN"

mkdir -p "$OBJ" "$BUNDLE/data" "$OUT"

# ------------------------------------------------- 1. Windows engine data ---
step "Fetching Windows engine artifacts (flutter precache --windows)"
( cd "$UI" && flutter precache --windows )

# icudtl.dat is engine-version-identical across desktop targets; reuse the
# Linux blob when the Windows artifact does not ship one.
if [ ! -f "$ENGINE/windows-x64/icudtl.dat" ]; then
    cp "$ENGINE/linux-x64/icudtl.dat" "$ENGINE/windows-x64/icudtl.dat"
fi

# ------------------------------------------- 2. Dart bundle + AOT snapshot ---
# Flutter looks for `gen_snapshot` (no extension) on a Linux host; the real
# Windows PE runs under wine with unix paths translated to Z:\ paths.
GEN_DIR="$ENGINE/windows-x64-release"
if [ ! -f "$GEN_DIR/gen_snapshot-real.exe" ]; then
    cp "$GEN_DIR/gen_snapshot.exe" "$GEN_DIR/gen_snapshot-real.exe"
fi
cat > "$GEN_DIR/gen_snapshot" <<EOF
#!/usr/bin/env bash
# Auto-generated cross-build shim — runs the Windows gen_snapshot under wine.
export WINEDEBUG=-all
export WINEPREFIX="\${WINEPREFIX:-$WINEPREFIX}"
HERE="\$(cd "\$(dirname "\${BASH_SOURCE[0]}")" && pwd)"
args=()
for a in "\$@"; do
  if [[ "\$a" == --*=/* ]]; then
    k="\${a%%=*}"; v="\${a#*=}"
    args+=("\$k=\$(winepath -w "\$v" 2>/dev/null)")
  elif [[ "\$a" == /* ]]; then
    args+=("\$(winepath -w "\$a" 2>/dev/null)")
  else
    args+=("\$a")
  fi
done
exec wine "\$HERE/gen_snapshot-real.exe" "\${args[@]}"
EOF
chmod +x "$GEN_DIR/gen_snapshot"

step "Assembling Dart assets + AOT snapshot (release, windows-x64)"
( cd "$UI" && flutter assemble --no-version-check --output=build \
    -dTargetPlatform=windows-x64 \
    -dBuildMode=release \
    -dTargetFile=lib/main.dart \
    -dTreeShakeIcons=true \
    release_bundle_windows-x64_assets )

[ -f "$UI/build/windows/app.so" ] || die "AOT snapshot missing (build/windows/app.so)"

# ------------------------------------------------------ 3. C++ runner exe ---
step "Compiling the Windows runner (clang-cl + lld-link)"

INCLUDES=(
    "/I$RUNNER"
    "/I$UI/windows"
    "/I$EPH"
    "/I$WRAPPER/include"
    "/I$WRAPPER"
    "/I$XWIN/crt/include"
    "/I$XWIN/sdk/include/ucrt"
    "/I$XWIN/sdk/include/shared"
    "/I$XWIN/sdk/include/um"
    "/I$XWIN/sdk/include/winrt"
)

SOURCES=(
    "$RUNNER/flutter_window.cpp"
    "$RUNNER/main.cpp"
    "$RUNNER/utils.cpp"
    "$RUNNER/win32_window.cpp"
    "$UI/windows/flutter/generated_plugin_registrant.cc"
    "$WRAPPER/core_implementations.cc"
    "$WRAPPER/standard_codec.cc"
    "$WRAPPER/flutter_engine.cc"
    "$WRAPPER/flutter_view_controller.cc"
)

OBJS=()
for src in "${SOURCES[@]}"; do
    obj="$OBJ/$(basename "${src%.*}").obj"
    "$CLANG_CL" --target=x86_64-pc-windows-msvc /nologo /c /O2 /EHsc /std:c++17 /MT \
        /DUNICODE /D_UNICODE /DNOMINMAX /D_HAS_EXCEPTIONS=0 \
        "/DFLUTTER_VERSION=\"$VERSION\"" \
        /DFLUTTER_VERSION_MAJOR=0 /DFLUTTER_VERSION_MINOR=1 \
        /DFLUTTER_VERSION_PATCH=0 /DFLUTTER_VERSION_BUILD=0 \
        "${INCLUDES[@]}" "/Fo$obj" "$src"
    OBJS+=("$obj")
done

step "Linking flutter_installer_ui.exe"
"$LLD_LINK" /nologo /OUT:"$BUNDLE/flutter_installer_ui.exe" \
    /SUBSYSTEM:WINDOWS /MACHINE:X64 /RELEASE \
    /MANIFEST:EMBED "/MANIFESTINPUT:$RUNNER/runner.exe.manifest" \
    "/LIBPATH:$XWIN/crt/lib/x86_64" \
    "/LIBPATH:$XWIN/sdk/lib/ucrt/x86_64" \
    "/LIBPATH:$XWIN/sdk/lib/um/x86_64" \
    "${OBJS[@]}" \
    "$EPH/flutter_windows.dll.lib" \
    dwmapi.lib comctl32.lib user32.lib gdi32.lib shell32.lib ole32.lib \
    oleaut32.lib uuid.lib winmm.lib advapi32.lib \
    libcmt.lib libcpmt.lib libvcruntime.lib libucrt.lib oldnames.lib
# Static CRT (/MT) on purpose: matches how flutter_windows.dll itself is
# linked, and keeps the app free of any MSVCP140/VCRUNTIME140 (VC++
# Redistributable) requirement on the target machine.

# --------------------------------------------------- 4. Assemble the bundle --
step "Assembling the release bundle"
cp -f "$EPH/flutter_windows.dll" "$BUNDLE/"
cp -f "$EPH/icudtl.dat" "$BUNDLE/data/"
cp -f "$UI/build/windows/app.so" "$BUNDLE/data/"
rm -rf "$BUNDLE/data/flutter_assets"
cp -a "$UI/build/flutter_assets" "$BUNDLE/data/flutter_assets"

echo "    bundle: $BUNDLE"
ls -la "$BUNDLE"

# --------------------------------------------------------- 5. setup.exe -----
# Inno Setup runs under wine, so the same .iss used on Windows/CI produces
# the installer here too.
ISCC="$(find "$WINEPREFIX/drive_c" -ipath '*Inno Setup 6/ISCC.exe' 2>/dev/null | head -1)"
if [ -z "$ISCC" ]; then
    step "Installing Inno Setup into the wine prefix"
    INNO_EXE="${INNO_EXE:-$HOME/.cache/innosetup/innosetup-6.7.3.exe}"
    if [ ! -f "$INNO_EXE" ]; then
        mkdir -p "$(dirname "$INNO_EXE")"
        curl -fsSL -o "$INNO_EXE" \
            https://github.com/jrsoftware/issrc/releases/download/is-6_7_3/innosetup-6.7.3.exe
    fi
    wine "$INNO_EXE" /VERYSILENT /SUPPRESSMSGBOXES /NORESTART /SP-
    ISCC="$(find "$WINEPREFIX/drive_c" -ipath '*Inno Setup 6/ISCC.exe' 2>/dev/null | head -1)"
fi
[ -n "$ISCC" ] || die "cannot find ISCC.exe in the wine prefix"

step "Packaging setup.exe (Inno Setup under wine)"
wine "$ISCC" "/DMyAppVersion=$VERSION" \
    "$(winepath -w "$ROOT/packaging/windows/flutter-installer.iss")"

step "Done"
ls -lh "$OUT"/flutter-installer-*-setup.exe
