# Packaging — Flutter Installer

كيفية بناء حزم التثبيت لكل التوزيعات من مصدر واحد. التطبيق نفسه
مبني بـ Flutter (Dart فقط، بدون باك إند) لذلك كل الحزم هي مجرد
غلاف لنفس الـ release bundle:

```
flutter_installer_ui + lib/ + data/   ← مخرجات flutter build linux --release
```

## بناء كل الحزم مرة واحدة

```bash
./packaging/build-packages.sh
```

الناتج في `dist/`:

| الملف | الأنظمة | الأداة المطلوبة |
|-------|---------|------------------|
| `flutter-installer-<ver>.tar.gz` | كل لينكس (مصدر/نقل) | tar |
| `flutter-installer-<ver>-1.<dist>.rpm` | Fedora / RHEL / openSUSE | `rpmbuild` |
| `flutter-installer_<ver>_amd64.deb` | Debian / Ubuntu / Mint | `dpkg-deb` (أو `ar`+`tar` احتياطياً) |
| `flutter-installer-x86_64.AppImage` | أي لينكس x86_64 بدون تثبيت | `appimagetool` (يُنزَّل تلقائياً) |
| `PKGBUILD` + `.SRCINFO` | Arch / Manjaro / AUR | `makepkg` على جهاز Arch |

النص يكشف الأدوات المتوفرة تلقائياً ويتجاوز ما ينقص، فينتج
كل ما يمكن إنتاجه على الجهاز الحالي.

## التثبيت لكل نظام

### Fedora / RHEL (RPM)
```bash
sudo rpm -ivh dist/flutter-installer-0.1.0-*.rpm
# أو بالترقية:
sudo rpm -Uvh dist/flutter-installer-0.1.0-*.rpm
```
- التطبيق: `/opt/flutter-installer/`
- الأمر: `/usr/bin/flutter-installer` (رابط نسبي ← `/opt/...`)
- القائمة والرمز: `/usr/share/applications` + `hicolor/192x192`
- التبعية الوحيدة: `gtk3` (بقية المكتبات تتبعها تلقائياً)

### Debian / Ubuntu (DEB)
```bash
sudo apt install ./dist/flutter-installer_0.1.0_amd64.deb
```
نفس المسارات أعلاه. `Depends: libgtk-3-0`، وسكريبتات
`postinst`/`prerm` تحدث قاعدة بيانات القوائم والرموز.

### أي لينكس (AppImage)
```bash
chmod +x dist/flutter-installer-x86_64.AppImage
./dist/flutter-installer-x86_64.AppImage
```
لا يثبّت شيئاً — يعمل مباشرة. `AppRun` يضبط `LD_LIBRARY_PATH`
على مجلد `lib/` الداخلي ثم يشغّل `flutter_installer_ui`.

### Arch Linux / AUR
انسخ `packaging/arch/{PKGBUILD,.SRCINFO}` إلى مجلد بناء:
```bash
makepkg -si          # يبني من tarball المصدر
```
لـ AUR: ارفع المجلد (PKGBUILD + .SRCINFO) كحزمة AUR جديدة،
أو استخدم `aurpublish`. الحزمة تبني من الـ tarball المرفق
في Releases.

## ملفات التغليف

```
packaging/
├── build-packages.sh        ← البنّاء الموحّد (اكتشف الأدوات تلقائياً)
├── common/
│   ├── flutter-installer.desktop
│   ├── AppRun               ← دخول الـ AppImage
│   └── appimagetool.yml
├── rpm/flutter-installer.spec
├── debian/{control,postinst,prerm}
├── appimage/                ← ملاحظات AppImage
└── arch/{PKGBUILD,.SRCINFO}
```

## ملاحظات مهمة

* **الإصدار** يُقرأ من `version:` في `ui/pubspec.yaml` (الجزء
  `0.1.0` فقط، بدون `+build`). غيّره هناك وأعد البناء.
* **الرمز** يُؤخذ من قوالب Flutter SDK
  (`templates/app/.../mipmap-xxxhdpi/ic_launcher.png`).
* **الـ DEB اليدوي**: لو انقص `dpkg-deb` (مثلاً على Fedora) يبني
  النص الحزمة يدوياً — `.deb` هو أرشيف `ar` من ثلاثة أعضاء:
  `debian-binary` + `control.tar.gz` + `data.tar.xz`، و`dpkg`
  يقرأها بنفس الجودة.
* **الـ RPM** يستبعد مكتبات Flutter المرفقة من الفحص التلقائي
  للتبعيات لأنها موجودة داخل الحزمة نفسها (`lib/libflutter_linux_gtk.so`)
  — `rpm -ivh --test` يثبت أن التبعيات تُحلّ ذاتياً.
* **الرابط `/usr/bin/flutter-installer` نسبي** (`../../opt/...`)
  حتى يعمل مع `rpm` و`pacman` الذين يفضّلان الروابط النسبية.
* **Windows / macOS**: التطبيق يعمل عليهما عبر `flutter build
  windows` / `macos` (خدمات النظام تتفرع عبر `Platform` وتستخدم
  `winget`/`setx` على ويندوز)، لكن لم يُصنع مُثبّت لهما بعد —
  `flutter_distributor` أو `msix`/`inno` للويندوز و`dmg` للماك.

## خط أنابيب مقترح (CI)

| الخطوة | ال runner |
|--------|-----------|
| `flutter build linux --release` | ubuntu-latest |
| `.deb` | ubuntu-latest (dpkg-deb موجود) |
| `.rpm` | fedora-latest (rpmbuild موجود) |
| `.AppImage` | ubuntu-latest + تنزيل appimagetool |
| `PKGBUILD` | تحقق فقط (لا يوجد makepkg على GitHub Actions) |

ارفع الناتج إلى GitHub Releases — `PKGBUILD` يشير إليه مباشرة
في `source=()`، ويمكن توقيع الحزم بـ `gpg` عندها.
