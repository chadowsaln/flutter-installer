import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/core_client.dart';

/// Holds the [CoreClient] connection and the cached knowledge pulled from the
/// daemon: system info + checks, SDK lists, known versions, PATH and running
/// processes. Screens call [refresh] and rebuild via [ChangeNotifier].
class AppState extends ChangeNotifier {
  CoreClient? _client;

  Map<String, dynamic> systemInfo = const {};
  List<Map<String, dynamic>> systemChecks = const [];
  List<Map<String, dynamic>> flutterSdks = const [];
  List<Map<String, dynamic>> dartSdks = const [];
  Map<String, dynamic> known = const {};

  List<Map<String, dynamic>> pathEntries = const [];
  List<Map<String, dynamic>> pathProfiles = const [];

  List<Map<String, dynamic>> processes = const [];

  final List<String> logBuffer = [];
  final int logMax = 2000;

  /// Last install task + version running (from task.started / completed).
  String? activeTask;
  String? activeTaskDetail;

  /// Latest download progress percent (0..100) or null when idle.
  final ValueNotifier<double?> downloadProgress = ValueNotifier(null);

  Object? error; // connection-level error shown in the shell
  bool starting = true;
  bool startingFailed = false;

  AppState() {
    _bootstrap();
  }

  CoreClient? get client => _client;

  @override
  void dispose() {
    downloadProgress.dispose();
    _client?.stop();
    super.dispose();
  }

  Future<void> _bootstrap() async {
    try {
      final c = await CoreClient.launch();
      _client = c;

      _subscribe();
    } catch (e) {
      error = e;
      startingFailed = true;
    }
    starting = false;
    notifyListeners();
  }

  void _subscribe() {
    final c = _client!;
    c.events.listen((msg) {
      _routeEvent(msg);
    });
    c.daemonLog.listen((line) {
      _appendLog('daemon> $line');
    });
  }

  void _routeEvent(Map<String, dynamic> msg) {
    final method = msg['method'] as String?;
    final p = msg['params'] as Map<String, dynamic>? ?? const {};
    switch (method) {
      case 'progress':
        final pct = (p['percent'] as num?)?.toStringAsFixed(1) ?? '?';
        final url = (p['url'] as String?)?.split('/').last ?? '';
        downloadProgress.value = (p['percent'] as num?)?.toDouble();
        activeTaskDetail = 'Downloading $url ($pct%)';
        break;
      case 'log':
        _appendLog((p['level'] as String? ?? 'info') == 'warn'
            ? '! ${p['message']}'
            : '${p['message']}');
        break;
      case 'task.started':
        activeTask = 'Installing ${p['id']} ${p['version']}...';
        _appendLog('task started: ${p['id']} ${p['version']}');
        break;
      case 'task.completed':
        activeTask = null;
        activeTaskDetail = null;
        downloadProgress.value = null;
        _appendLog('task completed: ${p['id']} ${p['version']}');
        break;
      case 'process.stdout':
        _appendLog('[${p['pid']}] ${p['data']}');
        break;
      case 'process.stderr':
        _appendLog('[${p['pid']}] ! ${p['data']}');
        break;
      case 'process.exit':
        _appendLog('process ${p['pid']} exited (code ${p['code']})');
        processes = processes.where((e) => e['pid'] != p['pid']).toList();
        break;
      default:
        break;
    }
    notifyListeners();
  }

  void _appendLog(String line) {
    if (logBuffer.length >= logMax) logBuffer.removeAt(0);
    logBuffer.add(line);
  }

  /// Sends one request and returns the parsed result object.
  Future<Map<String, dynamic>> rpc(String method,
      [Map<String, dynamic> params = const {}]) async {
    final c = _client;
    if (c == null) throw StateError('core not connected');
    return c.call(method, params);
  }

  // ------------------------------------------------------------- refresh --

  Future<void> refreshSystem() async {
    try {
      systemInfo = await rpc('system.info');
      systemChecks = _list(systemInfo['checks']);
    } catch (e) {
      systemChecks = [{'name': 'info', 'ok': false, 'detail': '$e', 'fix': ''}];
    }
    notifyListeners();
  }

  Future<void> refreshSdks() async {
    try {
      final s = await rpc('sdk.list');
      flutterSdks = _sdkList(s, 'flutter');
      dartSdks = _sdkList(s, 'dart');
    } catch (e) {
      error = e;
    }
    notifyListeners();
  }

  Future<void> refreshKnown() async {
    try {
      known = await rpc('sdk.known');
    } catch (e) {
      known = {'error': '$e'};
    }
    notifyListeners();
  }

  Future<void> refreshPath() async {
    try {
      final r = await rpc('path.get');
      final entries = r['entries'];
      if (entries is List) {
        pathEntries = entries
            .map((e) => {'entry': e.toString()})
            .toList()
            .cast<Map<String, dynamic>>();
      }
      final rawProfiles = (await rpc('path.profiles'))['profiles'];
      pathProfiles = _list(rawProfiles);
    } catch (e) {
      error = e;
    }
    notifyListeners();
  }

  Future<void> refreshProcesses() async {
    try {
      processes = _list((await rpc('process.list'))['processes']);
    } catch (e) {
      error = e;
    }
    notifyListeners();
  }

  Future<void> refreshAll() async {
    await Future.wait([
      refreshSystem(),
      refreshSdks(),
      refreshKnown(),
      refreshPath(),
      refreshProcesses(),
    ]);
  }

  Future<void> runChecks() async {
    try {
      final r = await rpc('system.check');
      systemChecks = _list(r['checks']);
    } catch (e) {
      error = e;
    }
    notifyListeners();
  }

  // ------------------------------------------------------------- helpers --

  static List<Map<String, dynamic>> _list(dynamic v) {
    if (v is List) {
      return v
          .whereType<Map>()
          .map((e) => e.map((k, v) => MapEntry('$k', v)))
          .toList();
    }
    return const [];
  }

  static List<Map<String, dynamic>> _sdkList(Map<String, dynamic> sdkResult, String kind) {
    final inner = sdkResult[kind];
    if (inner is Map) return _list(inner['sdks']);
    return const [];
  }

  String get flutterLatestVersion =>
      (known['flutter'] as Map?)?['version']?.toString() ?? '—';

  String get dartLatestVersion =>
      (known['dart'] as Map?)?['version']?.toString() ?? '—';

  bool get hasConnection => _client != null;
}