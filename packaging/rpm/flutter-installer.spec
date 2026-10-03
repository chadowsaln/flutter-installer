%global debug_package %{nil}

Name:           flutter-installer
Version:        0.1.0
Release:        1%{?dist}
Summary:        Desktop app to download and manage Flutter and Dart SDKs

License:        MIT
URL:            https://github.com/chadowsaln/flutter-installer
Source0:        %{name}-%{version}.tar.gz
BuildArch:      x86_64
Requires:       gtk3

%description
A self-contained desktop app (Flutter/Dart, no backend) that downloads,
extracts, and manages Flutter and Dart SDKs using only system commands.
Features an Instant Setup wizard, in-place git-based SDK updates,
PATH/profile management, and process supervision.

%prep
%setup -q

%build
# Nothing to compile — the Flutter release bundle ships pre-built.

%install
rm -rf %{buildroot}
install -d %{buildroot}/opt/%{name}
cp -a %{_builddir}/%{name}-%{version}/. %{buildroot}/opt/%{name}/
install -d %{buildroot}/usr/bin
ln -sfn ../../opt/%{name}/flutter_installer_ui \
    %{buildroot}/usr/bin/flutter-installer
install -d %{buildroot}/usr/share/applications
install -m 0644 %{_builddir}/%{name}-%{version}/flutter-installer.desktop \
    %{buildroot}/usr/share/applications/flutter-installer.desktop
install -d %{buildroot}/usr/share/icons/hicolor/192x192/apps
install -m 0644 %{_builddir}/%{name}-%{version}/flutter-installer.png \
    %{buildroot}/usr/share/icons/hicolor/192x192/apps/flutter-installer.png

%post
update-desktop-database >/dev/null 2>&1 || :
gtk-update-icon-cache -f -t /usr/share/icons/hicolor >/dev/null 2>&1 || :

%postun
update-desktop-database >/dev/null 2>&1 || :
gtk-update-icon-cache -f -t /usr/share/icons/hicolor >/dev/null 2>&1 || :

%files
%license /opt/%{name}/LICENSE
%doc /opt/%{name}/README.md
/opt/%{name}/flutter_installer_ui
/opt/%{name}/AppRun
/opt/%{name}/flutter-installer.desktop
/opt/%{name}/flutter-installer.png
/opt/%{name}/lib/
/opt/%{name}/data/
/usr/bin/flutter-installer
/usr/bin/flutter-installer
/usr/share/applications/flutter-installer.desktop
/usr/share/icons/hicolor/192x192/apps/flutter-installer.png

%changelog
* Sat Oct 03 2026 shadow <shadow@localhost> - 0.1.0-1
- Initial RPM packaging of the Flutter Installer desktop app.
