import 'dart:convert';
import 'dart:io';

import 'install_detector.dart';
import 'installer_service.dart';

/// نتيجة فحص واحد: هل هذا SDK مستودع git يمكن تحديثه داخل مكانه؟
class GitCheckoutInfo {
  const GitCheckoutInfo({
    required this.root,
    required this.isGitCheckout,
    required this.isFlutterRepo,
    required this.canUpgradeInPlace,
    this.branch,
    this.rcBranch,
    this.remoteUrl,
    this.headSha,
    this.version,
    this.reason,
  });

  /// SDK ليس `git checkout` — لا يمكن تحديثه داخلياً.
  const GitCheckoutInfo.notGit(this.root, String this.reason)
      : isGitCheckout = false,
        isFlutterRepo = false,
        canUpgradeInPlace = false,
        branch = null,
        rcBranch = null,
        remoteUrl = null,
        headSha = null,
        version = null;

  final String root;
  final bool isGitCheckout;
  final bool isFlutterRepo;
  final bool canUpgradeInPlace;

  /// الفرع الحالي (`stable` / `beta` / …).
  final String? branch;

  /// فرع دورة الإصدار من `bin/internal/release-candidate-branch.version`.
  /// هذا هو الآلية التي يقرأ منها `flutter upgrade` هدفه.
  final String? rcBranch;

  final String? remoteUrl;
  final String? headSha;
  final String? version;

  /// سبب عدم إمكانية التحديث الداخلي — رسالة عملية للمستخدم.
  final String? reason;

  String get shortSha => (headSha ?? '').length >= 7
      ? headSha!.substring(0, 7)
      : (headSha ?? '?');
}

/// خطة تحديث محسوبة قبل التنفيذ — تُعرض للمستخدم قبل أي كتابة.
class UpgradePlan {
  const UpgradePlan({
    required this.root,
    required this.feasible,
    this.targetBranch,
    this.commitsBehind = 0,
    this.currentVersion,
    this.fetchedVersion,
    this.targetSha,
    this.dirtyFiles = 0,
    this.diverged = false,
    this.problem,
    this.newFiles,
  });

  final String root;
  final bool feasible;
  final String? targetBranch;
  final int commitsBehind;
  final String? currentVersion;
  final String? fetchedVersion;
  final String? targetSha;

  /// عدد الملفات المعدّلة محلياً داخل الـ SDK (تغييرات المستخدم).
  final int dirtyFiles;

  /// التاريخ المحلي غير متوافق مع السيرفر — fast-forward مستحيل.
  final bool diverged;

  final String? problem;

  /// ملفات جديدة في التحديث — تقدير من `git diff --stat`، ليس بايتات.
  final int? newFiles;

  bool get alreadyCurrent => feasible && commitsBehind == 0 && !diverged;
  bool get hasLocalChanges => dirtyFiles > 0;

  String get summary {
    if (!feasible) return problem ?? 'in-place update is not possible';
    if (alreadyCurrent) {
      return 'Already at $_shortCurrent';
    }
    final base = '$commitsBehind commit${commitsBehind == 1 ? '' : 's'}'
        '${targetBranch == null ? '' : ' on $targetBranch'}';
    return '$base · $_shortCurrent → $_shortTarget'
        '${hasLocalChanges ? ' · $dirtyFiles local change(s) kept' : ''}';
  }

  String get _shortCurrent => currentVersion ?? 'current';

  /// الإصدار/الـ SHA الهدف — متاح للواجهة لعرض خطة محتملة.
  String get targetLabel {
    final v = fetchedVersion;
    if (v != null) return v;
    final sha = targetSha;
    return (sha != null && sha.length >= 7) ? sha.substring(0, 7) : 'latest';
  }

  String get _shortTarget => targetLabel;
}

/// يحدّث Flutter **داخل مكانه** عبر git بدل تنزيل نسخة كاملة جديدة.
///
/// Mechanism matches `flutter upgrade` exactly:
///  1. `git fetch origin <release-candidate-branch>`
///  2. `git merge --ff-only FETCH_HEAD` (لا إعادة تنزيل 1.2GB ولا حذف/فكّ)
///  3. `flutter --version` ← يشغّل `bin/internal/update_dart_sdk.sh` فتُجسَّد
///     نسخة Dart والأدوات، وكل ما هو موجود في `bin/cache` يُعاد استخدامه.
///
/// Nothing here deletes or re-extracts the SDK: only the changed commits move.
class FlutterUpgrader {
  static String get _rcBranchFile => 'bin${Platform.pathSeparator}internal'
      '${Platform.pathSeparator}release-candidate-branch.version';

  static String _gitBinary() =>
      Platform.isWindows ? 'git.exe' : 'git';

  static (int, String, String) _run(String root, List<String> args) {
    try {
      final r = Process.runSync(_gitBinary(), args,
          workingDirectory: root,
          // يمنع git من طلب بيانات اعتماد تفاعلياً.
          environment: {
            'GIT_TERMINAL_PROMPT': '0',
            'GIT_ASKPASS': 'echo',
          });
      return (
        r.exitCode,
        (r.stdout as String).trim(),
        (r.stderr as String).trim(),
      );
    } catch (_) {
      return (127, '', 'git could not be executed');
    }
  }

  static bool _hasGit() {
    try {
      return Process.runSync(Platform.isWindows ? 'where' : 'which', ['git'])
              .exitCode ==
          0;
    } catch (_) {
      return false;
    }
  }

  /// فحص **قراءة فقط** — لا يكتب شيئاً. يُستخدم عند فتح الشاشة.
  static GitCheckoutInfo probe(String root) {
    final version = InstallationDetector.readVersion(root).$1;
    final sep = Platform.pathSeparator;

    if (!Directory('$root$sep.git').existsSync()) {
      return GitCheckoutInfo.notGit(
        root,
        'This SDK has no .git — it cannot be updated in place. '
        'Use a full reinstall instead.',
      );
    }
    if (!_hasGit()) {
      return GitCheckoutInfo(
        root: root,
        isGitCheckout: true,
        isFlutterRepo: false,
        canUpgradeInPlace: false,
        version: version,
        reason: 'git is not installed — install it to update in place',
      );
    }

    final branchResult = _run(root, ['rev-parse', '--abbrev-ref', 'HEAD']);
    final remoteResult = _run(root, ['remote', 'get-url', 'origin']);
    final headResult = _run(root, ['rev-parse', 'HEAD']);

    final isFlutterRepo = remoteResult.$1 == 0 &&
        remoteResult.$2.contains('flutter/flutter');

    String? rcBranch;
    try {
      final f = File('$root$sep$_rcBranchFile');
      if (f.existsSync()) rcBranch = f.readAsStringSync().trim();
    } catch (_) {}

    // لا يوجد فرع دورة إصدار ⇒ لا نعرف إلى أين نحدّث.
    final canUpgrade = isFlutterRepo && (rcBranch?.isNotEmpty ?? false);

    return GitCheckoutInfo(
      root: root,
      isGitCheckout: true,
      isFlutterRepo: isFlutterRepo,
      canUpgradeInPlace: canUpgrade,
      branch: branchResult.$1 == 0 ? branchResult.$2 : null,
      rcBranch: rcBranch,
      remoteUrl: remoteResult.$1 == 0 ? remoteResult.$2 : null,
      headSha: headResult.$1 == 0 ? headResult.$2 : null,
      version: version,
      reason: canUpgrade
          ? null
          : (!isFlutterRepo
              ? 'origin is not the Flutter repository — run '
                  '"flutter channel <name>" first'
              : 'no release-candidate-branch.version — channel is unknown'),
    );
  }

  /// يجلب ويحسب الخطة. `fetch` يحدّث بيانات refs فقط — لا يلمس شجرة العمل.
  static Future<UpgradePlan> plan(GitCheckoutInfo info) async {
    if (!info.canUpgradeInPlace) {
      return UpgradePlan(root: info.root, feasible: false, problem: info.reason);
    }

    final branch = info.rcBranch!;
    final (fetchCode, _, fetchErr) =
        _run(info.root, ['fetch', '--tags', '--force', 'origin', branch]);
    if (fetchCode != 0) {
      return UpgradePlan(
        root: info.root,
        feasible: false,
        problem: 'git fetch failed: ${fetchErr.isEmpty ? 'exit $fetchCode' : fetchErr}',
      );
    }

    final (_, behind, _) =
        _run(info.root, ['rev-list', '--count', 'HEAD..FETCH_HEAD']);
    final (_, ahead, _) =
        _run(info.root, ['rev-list', '--count', 'FETCH_HEAD..HEAD']);
    final (_, statusOut, _) = _run(info.root, ['status', '--porcelain']);
    final (_, targetSha, _) = _run(info.root, ['rev-parse', 'FETCH_HEAD']);
    final (_, desc, _) =
        _run(info.root, ['describe', '--tags', '--abbrev=0', 'FETCH_HEAD']);
    final (_, stat, _) = _run(
      info.root,
      ['diff', '--name-only', 'HEAD..FETCH_HEAD'],
    );

    return UpgradePlan(
      root: info.root,
      feasible: true,
      targetBranch: branch,
      commitsBehind: int.tryParse(behind) ?? 0,
      currentVersion: info.version,
      fetchedVersion: desc.isEmpty ? null : desc,
      targetSha: targetSha.isEmpty ? null : targetSha,
      dirtyFiles: statusOut.isEmpty
          ? 0
          : statusOut.split('\n').where((l) => l.trim().isNotEmpty).length,
      diverged: (int.tryParse(ahead) ?? 0) > 0,
      newFiles: stat.isEmpty ? 0 : stat.split('\n').length,
    );
  }

  /// ينفّذ التحديث داخل المكان مع تقارير حيّة — نفس مسار شاشة التنزيل.
  ///
  /// [allowHardReset] يجب أن يكون `true` فقط بعد موافقة المستخدم الصريحة،
  /// لأنه يتخلص من أي فروع/تعهدات محلية غير مدمجة.
  static Future<SetupProgress> run({
    required String root,
    required UpgradePlan plan,
    required ProgressReporter report,
    bool allowHardReset = false,
    bool precache = true,
  }) async {
    final p = SetupProgress();
    void emit() => report(p);

    Future<bool> git(List<String> args) async {
      final (code, out, err) = _run(root, args);
      if (out.isNotEmpty) p.log.add('[git] $out');
      if (err.isNotEmpty) p.log.add('! [git] $err');
      emit();
      return code == 0;
    }

    try {
      // ---------------------------------------------------------- probe
      p.stage = SetupStage.probe;
      p.log.add('SDK root: $root');
      p.log.add('branch: ${plan.targetBranch}');
      emit();

      // ---------------------------------------------------------- fetch
      p.stage = SetupStage.fetch;
      emit();
      if (!await git(['fetch', '--tags', '--force', 'origin',
        plan.targetBranch!,
      ])) {
        p.stage = SetupStage.failed;
        p.error = 'git fetch failed';
        emit();
        return p;
      }

      if (plan.commitsBehind == 0) {
        p.stage = SetupStage.done;
        p.log.add('already up to date — nothing downloaded');
        emit();
        return p;
      }

      // ---------------------------------------------------------- merge
      p.stage = SetupStage.merge;
      emit();
      p.log.add('fast-forwarding ${plan.commitsBehind} commit(s)');

      final merged = await git(
          ['merge', '--ff-only', 'FETCH_HEAD']);
      if (!merged) {
        // fast-forward فشل: إما تاريخ متشعب أو تغييرات محلية.
        if (!allowHardReset) {
          p.stage = SetupStage.failed;
          p.error = plan.diverged
              ? 'Local commits diverged from origin. Reinstall from the '
                  'archive, or confirm a hard reset to discard them.'
              : 'Fast-forward refused. Local changes are in the SDK — '
                  'reinstall from the archive to overwrite them.';
          p.log.add('! merge --ff-only refused; nothing was changed');
          emit();
          return p;
        }
        p.log.add('! merge refused — hard reset requested by the user');
        if (!await git(['reset', '--hard', 'FETCH_HEAD'])) {
          p.stage = SetupStage.failed;
          p.error = 'git reset --hard failed';
          emit();
          return p;
        }
      }

      // -------------------------------------------------------- materialize
      p.stage = SetupStage.materialize;
      emit();
      p.log.add('materialising the Dart SDK (reuses bin/cache)');
      final exe = Platform.isWindows ? 'flutter.bat' : 'flutter';
      final sep = Platform.pathSeparator;
      await _streamCommand(
        root,
        '$root$sep${'bin'}$sep$exe',
        ['--version'],
        p,
        emit,
      );

      // ------------------------------------------------------------- verify
      p.stage = SetupStage.verify;
      emit();
      final (version, channel, _) =
          InstallationDetector.readVersion(root);
      if (version == null) {
        p.stage = SetupStage.failed;
        p.error =
            'update applied but the version could not be read from '
            'bin/cache/flutter.version.json';
        emit();
        return p;
      }
      p.log.add('now on Flutter $version${channel == null ? '' : ' ($channel)'}');
      p.log.add('updated in place — no archive was downloaded');

      if (precache) {
        p.stage = SetupStage.precache;
        emit();
        await _streamCommand(root, '$root$sep${'bin'}$sep$exe',
            ['precache'], p, emit);
      }

      p.stage = SetupStage.done;
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

  /// يشغّل أمر SDK ويبثّ مخرجاته إلى السجل (bin/cache وما فيه يُعاد استخدامه).
  static Future<void> _streamCommand(
    String cwd,
    String exe,
    List<String> args,
    SetupProgress p,
    void Function() emit,
  ) async {
    try {
      p.log.add('\$ $exe ${args.join(' ')}');
      emit();
      final proc = await Process.start(exe, args,
          workingDirectory: cwd, runInShell: true);
      await proc.stdout
          .transform(const SystemEncoding().decoder)
          .transform(const LineSplitter())
          .forEach((line) {
        if (line.trim().isNotEmpty) {
          p.log.add(line);
          emit();
        }
      });
      await proc.stderr
          .transform(const SystemEncoding().decoder)
          .transform(const LineSplitter())
          .forEach((line) {
        if (line.trim().isNotEmpty) {
          p.log.add('! $line');
          emit();
        }
      });
      final code = await proc.exitCode;
      p.log.add(code == 0 ? 'exit 0' : 'exit $code');
      emit();
    } catch (e) {
      p.log.add('! $e');
      emit();
    }
  }
}