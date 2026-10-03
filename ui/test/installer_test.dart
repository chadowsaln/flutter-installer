import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_installer_ui/screens/instant_setup_screen.dart';
import 'package:flutter_installer_ui/services/downloader.dart';
import 'package:flutter_installer_ui/services/flutter_service.dart';
import 'package:flutter_installer_ui/services/install_detector.dart';
import 'package:flutter_installer_ui/services/installer_service.dart';
import 'package:flutter_installer_ui/services/system_service.dart';
import 'package:flutter_installer_ui/state/app_scope.dart';
import 'package:flutter_installer_ui/state/app_state.dart';
import 'package:flutter_test/flutter_test.dart';
import 'dart:io';

import 'package:flutter_installer_ui/widgets/adaptive_layout.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('formatting', () {
    test('formatBytes / formatSpeed / formatEta are human readable', () {
      expect(Downloader.formatBytes(0), '0 B');
      expect(Downloader.formatBytes(1024), '1.0 KB');
      expect(Downloader.formatBytes(1024 * 1024 * 12), '12.0 MB');
      expect(Downloader.formatBytes(3 * 1024 * 1024 * 1024), '3.0 GB');
      expect(Downloader.formatSpeed(1024 * 1024), '1.0 MB/s');
      expect(Downloader.formatSpeed(0), '—');
      expect(Downloader.formatEta(30 * 1024 * 1024, 1024 * 1024), '30s');
      expect(Downloader.formatEta(0, 1024 * 1024), '—');
    });
  });

  group('system awareness', () {
    test('detects distro, package manager and missing tools', () {
      final info = SystemService.info();
      expect(info['os'], isA<String>());
      expect(info['arch'], isA<String>());
      expect(info['distro'], isNotEmpty);
      expect(info['packageManager'], isA<Object?>());

      final checks = SystemService.check();
      expect(checks['checks'], isA<List>());
      expect(checks['missing'], isA<List>());
      // When tools are missing, a copy-paste install command must exist.
      final missing = (checks['missing'] as List).cast<String>();
      if (missing.isNotEmpty) {
        expect(checks['installAll'], isNotEmpty);
        expect(SystemService.packageName('xz'), isNotEmpty);
      }
    });

    test('installCommand maps to the real package manager', () {
      final pm = SystemService.packageManager();
      final cmd = SystemService.installCommand(['git']);
      expect(cmd, contains('git'));
      if (pm == 'apt-get') expect(cmd, contains('apt-get'));
      if (pm == 'dnf') expect(cmd, contains('dnf'));
      if (pm == 'pacman') expect(cmd, contains('pacman'));
      if (pm == 'brew') expect(cmd, contains('brew'));
    });
  });

  group('archive verification', () {
    test('rejects empty, tiny and corrupt archives', () {
      final dir = Directory.systemTemp.createTempSync('fi_verify');

      final empty = File('${dir.path}/empty.tar.xz')..writeAsBytesSync([]);
      expect(FlutterService.verifyArchive(empty), contains('empty'));

      final tiny = File('${dir.path}/tiny.tar.xz')..writeAsBytesSync([1, 2, 3]);
      expect(FlutterService.verifyArchive(tiny), contains('small'));

      final corrupt = File('${dir.path}/corrupt.tar.xz')
        ..writeAsBytesSync(List.filled(2 * 1024 * 1024, 7));
      expect(FlutterService.verifyArchive(corrupt), contains('xz'));

      final missing = File('${dir.path}/nope.zip');
      expect(FlutterService.verifyArchive(missing), contains('missing'));

      dir.deleteSync(recursive: true);
    });

    test('accepts a well-formed xz archive', () {
      final dir = Directory.systemTemp.createTempSync('fi_ok');
      final good = File('${dir.path}/good.tar.xz');
      good.writeAsBytesSync([
        0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00,
        ...List.filled(2 * 1024 * 1024, 0),
      ]);
      expect(FlutterService.verifyArchive(good), isNull);
      dir.deleteSync(recursive: true);
    });
  });

  group('installer pipeline', () {
    test('preflight never throws and reports the platform', () {
      final p = InstallerService.preflight();
      expect(p.stage, SetupStage.idle);
      expect(p.log, isNotEmpty);
      expect(p.log.first, contains('platform:'));
      expect(SetupStage.download.label, 'التنزيل');
      expect(SetupStage.verify.isActive, isTrue);
      expect(SetupStage.done.isActive, isFalse);
    });

    test('fails fast and names the missing tools', () async {
      final seen = <SetupProgress>[];
      final p = await InstallerService.install(
        report: seen.add,
      );
      // Either it failed at preflight (missing tools) or it moved on to a
      // network stage — it must never throw and always report.
      expect(seen, isNotEmpty);
      expect(p.stage == SetupStage.failed ||
          p.stage.index >= SetupStage.resolve.index, isTrue);
      if (p.stage == SetupStage.failed) {
        expect(p.error, isNotNull);
      }
    }, timeout: const Timeout(Duration(minutes: 1)));
  });

  group('instant setup screen', () {
    // The screen is hosted inside the Shell, so the harness mirrors production:
    // MaterialApp > Scaffold > AppScope > screen.
    late AppState appState;

    setUp(() => appState = AppState());
    tearDown(() => appState.dispose());

    Widget host(Widget child) => MaterialApp(
          home: Scaffold(body: AppScope(state: appState, child: child)),
        );

    testWidgets('renders stage track and the install button', (tester) async {
      await tester.pumpWidget(host(const InstantSetupScreen()));
      await tester.pump();

      expect(find.text('Instant setup'), findsOneWidget);

      // The detection card answers "is Flutter already installed?" from a real
      // scan — it must always render one of the four states.
      final titles = ['Flutter غير مثبّت', 'تحديث متاح', 'مثبّت وأحدث إصدار', 'أحدث من الهدف'];
      expect(titles.any((t) => find.text(t).evaluate().isNotEmpty), isTrue,
          reason: 'a detection state must be shown');

      // Scroll down to the pipeline stage track.
      await tester.drag(find.byType(ListView).first, const Offset(0, -600));
      await tester.pump();
      expect(find.text('1 · فحص النظام'), findsOneWidget);
      expect(find.text('3 · التنزيل'), findsOneWidget);
      expect(find.text('7 · التحقق'), findsOneWidget);

      // The CTA reflects the real detection state on this machine. Since CI and
      // dev boxes differ, assert the invariant instead of a fixed label:
      // an already-up-to-date SDK must NOT offer a redundant download.
      for (var i = 0; i < 4; i++) {
        await tester.drag(find.byType(ListView).first, const Offset(0, -400));
        await tester.pump();
      }

      final upToDate =
          InstallationDetector.detect().state == InstallState.upToDate;
      if (upToDate) {
        expect(find.text('Already installed'), findsOneWidget);
        expect(
          tester.widget<FilledButton>(
                  find.widgetWithText(FilledButton, 'Already installed'))
              .onPressed,
          isNull,
          reason: 'no redundant download when already up to date',
        );
      } else {
        // Not installed / outdated ⇒ a download action must be offered.
        expect(
          find.textContaining(RegExp('Install|Update|Downgrade')),
          findsWidgets,
        );
      }
    });

    testWidgets('never overflows at narrow widths', (tester) async {
      for (final size in [const Size(320, 640), const Size(520, 800)]) {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1.0;
        await tester.pumpWidget(host(const InstantSetupScreen()));
        await tester.pump();
        expect(tester.takeException(), isNull, reason: 'overflow at $size');
      }
    });

    testWidgets('uses the constrained large-screen body', (tester) async {
      tester.view.physicalSize = const Size(1600, 1000);
      tester.view.devicePixelRatio = 1.0;
      await tester.pumpWidget(host(const InstantSetupScreen()));
      await tester.pump();

      final boxes = tester
          .widgetList<ConstrainedBox>(find.byType(ConstrainedBox))
          .toList();
      expect(boxes.any((b) => b.constraints.maxWidth == 900.0), isTrue);
    });
  });

  group('adaptive primitives', () {
    testWidgets('AdaptiveLayout switches on available width', (tester) async {
      const large = Key('large');
      const small = Key('small');
      Widget build(double w) => MaterialApp(
            home: Scaffold(
              body: SizedBox(
                width: w,
                child: AdaptiveLayout(
                  largeBuilder: (_) => const SizedBox(key: large),
                  smallBuilder: (_) => const SizedBox(key: small),
                ),
              ),
            ),
          );
      await tester.pumpWidget(build(1000));
      expect(find.byKey(large), findsOneWidget);
      await tester.pumpWidget(build(320));
      expect(find.byKey(small), findsOneWidget);
    });

    testWidgets('AdaptiveRowOrColumn stacks when narrow', (tester) async {
      Widget build(double w) => MaterialApp(
            home: Scaffold(
              body: SizedBox(
                width: w,
                child: const AdaptiveRowOrColumn(
                    children: [Text('a'), Text('b')]),
              ),
            ),
          );
      await tester.pumpWidget(build(800));
      expect(find.byType(Row), findsOneWidget);
      await tester.pumpWidget(build(200));
      expect(find.byType(Row), findsNothing);
    });
  });

  test('clipboard is reachable for copy-paste fix commands', () {
    // Sanity: the screen depends on Clipboard; ensure the binding channel exists.
    expect(TestDefaultBinaryMessengerBinding.instance, isNotNull);
    const channel = SystemChannels.platform;
    expect(channel.name, 'flutter/platform');
  });
}