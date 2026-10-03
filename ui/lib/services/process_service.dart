import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// إدارة العمليات — بدون باك إند، عبر `Process.start` / `Process.run` مباشرة.
/// Process management with no backend: `Process.start` / `Process.run`.
class ProcessService {
  final _procs = <int, _Managed>{};
  final _stdoutController = StreamController<Map<String, dynamic>>.broadcast();
  final _exitController = StreamController<Map<String, dynamic>>.broadcast();

  Stream<Map<String, dynamic>> get stdoutEvents => _stdoutController.stream;
  Stream<Map<String, dynamic>> get exitEvents => _exitController.stream;

  /// مثل `process.spawn` — يشغّل أمراً ويبثّ مخرجاته.
  Future<Map<String, dynamic>> spawn(
    String cmd,
    List<String> args, {
    String? cwd,
    required void Function(String line) onLog,
  }) async {
    final proc = await Process.start(cmd, args,
        workingDirectory: cwd,
        mode: ProcessStartMode.normal,
        runInShell: true);
    _procs[proc.pid] = _Managed(exe: cmd, process: proc);
    onLog('\$ $cmd ${args.join(' ')} (pid ${proc.pid})');

    proc.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen(
      (line) {
        final msg = {'pid': proc.pid, 'data': line};
        _stdoutController.add({'type': 'stdout', ...msg});
        onLog('[${proc.pid}] $line');
      },
    );
    proc.stderr.transform(utf8.decoder).transform(const LineSplitter()).listen(
      (line) {
        final msg = {'pid': proc.pid, 'data': line};
        _stdoutController.add({'type': 'stderr', ...msg});
        onLog('[${proc.pid}] ! $line');
      },
    );
    unawaited(proc.exitCode.then((code) {
      _procs.remove(proc.pid);
      _exitController.add({'pid': proc.pid, 'code': code});
      onLog('process ${proc.pid} exited (code $code)');
    }));

    return {'pid': proc.pid, 'cmd': cmd, 'cwd': cwd};
  }

  /// مثل `process.list`.
  Map<String, dynamic> list() => {
        'processes': _procs.entries
            .map((e) => {'pid': e.key, 'exe': e.value.exe})
            .toList(),
      };

  /// مثل `process.terminate` — عبر `Process.killPid` (أمر نظام).
  Future<Map<String, dynamic>> terminate(int pid) async {
    final m = _procs.remove(pid);
    if (m == null) throw StateError('no such managed process: $pid');
    final ok = Process.killPid(pid);
    if (!ok) {
      // احتياط: قتل عبر كائن العملية.
      try {
        m.process.kill();
      } catch (_) {}
    }
    return {'pid': pid, 'terminated': true};
  }

  /// مثل `process.exec` — أمر لمرة واحدة مع التقاط المخرجات.
  static Future<Map<String, dynamic>> exec(
    String cmd,
    List<String> args, {
    String? cwd,
    int timeoutMs = 20000,
  }) async {
    final r = await Process.run(cmd, args, workingDirectory: cwd, runInShell: true)
        .timeout(Duration(milliseconds: timeoutMs));
    return {
      'code': r.exitCode,
      'stdout': r.stdout as String,
      'stderr': r.stderr as String,
    };
  }

  void dispose() {
    _stdoutController.close();
    _exitController.close();
  }
}

class _Managed {
  _Managed({required this.exe, required this.process});
  final String exe;
  final Process process;
}
