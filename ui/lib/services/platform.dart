import 'dart:io';

/// كشف نوع النظام والمعمارية — بدون أي باك إند، فقط `dart:io Platform`.
/// OS detection with no backend: pure `dart:io Platform` + system commands.
class HostPlatform {
  /// `linux` / `macos` / `windows` / `unknown` — نفس تسميات أرشيفات Flutter.
  static String os() {
    if (Platform.isLinux) return 'linux';
    if (Platform.isMacOS) return 'macos';
    if (Platform.isWindows) return 'windows';
    return 'unknown';
  }

  /// `x64` / `arm64` / `ia32` / `unknown`.
  static String arch() {
    final v = Platform.version.toLowerCase();
    // Platform.version لا يعطي المعمارية مباشرة، نستخدم `uname -m` على POSIX.
    if (Platform.isLinux || Platform.isMacOS) {
      try {
        final r = Process.runSync('uname', ['-m']);
        final m = (r.stdout as String).trim().toLowerCase();
        if (m.contains('aarch64') || m.contains('arm64')) return 'arm64';
        if (m.contains('x86_64') || m.contains('amd64')) return 'x64';
        if (m.contains('i386') || m.contains('i686')) return 'ia32';
      } catch (_) {}
    }
    if (v.contains('arm64') || v.contains('aarch64')) return 'arm64';
    if (v.contains('x64') || v.contains('x86_64')) return 'x64';
    // الافتراض الآمن على أغلب الأجهزة الحديثة.
    return 'x64';
  }

  /// يوسّع `~` إلى مجلد البيت.
  static String expandHome(String path) {
    if (path == '~') return homeDir();
    if (path.startsWith('~/') || path.startsWith('~\\')) {
      return '${homeDir()}${path.substring(1)}';
    }
    return path;
  }

  static String homeDir() {
    final env = Platform.environment;
    return env['HOME'] ??
        env['USERPROFILE'] ??
        (Platform.isWindows ? r'C:\Users\Default' : '/home/user');
  }

  /// يبحث عن أمر في PATH عبر أوامر النظام: `which` على POSIX و `where` على Windows.
  /// Locate a command via system commands (`which` / `where`).
  static String? which(String name) {
    try {
      final cmd = Platform.isWindows ? 'where' : 'which';
      final r = Process.runSync(cmd, [name]);
      if (r.exitCode != 0) return null;
      final first = (r.stdout as String).split('\n').first.trim();
      if (first.isEmpty) return null;
      if (File(first).existsSync()) return first;
      return first;
    } catch (_) {
      return null;
    }
  }

  static bool looksLikeVersion(String s) {
    final t = s.trim();
    if (t.isEmpty) return false;
    return RegExp(r'^[0-9]').hasMatch(t);
  }
}
