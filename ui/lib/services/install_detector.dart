import 'dart:convert';
import 'dart:io';

import 'platform.dart';
import 'system_service.dart';

/// حالة تثبيت Flutter على هذا الجهاز.
enum InstallState {
  /// لا يوجد Flutter مثبت.
  notInstalled,

  /// مثبت بإصدار أقل من الهدف ⇒ يوفّر التحديث.
  outdated,

  /// مثبت بنفس إصدار الهدف ⇒ لا حاجة لأي إجراء.
  upToDate,

  /// مثبت بإصدار أحدث من الهدف (dev/master مقابل stable مثلاً).
  newer,
}

/// نتيجة الكشف الكاملة — شيء واحد تقوله الواجهة مباشرة.
class InstallDetection {
  const InstallDetection({
    required this.state,
    this.flutterPath,
    this.installedVersion,
    this.targetVersion,
    this.channel,
    this.dartVersion,
    this.onPath = false,
    this.binPath,
    this.sdkCount = 0,
    this.notes = const [],
  });

  /// جهاز بلا Flutter.
  const InstallDetection.absent()
      : state = InstallState.notInstalled,
        flutterPath = null,
        installedVersion = null,
        targetVersion = null,
        channel = null,
        dartVersion = null,
        onPath = false,
        binPath = null,
        sdkCount = 0,
        notes = const [];

  final InstallState state;
  final String? flutterPath;
  final String? installedVersion;
  final String? targetVersion;
  final String? channel;
  final String? dartVersion;
  final bool onPath;
  final String? binPath;

  /// كم SDK آخر وجدناه (لعرض "وجدت أكثر من واحد").
  final int sdkCount;
  final List<String> notes;

  bool get isInstalled => state != InstallState.notInstalled;

  /// هل يحتاج تدخّل المستخدم فعلاً.
  bool get needsAction => state == InstallState.notInstalled || state == InstallState.outdated;

  /// ملخّص سطر واحد للواجهة.
  String get summary {
    switch (state) {
      case InstallState.notInstalled:
        return 'Flutter غير مثبّت على هذا الجهاز';
      case InstallState.upToDate:
        return 'Flutter $installedVersion مثبّت — الأحدث';
      case InstallState.newer:
        return 'Flutter $installedVersion مثبّت (أحدث من الهدف $targetVersion)';
      case InstallState.outdated:
        return 'Flutter $installedVersion مثبّت — الهدف $targetVersion';
    }
  }

  /// نص الزر المناسب للحالة.
  String get actionLabel => switch (state) {
        InstallState.notInstalled => 'Install Flutter now',
        InstallState.outdated => 'Update to $targetVersion',
        InstallState.upToDate => 'Up to date',
        InstallState.newer => 'Downgrade to $targetVersion',
      };

  bool get actionEnabled => true;
}

/// يكتشف إن كان Flutter مثبتاً فعلاً على هذا الجهاز، ويقارنه بالهدف.
///
/// Detection is real, not guesswork:
///  - يفحص `PATH` مدخلاً مدخلاً (يبحث عن `flutter` داخل `<root>/bin`).
///  - يفحص المواقع المعتادة: `~/development/flutter`, `~/flutter`, `/opt/flutter`,
///    `FLUTTER_ROOT`, `%LOCALAPPDATA%\flutter`, `~/snap/flutter/common/flutter`.
///  - يقرأ الإصدار من `bin/cache/flutter.version.json` (بلا تشغيل `flutter`).
///  - يقارن رقمياً (3.9.0 < 3.10.0) لا lexicographically.
class InstallationDetector {
  /// المواقع التي نفحصها خارج PATH.
  static List<String> _candidateRoots() {
    final home = HostPlatform.homeDir();
    final sep = Platform.pathSeparator;
    final env = Platform.environment;
    final roots = <String>[
      if (env['FLUTTER_ROOT'] != null && env['FLUTTER_ROOT']!.isNotEmpty)
        HostPlatform.expandHome(env['FLUTTER_ROOT']!),
      '$home${sep}development${sep}flutter',
      '$home${sep}flutter',
      '$home${sep}snap${sep}flutter${sep}common${sep}flutter',
      if (Platform.isMacOS) '/opt/flutter',
      if (Platform.isWindows)
        '${env['LOCALAPPDATA'] ?? '$home${sep}AppData${sep}Local'}${sep}flutter',
      if (Platform.isWindows)
        '${env['ProgramFiles'] ?? 'C:\\Program Files'}${sep}flutter',
    ];
    return roots;
  }

  /// جذر Flutter إن كان flutter موجوداً داخل `<root>/bin`.
  static String? _rootFromBin(String binDir) {
    final sep = Platform.pathSeparator;
    final parent = binDir.substring(0, binDir.length - sep.length);
    if (parent.isEmpty) return null;
    return parent;
  }

  static String _flutterExe() => Platform.isWindows ? 'flutter.bat' : 'flutter';

  static String _binOf(String root) =>
      '$root${Platform.pathSeparator}bin';

  static bool _isFlutterRoot(String root) =>
      File('${_binOf(root)}${Platform.pathSeparator}${_flutterExe()}')
          .existsSync();

  /// يجد كل جذور Flutter المعروفة (من PATH + المواقع المعتادة).
  static List<String> discoverRoots() {
    final sep = Platform.pathSeparator;
    final found = <String>{};

    final pathEnv = Platform.environment['PATH'] ?? '';
    for (final entry in pathEnv.split(Platform.isWindows ? ';' : ':')) {
      if (entry.isEmpty) continue;
      final dir = entry.replaceAll('/', sep);
      if (!dir.endsWith('${sep}bin')) continue;
      final root = _rootFromBin(dir);
      if (root != null && _isFlutterRoot(root)) found.add(root);
    }

    for (final root in _candidateRoots()) {
      if (_isFlutterRoot(root)) found.add(root);
    }
    return found.toList();
  }

  /// يقرأ (الإصدار، القناة، إصدار Dart) من جذر SDK.
  ///
  /// يعتمد على `bin/cache/flutter.version.json` أولاً، ثم ملف `version`.
  /// لا يشغّل `flutter` إطلاقاً — ذلك قد يبدأ تنزيل المحرك.
  static (String?, String?, String?) readVersion(String root) {
    final sep = Platform.pathSeparator;
    final cache = File('$root${sep}bin${sep}cache${sep}flutter.version.json');
    if (cache.existsSync()) {
      try {
        final decoded = jsonDecode(cache.readAsStringSync());
        if (decoded is Map) {
          final v = decoded['frameworkVersion'] as String?;
          final c = decoded['channel'] as String?;
          final d = decoded['dartSdkVersion'] as String?;
          if (v != null) return (v, c, d);
        }
      } catch (_) {}
    }
    final versionFile = File('$root${sep}version');
    if (versionFile.existsSync()) {
      final t = versionFile.readAsStringSync().trim();
      if (HostPlatform.looksLikeVersion(t)) return (t, null, null);
    }
    return (null, null, null);
  }

  /// يقارن إصدارات Flutter ترتيبياً: `3.10.0 > 3.9.0` و `3.47.5-beta < 3.47.5`.
  ///
  /// Not a string compare: `3.9.0` must be lower than `3.10.0`.
  static int compareVersions(String a, String b) {
    final pa = _versionParts(a);
    final pb = _versionParts(b);
    for (var i = 0; i < 3; i++) {
      final d = pa[i].compareTo(pb[i]);
      if (d != 0) return d;
    }
    // نفس النواة الرقمية: نفصل الإصدار النهائي عن ما قبله (semver).
    final preA = a.split('-').skip(1).join('-');
    final preB = b.split('-').skip(1).join('-');
    if (preA.isEmpty && preB.isEmpty) return 0;
    if (preA.isEmpty) return 1; // 3.48.0 > 3.48.0-1.2.pre
    if (preB.isEmpty) return -1;
    return _comparePreRelease(preA, preB);
  }

  /// يقارن ما بعد الشرطة بترتيب semver: `1.2.pre` < `2.0.pre`، والمرقام
  /// الرقمية أصغر من النصوص.
  static int _comparePreRelease(String a, String b) {
    final ta = a.split('.');
    final tb = b.split('.');
    for (var i = 0; i < (ta.length > tb.length ? ta.length : tb.length); i++) {
      if (i >= ta.length) return -1;
      if (i >= tb.length) return 1;
      final ea = ta[i];
      final eb = tb[i];
      final na = int.tryParse(ea);
      final nb = int.tryParse(eb);
      if (na != null && nb != null) {
        final d = na.compareTo(nb);
        if (d != 0) return d;
      } else if (na != null) {
        return -1; // numeric identifiers rank below alphanumeric ones
      } else if (nb != null) {
        return 1;
      } else {
        final d = ea.compareTo(eb);
        if (d != 0) return d;
      }
    }
    return 0;
  }

  static List<int> _versionParts(String v) {
    final core = v.split('-').first;
    final parts = core.split('.');
    return List.generate(3, (i) {
      if (i >= parts.length) return 0;
      return int.tryParse(RegExp(r'^\d+').firstMatch(parts[i])?.group(0) ?? '0') ??
          0;
    });
  }

  /// الكشف الكامل ثم المقارنة مع الهدف.
  ///
  /// [targetVersion] null يعني "لم يُحلّ الهدف بعد" — يُرجع الحالة دون مقارنة.
  static InstallDetection detect({String? targetVersion}) {
    final roots = discoverRoots();
    if (roots.isEmpty) {
      final notes = <String>[];
      final onPath = SystemService.toolOnPath('flutter');
      if (onPath != null) {
        notes.add('flutter on PATH at $onPath but no SDK root matched');
      }
      return InstallDetection(
        state: InstallState.notInstalled,
        notes: notes,
      );
    }

    // نفضّل الجذر الموجود في PATH، وإلا أول مرتب.
    String? best;
    String? bestVersion;
    String? bestChannel;
    String? bestDart;
    var bestOnPath = false;

    for (final root in roots) {
      final (version, channel, dart) = readVersion(root);
      final onPath = _onPath(_binOf(root));
      if (best == null) {
        best = root;
        bestVersion = version;
        bestChannel = channel;
        bestDart = dart;
        bestOnPath = onPath;
        continue;
      }
      // نفضّل: على PATH، ثم إصدار أحدث.
      final better = (onPath && !bestOnPath) ||
          (onPath == bestOnPath &&
              (bestVersion == null ||
                  (version != null &&
                      compareVersions(version, bestVersion) > 0)));
      if (better) {
        best = root;
        bestVersion = version;
        bestChannel = channel;
        bestDart = dart;
        bestOnPath = onPath;
      }
    }

    final notes = <String>[];
    if (roots.length > 1) {
      notes.add('$roots.length Flutter SDKs found — using $best');
    }
    if (bestVersion == null) {
      notes.add('could not read a version from $best');
    }
    if (!bestOnPath) {
      notes.add('${_binOf(best!)} is not on PATH for this process');
    }

    final state = _classify(bestVersion, targetVersion);

    return InstallDetection(
      state: state,
      flutterPath: best,
      installedVersion: bestVersion,
      targetVersion: targetVersion,
      channel: bestChannel,
      dartVersion: bestDart,
      onPath: bestOnPath,
      binPath: best == null ? null : _binOf(best),
      sdkCount: roots.length,
      notes: notes,
    );
  }

  static InstallState _classify(String? installed, String? target) {
    if (installed == null) return InstallState.outdated;
    if (target == null || target.isEmpty) {
      // لا هدف: نعتبره مثبتاً (لا مقارنة ممكنة).
      return InstallState.upToDate;
    }
    final c = compareVersions(installed, target);
    if (c == 0) return InstallState.upToDate;
    return c < 0 ? InstallState.outdated : InstallState.newer;
  }

  static bool _onPath(String binDir) {
    final pathEnv = Platform.environment['PATH'] ?? '';
    final norm = binDir.replaceAll('/', Platform.pathSeparator);
    return pathEnv
        .split(Platform.isWindows ? ';' : ':')
        .any((e) => e.replaceAll('/', Platform.pathSeparator) == norm);
  }

  /// المسار التنفيذي لـ flutter داخل جذر SDK (`bin/flutter` أو `bin/flutter.bat`).
  static String _flutterRoot(String root) =>
      '${_binOf(root)}${Platform.pathSeparator}${_flutterExe()}';

  /// يشغّل `flutter --version` للتأكد الفعلي — أبطأ، يُستدعى عند الطلب فقط.
  static Future<String?> liveVersion(String root) async {
    try {
      final r = await Process.run(
        _flutterRoot(root),
        ['--version', '--machine'],
      );
      final out = '${r.stdout}${r.stderr}'.trim();
      if (out.isEmpty) return null;
      final match = RegExp(r'"frameworkVersion"\s*:\s*"([^"]+)"').firstMatch(out);
      return match?.group(1) ?? out.split('\n').first;
    } catch (_) {
      return null;
    }
  }
}

