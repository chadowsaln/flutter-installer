; Flutter Installer — Inno Setup script
;
; Produces a single click-to-install setup.exe from the Flutter Windows
; release bundle (ui/build/windows/x64/runner/Release).
;
; Build with:
;   ISCC.exe /DMyAppVersion=0.1.0 flutter-installer.iss
; or just run ..\windows\build-installer.ps1 (it fills the version in).
;
; Requires Inno Setup 6.3+ (https://jrsoftware.org/isdl.php).

#ifndef MyAppVersion
  #define MyAppVersion "0.1.0"
#endif

#define MyAppName "Flutter Installer"
#define MyAppPublisher "shadow"
#define MyAppURL "https://github.com/chadowsaln/flutter-installer"
#define MyAppExeName "flutter_installer_ui.exe"
; Double brace = a literal "{" for Inno's constant syntax.
#define MyAppId "{{7E3B7B2A-8F4C-4C6E-9A1D-3F2C9B0A5D41}"

; Where `flutter build windows --release` drops the bundle, relative to this file.
#ifndef MyAppSourceDir
  #define MyAppSourceDir "..\..\ui\build\windows\x64\runner\Release"
#endif

[Setup]
AppId={#MyAppId}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppVerName={#MyAppName} {#MyAppVersion}
AppPublisher={#MyAppPublisher}
AppPublisherURL={#MyAppURL}
AppSupportURL={#MyAppURL}
AppUpdatesURL={#MyAppURL}/releases
DefaultDirName={autopf}\{#MyAppName}
DefaultGroupName={#MyAppName}
DisableProgramGroupPage=yes
; Per-user install by default — the app manages SDKs under the user profile,
; so no administrator rights are required.
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
OutputDir=..\..\dist
OutputBaseFilename=flutter-installer-{#MyAppVersion}-setup
SetupIconFile=..\..\ui\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\{#MyAppExeName}
UninstallDisplayName={#MyAppName}
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0
LicenseFile=..\..\LICENSE
; A single setup.exe that installs the app in one click.
DisableWelcomePage=no
AllowNoIcons=yes

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"
Name: "arabic"; MessagesFile: "compiler:Languages\Arabic.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "{#MyAppSourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "..\..\README.md"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\..\LICENSE"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{autoprograms}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "{cm:LaunchProgram,{#StringChange(MyAppName, '&', '&&')}}"; Flags: nowait postinstall skipifsilent
