import 'dart:convert';
import 'dart:io';

/// وصف أصل (asset) مرفق بإصدار على GitHub Releases.
class AppAsset {
  const AppAsset({
    required this.name,
    required this.browserDownloadUrl,
    required this.size,
  });

  final String name;
  final String browserDownloadUrl;
  final int size;

  factory AppAsset.fromJson(Map<String, dynamic> json) => AppAsset(
        name: json['name'] as String? ?? '',
        browserDownloadUrl: json['browser_download_url'] as String? ?? '',
        size: json['size'] as int? ?? 0,
      );

  String get humanSize {
    if (size <= 0) return '';
    final mb = size / (1024 * 1024);
    return mb >= 1 ? '${mb.toStringAsFixed(1)} MB' : '${(size / 1024).round()} KB';
  }
}

/// إصدار منشور على الريبو.
class AppRelease {
  const AppRelease({
    required this.tagName,
    required this.name,
    required this.htmlUrl,
    required this.draft,
    required this.prerelease,
    required this.publishedAt,
    required this.body,
    required this.assets,
  });

  final String tagName;
  final String name;
  final String htmlUrl;
  final bool draft;
  final bool prerelease;
  final String publishedAt;
  final String body;
  final List<AppAsset> assets;

  factory AppRelease.fromJson(Map<String, dynamic> json) => AppRelease(
        tagName: json['tag_name'] as String? ?? '',
        name: json['name'] as String? ?? '',
        htmlUrl: json['html_url'] as String? ?? '',
        draft: json['draft'] as bool? ?? false,
        prerelease: json['prerelease'] as bool? ?? false,
        publishedAt: json['published_at'] as String? ?? '',
        body: json['body'] as String? ?? '',
        assets: (json['assets'] as List<dynamic>? ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(AppAsset.fromJson)
            .toList(),
      );
}

/// نتيجة تنزيل حزمة التحديث.
class DownloadedUpdate {
  const DownloadedUpdate({required this.path, required this.bytes});

  final String path;
  final int bytes;
}

/// فحص GitHub Releases لنسخة أحدث من التطبيق نفسه، وتنزيلها.
class AppUpdateService {
  const AppUpdateService._();

  static const String repoOwner = 'chadowsaln';
  static const String repoName = 'flutter-installer';
  static const String currentVersion = '0.1.0';

  static String get currentVersionLabel => 'v$currentVersion';

  static Uri get releasesApi => Uri.parse(
        'https://api.github.com/repos/$repoOwner/$repoName/releases/latest',
      );

  static String normalizeVersion(String value) {
    final trimmed = value.trim();
    if (trimmed.startsWith('v') || trimmed.startsWith('V')) {
      return trimmed.substring(1);
    }
    return trimmed;
  }

  /// إرجاع `true` إذا كان [candidate] أحدث من [current] (مقارنة رقمية).
  static bool isNewer(String candidate, String current) {
    final a = _numericParts(candidate);
    final b = _numericParts(current);
    final len = a.length > b.length ? a.length : b.length;
    for (var i = 0; i < len; i++) {
      final left = i < a.length ? a[i] : 0;
      final right = i < b.length ? b[i] : 0;
      if (left > right) return true;
      if (left < right) return false;
    }
    return false;
  }

  static List<int> _numericParts(String value) {
    var normalized = normalizeVersion(value);
    final plus = normalized.indexOf('+');
    if (plus >= 0) normalized = normalized.substring(0, plus);
    return normalized
        .split('.')
        .map((part) => int.tryParse(RegExp(r'\d+').firstMatch(part)?.group(0) ?? '') ?? 0)
        .toList();
  }

  static bool hasUpdate(AppRelease release) =>
      isNewer(release.tagName, currentVersion);

  /// أحدث إصدار منشور، أو `null` عند الفشل أو لو كان مسودة/معاينة.
  static Future<AppRelease?> checkForUpdates({Duration timeout = const Duration(seconds: 12)}) async {
    final client = HttpClient()..connectionTimeout = timeout;
    try {
      final request = await client.getUrl(releasesApi).timeout(timeout);
      request.headers.set(HttpHeaders.acceptHeader, 'application/vnd.github+json');
      request.headers.set(HttpHeaders.userAgentHeader, 'flutter-installer');
      final response = await request.close().timeout(timeout);
      if (response.statusCode != 200) return null;
      final payload = jsonDecode(
        await response.transform(utf8.decoder).join(),
      ) as Map<String, dynamic>;
      final release = AppRelease.fromJson(payload);
      if (release.draft || release.prerelease) return null;
      return release;
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
  }

  static const _linuxSuffixes = ['.appimage', '.deb', '.rpm', '.tar.gz'];
  static const _windowsSuffixes = ['.zip', '.msix', '.exe'];
  static const _macSuffixes = ['.dmg', '.zip'];

  /// أنسب أصل لإصدار [release] على النظام الحالي، أو `null`.
  static AppAsset? assetForCurrentPlatform(AppRelease release) {
    final suffixes = Platform.isLinux
        ? _linuxSuffixes
        : Platform.isWindows
            ? _windowsSuffixes
            : _macSuffixes;
    for (final suffix in suffixes) {
      for (final asset in release.assets) {
        if (asset.name.toLowerCase().endsWith(suffix)) return asset;
      }
    }
    return null;
  }

  /// المسار الذي يعمل منه التطبيق الآن، أو `null` غير معروف.
  static String? get runningFrom {
    final appImage = Platform.environment['APPIMAGE'];
    if (appImage != null && appImage.isNotEmpty) return appImage;
    try {
      final exe = File(Platform.resolvedExecutable).absolute.path;
      return exe;
    } catch (_) {
      return null;
    }
  }

  /// هل يمكن للتطبيق استبدال ملفه بنفسه بدون صلاحيات root؟
  static bool get canSelfReplace {
    final target = runningFrom;
    if (target == null) return false;
    try {
      final file = File(target);
      if (!file.existsSync()) return false;
      final probe = File('$target.write-probe');
      probe.writeAsStringSync('');
      probe.deleteSync();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// بديل رسومي لاسم الحزمة علىRHEL/DEB عند الحاجة لصلاحيات root.
  static String get packageManagerHint {
    if (Platform.isLinux) {
      final release = Platform.environment['ID'] ?? '';
      if (release.contains('fedora') || release.contains('rhel') || release.contains('suse')) {
        return 'sudo rpm -Uvh';
      }
      if (release.contains('arch')) return 'sudo pacman -U';
      return 'sudo apt install ./';
    }
    if (Platform.isWindows) return 'افتح ملف الـ msix/zip المُنزّل';
    return 'افتح ملف الـ dmg المُنزّل';
  }

  static Directory get downloadDirectory {
    final home = Platform.environment['HOME'] ??
        Platform.environment['USERPROFILE'] ??
        Directory.systemTemp.path;
    return Directory('$home${Platform.isWindows ? r'\' : '/'}Downloads');
  }

  /// تنزيل أصل مع تبعت تقدّم (بايت مُنزَّل / الإجمالي).
  static Future<DownloadedUpdate> downloadAsset(
    AppAsset asset, {
    void Function(int received, int total)? onProgress,
    Duration timeout = const Duration(minutes: 10),
  }) async {
    final dir = downloadDirectory;
    if (!dir.existsSync()) dir.createSync(recursive: true);
    final file = File('${dir.path}${Platform.isWindows ? r'\' : '/'}${asset.name}');
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 20);
    IOSink? sink;
    try {
      final request = await client.getUrl(Uri.parse(asset.browserDownloadUrl)).timeout(timeout);
      request.headers.set(HttpHeaders.userAgentHeader, 'flutter-installer');
      final response = await request.close().timeout(timeout);
      if (response.statusCode != 200) {
        throw HttpException('download ${asset.name} -> ${response.statusCode}');
      }
      final total = response.contentLength >= 0 ? response.contentLength : asset.size;
      sink = file.openWrite();
      var received = 0;
      await for (final chunk in response) {
        sink.add(chunk);
        received += chunk.length;
        onProgress?.call(received, total);
      }
      await sink.flush();
      await sink.close();
      sink = null;
      return DownloadedUpdate(path: file.path, bytes: received);
    } finally {
      await sink?.flush();
      await sink?.close();
      client.close(force: true);
    }
  }

  /// الأمر الذي ينفّذه المستخدم لاستبدال النسخة المثبّتة.
  static String installCommand(String downloadedPath) {
    final name = downloadedPath.split(Platform.pathSeparator).last.toLowerCase();
    if (name.endsWith('.rpm')) {
      return 'sudo rpm -Uvh ${_quote(downloadedPath)}';
    }
    if (name.endsWith('.deb')) {
      return 'sudo apt install ${_quote(downloadedPath)}';
    }
    if (name.endsWith('.pkg.tar.zst')) {
      return 'sudo pacman -U ${_quote(downloadedPath)}';
    }
    final running = runningFrom;
    if (running != null) {
      return 'sudo cp ${_quote(downloadedPath)} ${_quote(running)}';
    }
    return packageManagerHint;
  }

  static String _quote(String value) => value.contains(' ') ? '"$value"' : value;
}