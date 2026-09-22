import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'native_core.dart';

/// A newline-delimited JSON-RPC 2.0 client for the Rust core.
///
/// Two transports are supported:
///   * in-process via [`NativeCore`] (dart:ffi) — the default, no extra
///     process/server;
///   * a daemon sidecar process (legacy/dev) — spawned from the Rust workspace
///     and driven over stdio when the shared library is unavailable.
///
/// The message pipeline is identical in both cases: one JSON object per line,
/// responses matched to pending requests by `id`, notifications routed to
/// [events].
class CoreClient {
  CoreClient._(this.daemonPath, this._send, this._stop);

  /// Label shown in the UI (library or binary path).
  final String daemonPath;
  final Future<void> Function(int id, String method, Map<String, dynamic> params)
      _send;
  final Future<void> Function() _stop;

  static const _timeout = Duration(minutes: 20);

  final _pending = <int, Completer<Map<String, dynamic>>>{};
  final _events = StreamController<Map<String, dynamic>>.broadcast();
  final _unexpected = StreamController<Map<String, dynamic>>.broadcast();
  final _outLog = StreamController<String>.broadcast();
  int _nextId = 1;

  /// Stream of server notifications (progress, log, process.stdout, ...).
  Stream<Map<String, dynamic>> get events => _events.stream;

  /// Stream of full server messages that were not matched as a response
  /// (used by the diagnostics view).
  Stream<Map<String, dynamic>> get unexpected => _unexpected.stream;

  /// Raw stderr lines from the daemon process.
  Stream<String> get daemonLog => _outLog.stream;

  /// Launches the core: prefers the in-process FFI library, and falls back to
  /// spawning the `daemon` sidecar for development.
  static Future<CoreClient> launch() async {
    final so = NativeCore.locate();
    if (so != null) {
      try {
        return await _launchFfi(so);
      } catch (e) {
        debugPrint('FFI core failed to start ($e); falling back to daemon');
      }
    }
    return _launchProcess();
  }

  static Future<CoreClient> _launchFfi(String path) async {
    final native = NativeCore.open(path);
    final client = CoreClient._(
      path,
      (id, method, params) async => native.send(id, method, params),
      () async => native.dispose(),
    );
    native.onMessage = client._onLine;
    client._outLog.add('Flutter core loaded in-process from $path');

    for (var i = 0; i < 50; i++) {
      if (await client._pingOnce()) return client;
      await Future.delayed(const Duration(milliseconds: 40));
    }
    await client.stop();
    throw StateError('flutter_core did not answer ping');
  }

  static Future<CoreClient> _launchProcess() async {
    final bin = locateDaemon();
    if (bin == null) {
      throw const DaemonNotFound();
    }
    final proc = await Process.start(
      bin,
      const [],
      mode: ProcessStartMode.normal,
    );
    final client = CoreClient._(
      bin,
      (id, method, params) async {
        proc.stdin.writeln(jsonEncode({
          'jsonrpc': '2.0',
          'id': id,
          'method': method,
          'params': params,
        }));
        await proc.stdin.flush();
      },
      () async {
        try {
          proc.kill();
        } catch (_) {}
        await proc.exitCode;
      },
    );

    proc.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(client._onLine);
    proc.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((l) {
      if (l.isNotEmpty) client._outLog.add(l);
    });
    proc.exitCode.then((_) {
      client._failAll('daemon exited');
    });

    for (var i = 0; i < 20; i++) {
      if (await client._pingOnce()) return client;
      await Future.delayed(const Duration(milliseconds: 150));
    }
    await client.stop();
    throw StateError('daemon did not respond to ping');
  }

  /// Finds the `daemon` binary (fallback transport only).
  static String? locateDaemon() {
    final env = Platform.environment['CORE_DAEMON'];
    if (env != null && File(env).existsSync()) return env;

    final cwd = Directory.current.path;
    final candidates = <String>[
      '$cwd/../core/target/release/daemon',
      '$cwd/../core/target/debug/daemon',
    ];
    for (final c in candidates) {
      final f = File(c);
      if (f.existsSync()) return f.path;
    }
    final exe = Platform.resolvedExecutable;
    final sidecar = File(
        '${File(exe).parent.path}${Platform.isWindows ? '\\daemon.exe' : '/daemon'}');
    if (sidecar.existsSync()) return sidecar.path;
    return null;
  }

  Future<bool> _pingOnce() async {
    final id = _nextId++;
    final completer = Completer<Map<String, dynamic>>();
    _pending[id] = completer;
    await _send(id, 'ping', const {});
    try {
      await completer.future.timeout(const Duration(seconds: 2));
      return true;
    } catch (_) {
      return false;
    }
  }

  void _onLine(String line) {
    if (line.trim().isEmpty) return;
    Map<String, dynamic> msg;
    try {
      msg = jsonDecode(line) as Map<String, dynamic>;
    } catch (_) {
      _unexpected.add({'method': 'raw', 'params': {'data': line}});
      return;
    }
    final id = msg['id'];
    if (id is int) {
      final c = _pending.remove(id);
      if (c != null) {
        if (msg.containsKey('error')) {
          final e = msg['error'] as Map<String, dynamic>? ?? const {};
          c.completeError(CoreError(
            code: (e['code'] as num?)?.toInt() ?? -32000,
            message: (e['message'] as String?) ?? 'unknown error',
            data: e['data'],
          ));
        } else {
          c.complete(msg['result'] as Map<String, dynamic>? ?? const {});
        }
      } else {
        _unexpected.add(msg);
      }
    } else {
      _unexpected.add(msg);
      _events.add(msg);
    }
  }

  /// Sends a request and awaits its response.
  Future<Map<String, dynamic>> call(String method,
      [Map<String, dynamic> params = const {}]) async {
    final id = _nextId++;
    final completer = Completer<Map<String, dynamic>>();
    _pending[id] = completer;
    await _send(id, method, params);
    return completer.future.timeout(_timeout, onTimeout: () {
      _pending.remove(id);
      throw TimeoutException('core did not answer $method in ${_timeout.inMinutes}m');
    });
  }

  void _failAll(String reason) {
    final gone = List.of(_pending.values);
    _pending.clear();
    for (final c in gone) {
      if (!c.isCompleted) c.completeError(StateError('core exited: $reason'));
    }
    _events.close();
  }

  Future<void> stop() => _stop();
}

class CoreError implements Exception {
  CoreError({required this.code, required this.message, this.data});
  final int code;
  final String message;
  final dynamic data;
  @override
  String toString() => 'core error $code: $message';
}

class DaemonNotFound implements Exception {
  const DaemonNotFound();
  @override
  String toString() =>
      'Rust core not found. Build it with: '
      '`cargo build --manifest-path core/Cargo.toml` '
      '(install `libflutter_core.so` alongside the app), '
      'or set CORE_FFI to its path.';
}