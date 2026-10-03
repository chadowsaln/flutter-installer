import 'package:flutter/foundation.dart';

import '../services/dart_service.dart';
import '../services/flutter_service.dart';
import '../services/install_detector.dart';
import '../services/path_service.dart';
import '../services/process_service.dart';
import '../services/system_service.dart';

/// حالة التطبيق — بدون أي باك إند (لا Rust ولا سيرفر).
/// كل العمليات تتم بـ Dart وأوامر النظام مباشرة:
/// - كشف النظام عبر `Platform` (linux/macos/windows).
/// - التنزيل عبر `HttpClient` وفكّ الضغط عبر `tar`/`unzip`.
/// - الـ PATH عبر متغيرات البيئة + `export` في البروفايل أو `setx`.
///
/// App state with no backend: pure Dart + system commands.
/// Keeps the same `rpc()` surface so screens don't change.
class AppState extends ChangeNotifier {
  AppState() {
    _appendLog('local mode: no backend — Dart + system commands only');
    starting = false;
  }

  final _processes = ProcessService();

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

  String? activeTask;
  String? activeTaskDetail;

  final ValueNotifier<double?> downloadProgress = ValueNotifier(null);

  Object? error;
  bool starting = true;
  bool startingFailed = false;

  // توافق مع الواجهة القديمة — دائماً متصل محلياً.
  // Compat: always "connected" in local mode.
  bool get hasConnection => true;
  String get backendLabel => 'local (بدون باك إند)';

  /// نتيجة كشف التثبيت — هل Flutter موجود على هذا الجهاز وأي إصدار؟
  /// Cached so the shell badge and screens agree on one answer.
  InstallDetection detection = const InstallDetection.absent();

  /// هل Flutter مثبّت على هذا الجهاز فعلياً؟
  bool get flutterInstalled => detection.isInstalled;

  /// نسخة مختصرة للشارة في شريط الحالة.
  String get installedBadge {
    if (!detection.isInstalled) return 'Flutter not installed';
    final v = detection.installedVersion ?? 'unknown';
    return switch (detection.state) {
      InstallState.notInstalled => 'Flutter $v',
      InstallState.outdated => 'Flutter $v → update available',
      InstallState.upToDate => 'Flutter $v · up to date',
      InstallState.newer => 'Flutter $v · newer than target',
    };
  }

  @override
  void dispose() {
    downloadProgress.dispose();
    _processes.dispose();
    super.dispose();
  }

  void _appendLog(String line) {
    if (logBuffer.length >= logMax) logBuffer.removeAt(0);
    logBuffer.add(line);
  }

  void _onLog(String line) {
    _appendLog(line);
    notifyListeners();
  }

  void _onProgress(double pct) {
    downloadProgress.value = pct;
  }

  /// نفس واجهة الـ RPC القديمة لكن التنفيذ محلي بالكامل.
  /// Same RPC surface, fully local — no Rust, no server.
  Future<Map<String, dynamic>> rpc(
    String method, [
    Map<String, dynamic> params = const {},
  ]) async {
    switch (method) {
      case 'ping':
        return {'pong': true};
      case 'system.info':
        return SystemService.info();
      case 'system.check':
        return SystemService.check();
      case 'sdk.list':
        return {
          'flutter': FlutterService.list(),
          'dart': DartService.list(),
        };
      case 'sdk.known':
        return _known();
      case 'sdk.install': {
        final kind = params['kind'] as String? ?? 'flutter';
        if (kind == 'dart') {
          return DartService.install(
            version: params['version'] as String?,
            dir: params['dir'] as String?,
            addToPath: params['addToPath'] as bool? ?? true,
            replace: params['replace'] as bool? ?? true,
            onProgress: _onProgress,
            onLog: _onLog,
          );
        }
        return _flutterInstall(params);
      }
      case 'flutter.latest':
        return FlutterService.latest(
            (params['channel'] as String?) ?? 'stable');
      case 'flutter.install':
        return _flutterInstall(params);
      case 'flutter.list':
        return FlutterService.list();
      case 'flutter.uninstall':
        return FlutterService.uninstall(
            (params['flutterRoot'] as String?) ?? '');
      case 'dart.latest':
        return DartService.latest();
      case 'dart.install':
        return DartService.install(
          version: params['version'] as String?,
          dir: params['dir'] as String?,
          addToPath: params['addToPath'] as bool? ?? true,
          replace: params['replace'] as bool? ?? true,
          onProgress: _onProgress,
          onLog: _onLog,
        );
      case 'dart.list':
        return DartService.list();
      case 'dart.uninstall':
        return DartService.uninstall((params['dartRoot'] as String?) ?? '');
      case 'path.get':
        return PathService.get();
      case 'path.profiles':
        return PathService.profiles();
      case 'path.ensure':
        return PathService.ensure(
          (params['binDir'] as String?) ?? '',
          profile: params['profile'] as String?,
        );
      case 'path.remove':
        return PathService.remove((params['binDir'] as String?) ?? '');
      case 'process.spawn': {
        final r = await _processes.spawn(
          (params['cmd'] as String?) ?? '',
          ((params['args'] as List?) ?? const []).cast<String>(),
          cwd: params['cwd'] as String?,
          onLog: _onLog,
        );
        await refreshProcesses();
        return r;
      }
      case 'process.list':
        return _processes.list();
      case 'process.terminate': {
        final r = await _processes
            .terminate((params['pid'] as num).toInt());
        await refreshProcesses();
        return r;
      }
      case 'process.exec':
        return ProcessService.exec(
          (params['cmd'] as String?) ?? '',
          ((params['args'] as List?) ?? const []).cast<String>(),
          cwd: params['cwd'] as String?,
          timeoutMs: ((params['timeoutMs'] as num?) ?? 20000).toInt(),
        );
      default:
        throw UnsupportedError('unknown method: $method');
    }
  }

  Future<Map<String, dynamic>> _flutterInstall(
      Map<String, dynamic> params) async {
    activeTask = 'Installing flutter ${params['version'] ?? ''}...';
    _appendLog('task started: flutter ${params['version']}');
    downloadProgress.value = 0;
    notifyListeners();
    try {
      final r = await FlutterService.install(
        version: params['version'] as String?,
        channel: (params['channel'] as String?) ?? 'stable',
        dir: params['dir'] as String?,
        addToPath: params['addToPath'] as bool? ?? true,
        replace: params['replace'] as bool? ?? true,
        onProgress: _onProgress,
        onLog: _onLog,
      );
      return r;
    } finally {
      activeTask = null;
      activeTaskDetail = null;
      downloadProgress.value = null;
      notifyListeners();
    }
  }

  Future<Map<String, dynamic>> _known() async {
    Map<String, dynamic> flutter;
    try {
      flutter = await FlutterService.latest('stable');
    } catch (_) {
      flutter = {
        'version': null,
        'channel': 'stable',
        'error': 'unable to reach release feed',
      };
    }
    Map<String, dynamic> dart;
    try {
      dart = await DartService.latest();
    } catch (_) {
      dart = {'version': null, 'error': 'unable to reach dart-archive'};
    }
    return {'flutter': flutter, 'dart': dart};
  }

  // ------------------------------------------------------------- refresh --

  Future<void> refreshSystem() async {
    try {
      systemInfo = SystemService.info();
      systemChecks =
          _list((SystemService.check())['checks']);
    } catch (e) {
      systemChecks = [
        {'name': 'info', 'ok': false, 'detail': '$e', 'fix': ''}
      ];
    }
    notifyListeners();
  }

  Future<void> refreshSdks() async {
    try {
      flutterSdks =
          _list((FlutterService.list()['sdks']));
      dartSdks = _list((DartService.list()['sdks']));
      //_detection يتزامن مع قائمة SDKs حتى لا تتناقض الواجهتان.
      detection = InstallationDetector.detect(
        targetVersion: flutterLatestVersion == '—'
            ? null
            : flutterLatestVersion,
      );
    } catch (e) {
      error = e;
    }
    notifyListeners();
  }

  /// يعيد فحص التثبيت من القرص و`PATH` — يُستدعى من شاشة الإعداد الفوري.
  void refreshDetection({String? targetVersion}) {
    detection = InstallationDetector.detect(
      targetVersion: targetVersion ??
          (flutterLatestVersion == '—' ? null : flutterLatestVersion),
    );
    notifyListeners();
  }

  Future<void> refreshKnown() async {
    try {
      known = await _known();
    } catch (e) {
      known = {'error': '$e'};
    }
    notifyListeners();
  }

  Future<void> refreshPath() async {
    try {
      final entries = PathService.get()['entries'];
      if (entries is List) {
        pathEntries = entries
            .map((e) => {'entry': e.toString()})
            .toList()
            .cast<Map<String, dynamic>>();
      }
      pathProfiles = _list(PathService.profiles()['profiles']);
    } catch (e) {
      error = e;
    }
    notifyListeners();
  }

  Future<void> refreshProcesses() async {
    try {
      processes = _list((_processes.list())['processes']);
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
      systemChecks = _list((SystemService.check())['checks']);
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

  String get flutterLatestVersion =>
      (known['flutter'] as Map?)?['version']?.toString() ?? '—';

  String get dartLatestVersion =>
      (known['dart'] as Map?)?['version']?.toString() ?? '—';
}
