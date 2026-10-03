#!/usr/bin/env bash
# Flutter Installer — multi-format packaging.
#
# Builds every artifact this repo can produce on the current host:
#   * flutter-installer-<ver>.tar.gz   (source/bundle tarball, all formats)
#   * flutter-installer-<ver>-1.<dist>.rpm   (Fedora/RHEL/openSUSE)
#   * flutter-installer_<ver>_amd64.deb      (Debian/Ubuntu/Mint)
#   * flutter-installer-x86_64.AppImage      (any Linux, no install needed)
#   * PKGBUILD / .SRCINFO                    (Arch Linux / AUR — copy only)
#
# Usage:  ./packaging/build-packages.sh            # auto-detect host
#         VERSION=0.2.0 ./packaging/build-packages.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UI="$ROOT/ui"
PKG=flutter-installer
BIN=flutter_installer_ui

# Version comes from pubspec.yaml (semver part only, drops the +build).
VERSION="${VERSION:-$(sed -n 's/^version: *\([0-9][^ ]*\).*/\1/p' "$UI/pubspec.yaml" | head -1 | cut -d+ -f1)}"
VERSION="${VERSION:-0.1.0}"
OUT="${PKG_OUT:-$ROOT/dist}"
WORK="$(mktemp -d -t flutter-installer-pkg.XXXXXX)"
BUNDLE="$UI/build/linux/x64/release/bundle"
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$OUT"

step() { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }
die()  { printf '\n\033[1;31m!!\033[0m %s\n' "$*" >&2; exit 1; }

command -v flutter >/dev/null || die "flutter not on PATH"

step "Building release bundle (flutter build linux --release)"
( cd "$UI" && flutter build linux --release )
[ -x "$BUNDLE/$BIN" ] || die "release bundle missing $BIN"

step "Staging package tree v$VERSION"
STAGE="$WORK/$PKG-$VERSION"
mkdir -p "$STAGE"
cp -a "$BUNDLE/." "$STAGE/"
cp packaging/common/flutter-installer.desktop "$STAGE/"
# Icon: Flutter's own template launcher art (192x192).
ICON_SRC="$(find "${FLUTTER_ROOT:-$(dirname "$(command -v flutter)")/cache}/.." \
    /usr/lib/flutter /opt/flutter /home/*/development/flutter \
    -path '*/templates/app/android.tmpl/app/src/main/res/mipmap-xxxhdpi/ic_launcher.png' \
    2>/dev/null | head -1 || true)"
[ -n "$ICON_SRC" ] || die "cannot find a launcher icon in the Flutter SDK"
cp "$ICON_SRC" "$STAGE/flutter-installer.png"
cp packaging/common/AppRun "$STAGE/AppRun"
chmod +x "$STAGE/AppRun"
[ -f "$ROOT/LICENSE" ] && cp "$ROOT/LICENSE" "$STAGE/"
[ -f "$ROOT/README.md" ] && cp "$ROOT/README.md" "$STAGE/"

step "Source tarball → $OUT/$PKG-$VERSION.tar.gz"
tar -czf "$OUT/$PKG-$VERSION.tar.gz" -C "$WORK" "$PKG-$VERSION"

# ---------------------------------------------------------------- RPM -----
if command -v rpmbuild >/dev/null; then
    step "RPM (rpmbuild)"
    RPMTOP="$WORK/rpmbuild"
    mkdir -p "$RPMTOP"/{BUILD,RPMS,SOURCES,SPECS,SRPMS}
    cp "$OUT/$PKG-$VERSION.tar.gz" "$RPMTOP/SOURCES/"
    SPEC="$WORK/flutter-installer.spec"
    sed "s/^Version: *.*/Version:        $VERSION/" \
        packaging/rpm/flutter-installer.spec > "$SPEC"
    rpmbuild --define "_topdir $RPMTOP" -bb "$SPEC" >/dev/null
    cp "$RPMTOP"/RPMS/x86_64/*.rpm "$OUT/"
    echo "    ✓ $(ls "$RPMTOP"/RPMS/x86_64/)"
else
    step "RPM skipped — rpmbuild not found (install rpm-build)"
fi

# ---------------------------------------------------------------- DEB -----
build_deb() { # $1 = output .deb path
    local deb_root="$WORK/deb-root"
    rm -rf "$deb_root"
    mkdir -p "$deb_root"/{opt/$PKG,usr/bin,usr/share/applications,usr/share/icons/hicolor/192x192/apps,DEBIAN}
    cp -a "$STAGE/." "$deb_root/opt/$PKG/"
    ln -sfn "/opt/$PKG/$BIN" "$deb_root/usr/bin/flutter-installer"
    install -m 0644 "$STAGE/flutter-installer.desktop" \
        "$deb_root/usr/share/applications/flutter-installer.desktop"
    install -m 0644 "$STAGE/flutter-installer.png" \
        "$deb_root/usr/share/icons/hicolor/192x192/apps/flutter-installer.png"
    sed "s/^Version: .*/Version: $VERSION/" packaging/debian/control \
        > "$deb_root/DEBIAN/control"
    install -m 0755 packaging/debian/postinst "$deb_root/DEBIAN/postinst"
    install -m 0755 packaging/debian/prerm  "$deb_root/DEBIAN/prerm"

    if command -v dpkg-deb >/dev/null; then
        dpkg-deb --build --root-owner-group "$deb_root" "$1"
    else
        # Manual fallback — a .deb is just an ar of three members.
        ( cd "$deb_root" \
            && tar -czf "$WORK/control.tar.gz" -C DEBIAN . \
            && tar -cJf "$WORK/data.tar.xz" --exclude=./DEBIAN . )
        ( cd "$WORK" && echo "2.0" > debian-binary \
            && ar rc "$1" debian-binary control.tar.gz data.tar.xz )
    fi
}

if [ "$(uname -m)" = x86_64 ]; then
    step "DEB (dpkg-deb or ar+tar fallback)"
    build_deb "$OUT/$PKG"_"$VERSION"_amd64.deb
    echo "    ✓ ${PKG}_${VERSION}_amd64.deb"
fi

# ----------------------------------------------------------- AppImage -----
step "AppImage (appimagetool)"
APP_DIR="$WORK/AppDir"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR"
cp -a "$STAGE/." "$APP_DIR/"          # includes AppRun, desktop, icon
APPIMAGETOOL="${APPIMAGETOOL:-$WORK/appimagetool.AppImage}"
if ! command -v appimagetool >/dev/null && [ ! -x "$APPIMAGETOOL" ]; then
    echo "    downloading appimagetool…"
    if command -v curl >/dev/null; then
        curl -fsSL -o "$APPIMAGETOOL" \
            https://github.com/AppImage/AppImageKit/releases/download/continuous/appimagetool-x86_64.AppImage \
            && chmod +x "$APPIMAGETOOL" || true
    fi
fi
run_appimagetool() {
    if command -v appimagetool >/dev/null; then
        appimagetool "$APP_DIR" "$OUT/$PKG-x86_64.AppImage" >/dev/null
    elif [ -x "$APPIMAGETOOL" ]; then
        "$APPIMAGETOOL" --appimage-extract-and-run "$APP_DIR" \
            "$OUT/$PKG-x86_64.AppImage" >/dev/null
    else
        return 1
    fi
}
if run_appimagetool; then
    echo "    ✓ $PKG-x86_64.AppImage"
else
    echo "    AppImage skipped — appimagetool unavailable (see PACKAGING.md for manual steps)"
fi

# -------------------------------------------------------------- Arch ------
step "Arch (PKGBUILD + .SRCINFO — build on an Arch host with makepkg)"
cp packaging/arch/PKGBUILD packaging/arch/.SRCINFO "$OUT/"
echo "    ✓ PKGBUILD .SRCINFO"

step "Done — artifacts in $OUT"
ls -lh "$OUT"
