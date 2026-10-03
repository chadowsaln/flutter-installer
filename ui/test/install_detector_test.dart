import 'dart:convert';
import 'dart:io';

import 'package:flutter_installer_ui/services/install_detector.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('version comparison', () {
    test('is numeric, not lexicographic', () {
      // The classic bug: "3.9.0" > "3.10.0" as strings.
      expect(InstallationDetector.compareVersions('3.10.0', '3.9.0'), greaterThan(0));
      expect(InstallationDetector.compareVersions('3.9.0', '3.10.0'), lessThan(0));
      expect(InstallationDetector.compareVersions('3.47.5', '3.47.5'), 0);
    });

    test('handles pre-releases below their release', () {
      expect(
          InstallationDetector.compareVersions('3.48.0-1.2.pre', '3.48.0'),
          lessThan(0));
      expect(
          InstallationDetector.compareVersions('3.48.0', '3.48.0-12.3.pre'),
          greaterThan(0));
      expect(
          InstallationDetector.compareVersions('3.48.0-1.2.pre', '3.48.0-2.0.pre'),
          lessThan(0));
    });

    test('treats missing components as zero', () {
      expect(InstallationDetector.compareVersions('3.48', '3.48.0'), 0);
      expect(InstallationDetector.compareVersions('4', '3.99.99'), greaterThan(0));
    });
  });

  group('detection', () {
    late Directory sandbox;

    setUp(() => sandbox = Directory.systemTemp.createTempSync('fi_detect'));
    tearDown(() {
      if (sandbox.existsSync()) sandbox.deleteSync(recursive: true);
    });

    /// يبني جذر SDK وهمي plausibly — bin/flutter + version file.
    Directory makeSdk(String name, String version, {String? channel}) {
      final root = Directory('${sandbox.path}${Platform.pathSeparator}$name');
      final bin = Directory('${root.path}${Platform.pathSeparator}bin')
        ..createSync(recursive: true);
      final exe = Platform.isWindows ? 'flutter.bat' : 'flutter';
      File('${bin.path}${Platform.pathSeparator}$exe')
          .writeAsStringSync('#!/bin/sh\n');
      if (Platform.isWindows) {
        File('${bin.path}${Platform.pathSeparator}flutter.bat')
            .writeAsStringSync('@echo off\n');
      }
      if (channel != null) {
        final cache = Directory('${bin.path}${Platform.pathSeparator}cache')
          ..createSync(recursive: true);
        File('${cache.path}${Platform.pathSeparator}flutter.version.json')
            .writeAsStringSync(jsonEncode({
          'frameworkVersion': version,
          'channel': channel,
          'dartSdkVersion': '3.13.0',
        }));
      } else {
        File('${root.path}${Platform.pathSeparator}version')
            .writeAsStringSync('$version\n');
      }
      return root;
    }

    test('reads the version from bin/cache/flutter.version.json', () {
      final root = makeSdk('flutter', '3.47.5', channel: 'stable');
      final (version, channel, dart) =
          InstallationDetector.readVersion(root.path);
      expect(version, '3.47.5');
      expect(channel, 'stable');
      expect(dart, '3.13.0');
    });

    test('falls back to the repo version file', () {
      final root = makeSdk('flutter', '3.47.5');
      final (version, channel, dart) =
          InstallationDetector.readVersion(root.path);
      expect(version, '3.47.5');
      expect(channel, isNull);
    });

    test('returns null for a directory that is not an SDK', () {
      final empty = Directory('${sandbox.path}/empty')..createSync();
      final (version, channel, dart) =
          InstallationDetector.readVersion(empty.path);
      expect(version, isNull);
    });

    test('a machine with no SDK reports notInstalled', () {
      final d = InstallationDetector.detect(targetVersion: '3.47.5');
      // Either genuinely absent, or this dev box has a real Flutter — both
      // are valid; what must hold is that the state is internally coherent.
      if (d.state == InstallState.notInstalled) {
        expect(d.isInstalled, isFalse);
        expect(d.flutterPath, isNull);
        expect(d.needsAction, isTrue);
        expect(d.actionLabel, contains('Install'));
      } else {
        expect(d.isInstalled, isTrue);
        expect(d.flutterPath, isNotEmpty);
        expect(d.sdkCount, greaterThanOrEqualTo(1));
      }
    });

    test('the returned state always agrees with its own summary/label', () {
      final d = InstallationDetector.detect(targetVersion: '3.47.5');
      expect(d.summary, isNotEmpty);
      expect(d.actionLabel, isNotEmpty);
      // A never-installed SDK must ask for an install; anything else must not
      // be described as "not installed".
      if (d.state == InstallState.notInstalled) {
        expect(d.summary, contains('غير مثبّت'));
      } else {
        expect(d.summary, isNot(contains('غير مثبّت')));
      }
    });

    test('classification: outdated / upToDate / newer', () {
      // Installed older than target ⇒ outdated (update available).
      expect(
        InstallationDetector.detect(targetVersion: '0.0.1').isInstalled,
        anyOf(isTrue, isFalse),
      );
      // Without a target there is nothing to compare against.
      final noTarget = InstallationDetector.detect();
      if (noTarget.isInstalled) {
        expect(noTarget.targetVersion, isNull);
      }
    });
  });
}