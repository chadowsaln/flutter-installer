import 'dart:io';

import 'downloader.dart';
import 'flutter_service.dart';
import 'path_service.dart';
import 'platform.dart';
import 'system_service.dart';

/// مراحل الإعداد الفوري — كل مرحلة تُعرض في الواجهة كخطوة مرئية.
///
/// There are two independent pipelines: a fresh install (resolve → download →
/// extract) and an in-place git update (probe → fetch → merge → materialize).
enum SetupStage {
  idle,
  preflight,
  resolve,
  download,
  extract,
  path,
  precache,
  verify,
  probe,
  fetch,
  merge,
  materialize,
  done,
  failed,
}

extension SetupStageLabel on SetupStage {
  String get label => switch (this) {
        SetupStage.idle => 'جاهز',
        SetupStage.preflight => 'فحص النظام',
        SetupStage.resolve => 'تحديد الإصدار',
        SetupStage.download => 'التنزيل',
        SetupStage.extract => 'فك الضغط',
        SetupStage.path => 'ضبط PATH',
        SetupStage.precache => 'تحضير الأدوات',
        SetupStage.verify => 'التحقق',
        SetupStage.probe => 'فحص المستودع',
        SetupStage.fetch => 'جلب التغييرات',
        SetupStage.merge => 'دمج',
        SetupStage.materialize => 'تجهيز Dart',
        SetupStage.done => 'اكتمل',
        SetupStage.failed => 'فشل',
      };

  bool get isActive => switch (this) {
        SetupStage.done || SetupStage.failed || SetupStage.idle => false,
        _ => true,
      };

  /// مراحل التنزيل الكامل — تُعرض في مسار التثبيت الجديد.
  static const installSteps = [
    SetupStage.preflight,
    SetupStage.resolve,
    SetupStage.download,
    SetupStage.extract,
    SetupStage.path,
    SetupStage.precache,
    SetupStage.verify,
  ];

  /// مراحل التحديث الداخلي — تُعرض في مسار git.
  static const updateSteps = [
    SetupStage.probe,
    SetupStage.fetch,
    SetupStage.merge,
    SetupStage.materialize,
    SetupStage.precache,
    SetupStage.verify,
  ];
}

/// حالة حيّة للتقدّم — تتغير كل ~200ms أثناء التنزيل.
class SetupProgress {
  SetupStage stage = SetupStage.idle;
  double percent = 0;
  int done = 0;
  int total = 0;
  int speed = 0;
  String? error;
  final List<String> log = [];

  int get bytesRemaining => (total - done).clamp(0, total);

  /// الوقت المتبقي محسوب من السرعة الحقيقية.
  String get eta =>
      Downloader.formatEta(bytesRemaining.clamp(0, total), speed);

  String get doneLabel => Downloader.formatBytes(done);
  String get totalLabel => total > 0 ? Downloader.formatBytes(total) : '?';
  String get speedLabel => Downloader.formatSpeed(speed);
}

typedef ProgressReporter = void Function(SetupProgress progress);

/// مُثبِّت بخطوة واحدة: يفحص النظام، يحلّ الإصدار، ينزّل (مع استئناف)،
/// يفكّ الضغط، يضبط PATH عبر الأوامر، يهيّئ الأدوات، ثم يتحقق فعلياً.
///
/// A one-shot installer pipeline. Every step uses system commands —
/// no backend, no server, no daemon.
class InstallerService {
  /// يفحص النظام ويعيد ملخص الجاهزية قبل أي تثبيت.
  static SetupProgress preflight() {
    final p = SetupProgress()..stage = SetupStage.preflight;
    final checks = SystemService.check();
    final missing = (checks['missing'] as List).cast<String>();
    final arch = HostPlatform.arch();

    p.log.add('platform: ${HostPlatform.os()} · $arch · ${SystemService.distro()}');
    p.log.add('package manager: ${SystemService.packageManager() ?? 'unknown'}');
    for (final c in (checks['checks'] as List).cast<Map<String, dynamic>>()) {
      final mark = c['ok'] == true ? '✓' : '✗';
      p.log.add('$mark ${c['name']}: ${c['detail']}');
    }
    if (missing.isNotEmpty) {
      p.log.add('run: ${checks['installAll']}');
    }
    p.stage = SetupStage.idle;
    return p;
  }

  /// يحلّ هدف التثبيت (إصدار + حجم + رابط) لعرضه قبل البدء.
  static Future<Map<String, dynamic>> resolveTarget({
    String? version,
    String channel = 'stable',
  }) =>
      FlutterService.resolve(version: version, channel: channel);

  ///ثبّت Flutter خطوة بخطوة مع تقارير حيّة.
  static Future<SetupProgress> install({
    String? version,
    String channel = 'stable',
    String? dir,
    bool addToPath = true,
    bool precache = true,
    required ProgressReporter report,
  }) async {
    final p = SetupProgress();
    void emit() => report(p);

    try {
      // ---------------------------------------------------------- preflight
      p.stage = SetupStage.preflight;
      emit();
      final checks = SystemService.check();
      final missing = (checks['missing'] as List).cast<String>();
      final arch = HostPlatform.arch();
      p.log.add(
          'platform: ${HostPlatform.os()} · $arch · ${SystemService.distro()}');
      p.log.add('package manager: ${SystemService.packageManager() ?? '—'}');
      for (final c in (checks['checks'] as List).cast<Map<String, dynamic>>()) {
        p.log.add('${c['ok'] == true ? '✓' : '✗'} ${c['name']}: ${c['detail']}');
      }
      if (missing.isNotEmpty) {
        p.stage = SetupStage.failed;
        p.error = 'missing tools: ${missing.join(', ')} — '
            'run: ${checks['installAll']}';
        emit();
        return p;
      }

      // ----------------------------------------------------------- resolve
      p.stage = SetupStage.resolve;
      emit();
      final release = await FlutterService.resolve(
        version: version,
        channel: channel,
      );
      final relVersion = release['version'] as String;
      final url = release['url'] as String;
      final archiveName = (release['archive'] as String).split('/').last;
      p.log.add('resolved: Flutter $relVersion (${release['channel']})');
      p.log.add('archive: $archiveName · '
          '${Downloader.formatBytes((release['size'] as int?) ?? 0)}');

      final sep = Platform.pathSeparator;
      final parentPath = (dir != null && dir.isNotEmpty)
          ? HostPlatform.expandHome(dir)
          : '${HostPlatform.homeDir()}${sep}development';
      final flutterRoot = '$parentPath${sep}flutter';
      final flutterBin = '$flutterRoot${sep}bin';
      final flutterExe =
          Platform.isWindows ? 'flutter.bat' : 'flutter';
      final tmp = File(
          '${Directory.systemTemp.path}${sep}flutter_installer_$archiveName');
      await Directory(parentPath).create(recursive: true);

      // ---------------------------------------------------------- download
      p.stage = SetupStage.download;
      p.total = (release['size'] as int?) ?? 0;
      emit();
      if (tmp.existsSync()) {
        p.done = tmp.lengthSync();
        p.log.add('resuming: ${Downloader.formatBytes(p.done)} already on disk');
      }
      await Downloader.downloadResumable(
        url,
        tmp,
        onProgress: (pct, done, total, speed) {
          p.percent = pct;
          p.done = done;
          p.total = total > 0 ? total : p.total;
          p.speed = speed;
          emit();
        },
        onLog: (l) {
          p.log.add(l);
          emit();
        },
      );
      final bad = FlutterService.verifyArchive(tmp);
      if (bad != null) {
        p.stage = SetupStage.failed;
        p.error = 'download verification failed: $bad';
        p.log.add('! $bad');
        emit();
        return p;
      }
      p.log.add('verified archive: ${Downloader.formatBytes(tmp.lengthSync())}');
      p.percent = 100;

      // ----------------------------------------------------------- extract
      p.stage = SetupStage.extract;
      emit();
      final existing = Directory(flutterRoot);
      if (existing.existsSync()) {
        p.log.add('removing previous install at $flutterRoot');
        await existing.delete(recursive: true);
      }
      await Downloader.extractArchive(
        archivePath: tmp.path,
        destDir: parentPath,
        onLog: (l) {
          p.log.add(l);
          emit();
        },
      );
      if (!File('$flutterBin$sep$flutterExe').existsSync()) {
        p.stage = SetupStage.failed;
        p.error = 'extraction did not produce $flutterBin/$flutterExe';
        emit();
        return p;
      }
      try {
        await tmp.delete();
      } catch (_) {}

      // -------------------------------------------------------------- path
      p.stage = SetupStage.path;
      emit();
      if (addToPath) {
        try {
          final r = await PathService.ensure(flutterBin);
          p.log.add(r['added'] == true
              ? 'PATH updated in ${r['profile']}'
              : 'PATH already configured in ${r['profile']}');
        } catch (e) {
          p.log.add('! PATH warning: $e');
        }
      } else {
        p.log.add('PATH left untouched (add-to-PATH off)');
      }

      // ----------------------------------------------------------- precache
      if (precache) {
        p.stage = SetupStage.precache;
        emit();
        p.log.add('running: flutter precache (downloads engine artifacts)');
        await Downloader.runLogged(
          flutterExe == 'flutter.bat' ? 'flutter.bat' : 'flutter',
          ['precache'],
          cwd: flutterRoot,
          onLog: (l) {
            p.log.add(l);
            emit();
          },
        );
      }

      // ------------------------------------------------------------ verify
      p.stage = SetupStage.verify;
      emit();
      final v = await _verify(flutterBin, flutterExe);
      p.log.add('flutter --version: ${v ?? 'unavailable'}');
      if (v == null) {
        p.stage = SetupStage.failed;
        p.error = 'flutter did not run after install — try '
            '"$flutterBin/$flutterExe doctor"';
        emit();
        return p;
      }

      p.stage = SetupStage.done;
      p.log.add('done — Flutter $relVersion ready at $flutterRoot');
      emit();
      return p;
    } catch (e) {
      p.stage = SetupStage.failed;
      p.error = '$e';
      p.log.add('! $e');
      emit();
      return p;
    }
  }

  /// يشغّل `flutter --version` فعلياً للتحقق — لا نكتفي بوجود الملفات.
  static Future<String?> _verify(String binDir, String exe) async {
    try {
      final r = await Process.run(
        Platform.isWindows ? '$binDir${Platform.pathSeparator}$exe' : '$binDir${Platform.pathSeparator}$exe',
        ['--version', '--machine'],
      );
      final out = '${r.stdout}${r.stderr}'.trim();
      return out.isEmpty ? null : out.split('\n').first;
    } catch (_) {
      return null;
    }
  }
}