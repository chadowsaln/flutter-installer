import 'dart:io';

import 'platform.dart';

/// إدارة PATH ومتغيرات البيئة — بدون باك إند:
/// - القراءة من `Platform.environment['PATH']` (متغيرات البيئة).
/// - الكتابة عبر الأوامر/الملفات: `export PATH=...` في إعدادات الشيل على POSIX،
///   و `setx` عبر `Process.run` على Windows.
/// PATH management with no backend: read from `Platform.environment`,
/// write via shell-profile files on POSIX and `setx` on Windows.
class PathService {
  static List<String> _profileCandidates() {
    final home = HostPlatform.homeDir();
    final sep = Platform.pathSeparator;
    final list = <String>[
      '$home$sep.zshrc',
      '$home$sep.bashrc',
      '$home$sep.profile',
    ];
    if (Platform.isMacOS) list.add('$home$sep.bash_profile');
    // إزالة التكرار مع الحفاظ على الترتيب.
    final seen = <String>{};
    return list.where((p) => seen.add(p)).toList();
  }

  static String _defaultProfile() {
    for (final p in _profileCandidates()) {
      if (File(p).existsSync()) return p;
    }
    return '${HostPlatform.homeDir()}${Platform.pathSeparator}.bashrc';
  }

  /// مثل `path.get` — لقطة من متغيرات البيئة لهذه العملية.
  static Map<String, dynamic> get() {
    final raw = Platform.environment['PATH'] ?? '';
    final entries = raw.split(Platform.isWindows ? ';' : ':');
    return {'entries': entries.where((e) => e.isNotEmpty).toList()};
  }

  /// مثل `path.profiles` — ملفات الشيل التي يمكن الدمج فيها.
  static Map<String, dynamic> profiles() {
    final list = _profileCandidates()
        .map((p) => {'path': p, 'exists': File(p).existsSync()})
        .toList();
    return {'profiles': list};
  }

  /// مثل `path.ensure` — يضيف `binDir` إلى PATH عبر الأوامر:
  /// POSIX: سطر `export PATH="...:$PATH"` في البروفايل، Windows: `setx`.
  static Future<Map<String, dynamic>> ensure(
    String binDir, {
    String? profile,
  }) async {
    final abs = HostPlatform.expandHome(binDir);

    if (Platform.isWindows) {
      // عبر أمر النظام setx — يحدّث متغيرات بيئة المستخدم.
      final r = await Process.run(
          'setx', ['PATH', '%PATH%;$abs']);
      if (r.exitCode != 0) {
        throw ProcessException(
            'setx', ['PATH'], 'setx failed: ${r.stderr}', r.exitCode);
      }
      return {'platform': 'windows', 'path': abs, 'added': true};
    }

    if (!abs.startsWith('/')) {
      throw ArgumentError('expected an absolute bin directory, got: $abs');
    }

    final filePath = profile != null ? HostPlatform.expandHome(profile) : _defaultProfile();
    final file = File(filePath);
    final content =
        file.existsSync() ? await file.readAsString() : '';
    final line = 'export PATH="$abs:\$PATH"';
    final marker = '# flutter-installer: $abs';

    if (content.contains(abs)) {
      return {
        'profile': filePath,
        'path': abs,
        'line': line,
        'added': false,
      };
    }

    var next = content.trimRight();
    if (next.isNotEmpty) next += '\n';
    next += '\n$marker\n$line\n';
    await file.writeAsString(next);
    return {
      'profile': filePath,
      'path': abs,
      'line': line,
      'added': true,
    };
  }

  /// مثل `path.remove` — يحذف أسطر الـ export التي تشير إلى `binDir`.
  static Future<Map<String, dynamic>> remove(String binDir) async {
    final abs = HostPlatform.expandHome(binDir);
    final removed = <Map<String, String>>[];
    for (final p in _profileCandidates()) {
      final f = File(p);
      if (!f.existsSync()) continue;
      final content = await f.readAsString();
      final kept =
          content.split('\n').where((l) => !l.contains(abs)).toList();
      if (kept.length != content.split('\n').length) {
        await f.writeAsString('${kept.join('\n')}\n');
        removed.add({'profile': p});
      }
    }
    return {'path': abs, 'removed': removed};
  }
}
