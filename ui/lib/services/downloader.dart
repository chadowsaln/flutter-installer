import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// تنزيل وفك ضغط بدون باك إند:
/// - الجلب عبر `HttpClient` (مكتبة Dart القياسية).
/// - فك الضغط عبر أوامر النظام: `tar -xf` و `unzip -q -o`.
class Downloader {
  static Future<Map<String, dynamic>> fetchJson(String url) async {
    final client = HttpClient();
    try {
      final req = await client
          .getUrl(Uri.parse(url))
          .timeout(const Duration(seconds: 12));
      final resp = await req.close().timeout(const Duration(seconds: 12));
      if (resp.statusCode != 200) {
        throw HttpException('GET $url -> ${resp.statusCode}');
      }
      final text = await resp.transform(utf8.decoder).join();
      return jsonDecode(text) as Map<String, dynamic>;
    } finally {
      client.close(force: true);
    }
  }

  static Future<String> fetchText(String url) async {
    final client = HttpClient();
    try {
      final req = await client
          .getUrl(Uri.parse(url))
          .timeout(const Duration(seconds: 12));
      final resp = await req.close().timeout(const Duration(seconds: 12));
      if (resp.statusCode != 200) {
        throw HttpException('GET $url -> ${resp.statusCode}');
      }
      return await resp.transform(utf8.decoder).join();
    } finally {
      client.close(force: true);
    }
  }

  /// HEAD سريع لمعرفة حجم الملف (يفشل بصمت مثل الـ Rust).
  static Future<int?> headSize(String url) async {
    final client = HttpClient();
    try {
      final req = await client
          .headUrl(Uri.parse(url))
          .timeout(const Duration(seconds: 12));
      final resp = await req.close().timeout(const Duration(seconds: 12));
      final len = resp.headers.contentLength;
      return len >= 0 ? len : null;
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
  }

  /// تنزيل مع **استئناف** (HTTP Range) و**إعادة محاولة** exponentially.
  ///
  /// - يستأنف من حجم الملف الموجود جزئياً بعد انقطاع الشبكة.
  /// - يعيد المحاولة [retries] مرات مع انتظار متزايد.
  /// - يبلّغ عن السرعة والوقت المتبقي عبر [onProgress].
  static Future<int> downloadResumable(
    String url,
    File dest, {
    void Function(double percent, int done, int total, int speed)? onProgress,
    void Function(String)? onLog,
    int retries = 4,
  }) async {
    var attempt = 0;
    while (true) {
      attempt++;
      final existing = dest.existsSync() ? dest.lengthSync() : 0;
      try {
        return await _downloadOnce(
          url,
          dest,
          resumeFrom: existing,
          onProgress: onProgress,
        );
      } catch (e) {
        if (attempt >= retries) rethrow;
        final wait = 1 << (attempt - 1);
        onLog?.call('! download interrupted (${e.runtimeType}) — '
            'resuming in ${wait}s (attempt $attempt/$retries)');
        await Future<void>.delayed(Duration(seconds: wait));
      }
    }
  }

  static Future<int> _downloadOnce(
    String url,
    File dest, {
    required int resumeFrom,
    void Function(double percent, int done, int total, int speed)? onProgress,
  }) async {
    final client = HttpClient();
    try {
      final req = await client
          .getUrl(Uri.parse(url))
          .timeout(const Duration(seconds: 20));
      if (resumeFrom > 0) {
        req.headers.set(HttpHeaders.rangeHeader, 'bytes=$resumeFrom-');
      }
      final resp = await req.close().timeout(const Duration(seconds: 60));

      final resuming = resp.statusCode == 206;
      if (resp.statusCode != 200 && !resuming) {
        throw HttpException('GET $url -> ${resp.statusCode}');
      }

      final remaining = resp.headers.contentLength;
      final total = (remaining > 0 ? remaining + (resuming ? resumeFrom : 0) : 0);

      final sink =
          resuming ? dest.openWrite(mode: FileMode.append) : dest.openWrite();
      var done = resuming ? resumeFrom : 0;
      var lastReport = DateTime.fromMillisecondsSinceEpoch(0);
      var lastDone = done;

      try {
        await for (final chunk in resp) {
          sink.add(chunk);
          done += chunk.length;
          final now = DateTime.now();
          final dt = now.difference(lastReport).inMilliseconds;
          // نبلّغ كل ~200ms أو عند الاكتمال — يحسب السرعة الحقيقية.
          if (dt >= 200 || (total > 0 && done >= total)) {
            final speed = dt > 0 ? ((done - lastDone) * 1000 / dt).round() : 0;
            if (onProgress != null) {
              final pct = total > 0
                  ? (done / total * 100).clamp(0, 100).toDouble()
                  : 0.0;
              onProgress(pct, done, total, speed);
            }
            lastReport = now;
            lastDone = done;
          }
        }
        await sink.flush();
      } finally {
        await sink.close();
      }
      return done;
    } finally {
      client.close(force: true);
    }
  }

  /// تنزيل بسيط (بدون استئناف) — يبقى متاحاً للاستخدامات الصغيرة.
  static Future<int> download(
    String url,
    File dest,
    void Function(double percent, int done, int total)? onProgress,
  ) async {
    return downloadResumable(
      url,
      dest,
      onProgress: (pct, done, total, _) =>
          onProgress?.call(pct, done, total),
    );
  }

  /// فك الضغط عبر أوامر النظام — `unzip` لملفات zip و `tar` لملفات tar.xz.
  static Future<void> extractArchive({
    required String archivePath,
    required String destDir,
    required void Function(String line) onLog,
  }) async {
    await Directory(destDir).create(recursive: true);
    late final String cmd;
    late final List<String> args;
    if (archivePath.endsWith('.zip')) {
      cmd = 'unzip';
      args = ['-q', '-o', archivePath, '-d', destDir];
    } else if (archivePath.endsWith('.tar.xz')) {
      cmd = 'tar';
      args = ['-xf', archivePath, '-C', destDir];
    } else {
      throw UnsupportedError('unsupported archive type: $archivePath');
    }
    onLog('\$ $cmd ${args.join(' ')}');
    final r = await Process.run(cmd, args);
    final out = (r.stdout as String).trim();
    final err = (r.stderr as String).trim();
    if (out.isNotEmpty) onLog(out);
    if (err.isNotEmpty) onLog('! $err');
    if (r.exitCode != 0) {
      throw ProcessException(
          cmd, args, 'extract failed (exit ${r.exitCode})', r.exitCode);
    }
  }

  /// تشغيل أمر مع بثّ المخرجات إلى السجل — بديل `util::run` في الـ Rust.
  static Future<bool> runLogged(
    String cmd,
    List<String> args, {
    String? cwd,
    required void Function(String line) onLog,
  }) async {
    onLog('\$ $cmd ${args.join(' ')}');
    final r = await Process.run(cmd, args, workingDirectory: cwd);
    final out = (r.stdout as String).trim();
    final err = (r.stderr as String).trim();
    if (out.isNotEmpty) onLog('[$cmd] $out');
    if (err.isNotEmpty) onLog('! [$cmd] $err');
    return r.exitCode == 0;
  }

  /// صيغة بايتات سهلة القراءة: `1.2 GB` / `850 MB`.
  static String formatBytes(int bytes) {
    if (bytes <= 0) return '0 B';
    const units = ['B', 'KB', 'MB', 'GB', 'TB'];
    var value = bytes.toDouble();
    var i = 0;
    while (value >= 1024 && i < units.length - 1) {
      value /= 1024;
      i++;
    }
    return '${value.toStringAsFixed(i == 0 ? 0 : 1)} ${units[i]}';
  }

  /// صيغة السرعة: `4.2 MB/s`.
  static String formatSpeed(int bytesPerSecond) =>
      bytesPerSecond <= 0 ? '—' : '${formatBytes(bytesPerSecond)}/s';

  /// صيغة الوقت المتبقي: `2m 14s` / `48s`.
  static String formatEta(int bytesRemaining, int bytesPerSecond) {
    if (bytesPerSecond <= 0 || bytesRemaining <= 0) return '—';
    final seconds = (bytesRemaining / bytesPerSecond).round();
    if (seconds < 60) return '${seconds}s';
    if (seconds < 3600) return '${seconds ~/ 60}m ${seconds % 60}s';
    return '${seconds ~/ 3600}h ${(seconds % 3600) ~/ 60}m';
  }
}