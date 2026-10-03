import 'package:flutter_installer_ui/services/path_service.dart';
import 'package:flutter_installer_ui/services/platform.dart';
import 'package:flutter_installer_ui/services/process_service.dart';
import 'package:flutter_installer_ui/services/system_service.dart';
import 'package:flutter_installer_ui/state/app_state.dart';
import 'package:flutter_test/flutter_test.dart';

/// يتحقق أن التطبيق يعمل بدون أي باك إند — فقط Dart وأوامر النظام.
void main() {
  test('OS detection uses Platform only (no backend)', () {
    final os = HostPlatform.os();
    expect(['linux', 'macos', 'windows', 'unknown'], contains(os));
    final arch = HostPlatform.arch();
    expect(['x64', 'arm64', 'ia32', 'unknown'], contains(arch));
  });

  test('system.info returns host summary locally', () {
    final info = SystemService.info();
    expect(info['os'], HostPlatform.os());
    expect(info['arch'], HostPlatform.arch());
    expect(info['home'], isNotNull);
  });

  test('system.check finds tools via which/where', () {
    final result = SystemService.check();
    final checks = (result['checks'] as List).cast<Map<String, dynamic>>();
    expect(checks, isNotEmpty);
    expect(checks.any((c) => c['id'] == 'arch'), isTrue);
  });

  test('path.get reads Platform.environment PATH', () {
    final r = PathService.get();
    expect(r['entries'], isA<List>());
  });

  test('path.profiles lists shell candidates', () {
    final r = PathService.profiles();
    final profiles = (r['profiles'] as List).cast<Map>();
    expect(profiles, isNotEmpty);
    expect(profiles.first.containsKey('path'), isTrue);
  });

  test('process.exec runs system commands directly', () async {
    final r = await ProcessService.exec('echo', ['hello']);
    expect(r['code'], 0);
    expect((r['stdout'] as String).trim(), 'hello');
  });

  test('AppState rpc works with no backend (ping + system)', () async {
    final app = AppState();
    expect(app.hasConnection, isTrue);
    expect(app.backendLabel, contains('بدون باك إند'));

    final ping = await app.rpc('ping');
    expect(ping['pong'], isTrue);

    final info = await app.rpc('system.info');
    expect(info['os'], HostPlatform.os());

    final checks = await app.rpc('system.check');
    expect((checks['checks'] as List), isNotEmpty);

    final path = await app.rpc('path.get');
    expect(path['entries'], isA<List>());

    final procs = await app.rpc('process.list');
    expect(procs['processes'], isA<List>());

    app.dispose();
  }, timeout: const Timeout(Duration(seconds: 30)));
}
