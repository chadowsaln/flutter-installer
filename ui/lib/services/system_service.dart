import 'dart:io';

import 'platform.dart';

/// فحص النظام — نفس منطق `system.rs` لكن بـ Dart وأوامر النظام فقط.
class SystemService {
  static String hostname() {
    if (Platform.isLinux) {
      try {
        return File('/proc/sys/kernel/hostname').readAsStringSync().trim();
      } catch (_) {}
    }
    if (Platform.isMacOS) {
      try {
        final r = Process.runSync('scutil', ['--get', 'ComputerName']);
        final s = (r.stdout as String).trim();
        if (s.isNotEmpty) return s;
      } catch (_) {}
    }
    if (Platform.isWindows) {
      return Platform.environment['COMPUTERNAME'] ?? 'unknown';
    }
    return Platform.localHostname;
  }

  static String? toolOnPath(String name) {
    final exe = Platform.isWindows ? '$name.exe' : name;
    final pathEnv = Platform.environment['PATH'] ?? '';
    for (final dir in pathEnv.split(Platform.isWindows ? ';' : ':')) {
      if (dir.isEmpty) continue;
      final f = File('$dir${Platform.pathSeparator}$exe');
      try {
        if (f.existsSync()) return f.path;
      } catch (_) {}
    }
    return HostPlatform.which(name);
  }

  /// اسم التوزيعة من `/etc/os-release` (Linux فقط).
  static String distro() {
    if (!Platform.isLinux) return Platform.isMacOS ? 'macOS' : 'Windows';
    try {
      for (final line in File('/etc/os-release').readAsLinesSync()) {
        if (line.startsWith('PRETTY_NAME=')) {
          return line
              .split('=')
              .skip(1)
              .join('=')
              .replaceAll('"', '')
              .trim();
        }
      }
    } catch (_) {}
    return 'Linux';
  }

  /// مدير الحزم الفعلي — يُكتشف بالأمر لا بالافتراض.
  static String? packageManager() {
    for (final pm in [
      'apt-get',
      'dnf',
      'yum',
      'pacman',
      'zypper',
      'apk',
      'brew',
    ]) {
      if (HostPlatform.which(pm) != null) return pm;
    }
    if (Platform.isWindows && HostPlatform.which('winget') != null) {
      return 'winget';
    }
    return null;
  }

  /// أمر حقيقي جاهز للنسخ لتثبيت أدوات مفقودة على هذا النظام.
  static String installCommand(List<String> packages) {
    final pm = packageManager();
    final pkgs = packages.join(' ');
    return switch (pm) {
      'apt-get' => 'sudo apt-get update && sudo apt-get install -y $pkgs',
      'dnf' => 'sudo dnf install -y $pkgs',
      'yum' => 'sudo yum install -y $pkgs',
      'pacman' => 'sudo pacman -S --needed $pkgs',
      'zypper' => 'sudo zypper install -y $pkgs',
      'apk' => 'sudo apk add $pkgs',
      'brew' => 'brew install $pkgs',
      'winget' =>
        'winget install ${packages.map((p) => 'Id.${_wingetId(p)}').join(' ')}',
      _ => 'install manually: $pkgs',
    };
  }

  static String _wingetId(String pkg) => switch (pkg) {
        'git' => 'Git.Git',
        'curl' => 'curl.curl',
        'unzip' => '7zip.7zip',
        _ => pkg,
      };

  /// اسم حزمة النظام لأي أداة (يختلف بين التوزيعات).
  static String packageName(String tool) => switch (tool) {
        'xz' => Platform.isMacOS ? 'xz' : 'xz-utils',
        _ => tool,
      };

  /// الأدوات المطلوبة + الغائبة (لعرض "ثبّت هذه" بنقرة واحدة).
  static List<String> missingTools() {
    final missing = <String>[];
    for (final tool in ['curl', 'tar', 'unzip', 'git']) {
      if (HostPlatform.which(tool) == null) missing.add(tool);
    }
    if (!Platform.isWindows && HostPlatform.which('xz') == null) {
      missing.add('xz');
    }
    return missing;
  }

  /// مثل `system.info` — ملخص البيئة + قدرات النظام.
  static Map<String, dynamic> info() {
    final env = Platform.environment;
    return {
      'os': HostPlatform.os(),
      'arch': HostPlatform.arch(),
      'hostname': hostname(),
      'user': env['USER'] ?? env['USERNAME'] ?? 'unknown',
      'home': HostPlatform.homeDir(),
      'shell': env['SHELL'] ?? (Platform.isWindows ? 'cmd' : 'unknown'),
      'distro': distro(),
      'packageManager': packageManager(),
      'cpuCores': Platform.numberOfProcessors,
      'flutterOnPath': toolOnPath('flutter'),
      'dartOnPath': toolOnPath('dart'),
    };
  }

  static Map<String, dynamic> _check(
      String id, String name, bool ok, String detail, String fix) {
    return {'id': id, 'name': name, 'ok': ok, 'detail': detail, 'fix': fix};
  }

  /// مثل `system.check` — يتحقق من المعمارية والأدوات عبر أوامر النظام،
  /// ويعيد أوامر إصلاح حقيقية قابلة للنسخ.
  static Map<String, dynamic> check() {
    final checks = <Map<String, dynamic>>[];
    final arch = HostPlatform.arch();
    checks.add(_check(
      'arch',
      'CPU architecture supported',
      arch != 'unknown',
      'Detected architecture: $arch',
      'Flutter supports x86_64 and arm64 hosts.',
    ));

    for (final tool in ['curl', 'tar', 'unzip', 'git']) {
      final found = HostPlatform.which(tool) != null;
      checks.add(_check(
        tool,
        tool,
        found,
        found ? '$tool: found on PATH' : '$tool: not found',
        found
            ? ''
            : 'Copy and run:\n${installCommand([packageName(tool)])}',
      ));
    }

    final xz = HostPlatform.which('xz') != null;
    checks.add(_check(
      'xz',
      'xz compression',
      Platform.isWindows ? true : xz,
      Platform.isWindows
          ? 'Windows tar handles xz natively'
          : (xz ? 'xz: found on PATH' : 'xz: not found'),
      (!Platform.isWindows && !xz)
          ? 'Copy and run:\n${installCommand([packageName('xz')])}'
          : '',
    ));

    final missing = missingTools();
    return {
      'checks': checks,
      'missing': missing,
      'installAll':
          missing.isEmpty ? '' : installCommand(missing.map(packageName).toList()),
    };
  }
}