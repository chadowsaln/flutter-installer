import 'package:flutter_installer_ui/core/core_client.dart';
import 'package:flutter_test/flutter_test.dart';

/// Verifies the in-process FFI bridge: real RPC round-trips against the
/// Rust core shared library, with no daemon process or sidecar involved.
void main() {
  test('FFI core: ping, system info, sdk.known round-trip', () async {
    final client = await CoreClient.launch();

    final ping = await client.call('ping');
    expect(ping['pong'], isTrue);

    final info = await client.call('system.info');
    expect(info['os'], 'linux');
    expect(info['arch'], 'x64');

    final known = await client.call('sdk.known');
    expect((known['dart'] as Map)['version'], isNotNull);

    await client.stop();
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('FFI core: events stream carries notifications', () async {
    final client = await CoreClient.launch();
    final seen = <String>[];
    final sub = client.events.listen((e) {
      final p = (e['params'] as Map?)?['task'];
      if (e['method'] == 'log') seen.add('log');
      if (p == 'download') seen.add('progress');
    });

    final checks = await client.call('system.check');
    expect(checks['checks'], isNotEmpty);

    await Future<void>.delayed(const Duration(milliseconds: 100));
    sub.cancel();
    await client.stop();
    expect(seen.isNotEmpty, isTrue);
  }, timeout: const Timeout(Duration(minutes: 2)));
}