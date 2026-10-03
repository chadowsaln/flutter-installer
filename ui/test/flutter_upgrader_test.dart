import 'dart:io';

import 'package:flutter_installer_ui/services/flutter_upgrader.dart';
import 'package:flutter_installer_ui/services/installer_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('probe is read-only and honest', () {
    test('a directory without .git is refused with an actionable reason', () {
      final dir = Directory.systemTemp.createTempSync('fi_up');
      addTearDown(() => dir.deleteSync(recursive: true));

      final info = FlutterUpgrader.probe(dir.path);
      expect(info.isGitCheckout, isFalse);
      expect(info.canUpgradeInPlace, isFalse);
      expect(info.reason, contains('no .git'));
      expect(info.reason, contains('full reinstall'));
    });

    test('a real git repo that is not Flutter is refused with guidance', () {
      final dir = Directory.systemTemp.createTempSync('fi_up');
      addTearDown(() => dir.deleteSync(recursive: true));
      final r = Process.runSync('git', ['init', '-q'], workingDirectory: dir.path);
      if (r.exitCode != 0) return; // git unavailable on this box

      final info = FlutterUpgrader.probe(dir.path);
      expect(info.isGitCheckout, isTrue);
      expect(info.isFlutterRepo, isFalse);
      expect(info.canUpgradeInPlace, isFalse);
      expect(info.reason, contains('flutter channel'));
    });
  });

  group('upgrade plan', () {
    test('an infeasible plan explains itself', () {
      const plan = UpgradePlan(
        root: '/x',
        feasible: false,
        problem: 'no .git',
      );
      expect(plan.alreadyCurrent, isFalse);
      expect(plan.summary, 'no .git');
    });

    test('summary reports commits, versions and local changes', () {
      const plan = UpgradePlan(
        root: '/x',
        feasible: true,
        targetBranch: 'flutter-3.48-candidate.0',
        commitsBehind: 6,
        currentVersion: '3.47.5',
        fetchedVersion: '3.48.0',
        dirtyFiles: 2,
      );
      expect(plan.alreadyCurrent, isFalse);
      expect(plan.hasLocalChanges, isTrue);
      expect(plan.summary, contains('6 commits'));
      expect(plan.summary, contains('3.47.5 → 3.48.0'));
      expect(plan.summary, contains('2 local change(s) kept'));
    });

    test('a clean up-to-date SDK is a no-op', () {
      const plan = UpgradePlan(
        root: '/x',
        feasible: true,
        commitsBehind: 0,
        currentVersion: '3.47.5',
        fetchedVersion: '3.47.5',
      );
      expect(plan.alreadyCurrent, isTrue);
      expect(plan.summary, 'Already at 3.47.5');
    });

    test('diverged history is flagged, not silently reset', () {
      const plan = UpgradePlan(
        root: '/x',
        feasible: true,
        commitsBehind: 3,
        diverged: true,
        currentVersion: '3.47.5',
      );
      expect(plan.diverged, isTrue);
      expect(plan.alreadyCurrent, isFalse);
    });
  });

  group('stage model', () {
    test('install and update pipelines are separate and labelled', () {
      expect(SetupStageLabel.installSteps, [
        SetupStage.preflight,
        SetupStage.resolve,
        SetupStage.download,
        SetupStage.extract,
        SetupStage.path,
        SetupStage.precache,
        SetupStage.verify,
      ]);
      expect(SetupStageLabel.updateSteps, [
        SetupStage.probe,
        SetupStage.fetch,
        SetupStage.merge,
        SetupStage.materialize,
        SetupStage.precache,
        SetupStage.verify,
      ]);
      // The git pipeline never downloads an archive.
      expect(SetupStageLabel.updateSteps, isNot(contains(SetupStage.download)));
      expect(SetupStageLabel.updateSteps, isNot(contains(SetupStage.extract)));
    });

    test('every stage has a non-empty label and correct activity', () {
      for (final s in SetupStage.values) {
        expect(s.label, isNotEmpty, reason: '$s has no label');
      }
      expect(SetupStage.download.isActive, isTrue);
      expect(SetupStage.merge.isActive, isTrue);
      expect(SetupStage.materialize.isActive, isTrue);
      expect(SetupStage.done.isActive, isFalse);
      expect(SetupStage.failed.isActive, isFalse);
      expect(SetupStage.idle.isActive, isFalse);
    });
  });

  group('against the SDK on this machine', () {
    test('probe reads the real checkout without touching it', () {
      // Resolved from PATH, exactly like the app does.
      final roots = <String>[];
      final pathEnv = Platform.environment['PATH'] ?? '';
      for (final entry in pathEnv.split(Platform.isWindows ? ';' : ':')) {
        if (entry.isEmpty) continue;
        if (entry.replaceAll('/', Platform.pathSeparator).endsWith(
            '${Platform.pathSeparator}bin')) {
          final parent = entry.substring(
              0, entry.length - Platform.pathSeparator.length);
          if (File('$parent${Platform.pathSeparator}bin'
                  '${Platform.pathSeparator}flutter')
              .existsSync()) {
            roots.add(parent);
          }
        }
      }
      if (roots.isEmpty) return; // no SDK here — nothing to assert

      final info = FlutterUpgrader.probe(roots.first);
      expect(info.root, roots.first);
      expect(info.isGitCheckout, isTrue,
          reason: 'official archives ship .git so flutter upgrade works');
      expect(info.remoteUrl, contains('flutter/flutter'));
      expect(info.branch, isNotEmpty);
      expect(info.rcBranch, isNotEmpty,
          reason: 'release-candidate-branch.version drives flutter upgrade');
      expect(info.canUpgradeInPlace, isTrue);
      expect(info.headSha, isNotNull);
    });
  });
}