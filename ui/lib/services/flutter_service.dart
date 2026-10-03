import 'dart:convert';
import 'dart:io';

import 'downloader.dart';
import 'path_service.dart';
import 'platform.dart';

/// إدارة Flutter — نفس منطق `flutter.rs` لكن بـ Dart وأوامر النظام فقط.
/// يكتشف النظام (`linux/macos/windows`) ويختار الأرشيف المناسب من سيرفرات
/// Flutter الرسمية، ثم ينزّل ويفكّ الضغط عبر `tar`/`unzip`.
class FlutterService {
  static const _releasesBase =
      'https://storage.googleapis.com/flutter_infra_release/releases';

  static Future<Map<String, dynamic>> _fetchFeed() async {
    final url = '$_releasesBase/releases_${HostPlatform.os()}.json';
    return Downloader.fetchJson(url);
  }

  static Map<String, dynamic> _resolveFromFeed(
    Map<String, dynamic> feed,
    String? version,
    String channel,
  ) {
    final releases = (feed['releases'] as List).cast<Map<String, dynamic>>();
    Map<String, dynamic>? pick;
    if (version != null && version.isNotEmpty) {
      for (final r in releases) {
        if (r['version'] == version) {
          pick = r;
          break;
        }
      }
      if (pick == null) {
        throw StateError('Flutter version $version was not found in the release feed');
      }
    } else if (channel == 'master') {
      for (final r in releases) {
        if (r['channel'] == 'master') {
          pick = r;
          break;
        }
      }
    } else {
      final current = feed['current_release'] as Map<String, dynamic>;
      final hash = current[channel] as String?;
      if (hash == null) throw StateError("channel '$channel' has no current release");
      for (final r in releases) {
        if (r['hash'] == hash) {
          pick = r;
          break;
        }
      }
    }
    if (pick == null) throw StateError('no matching release found');
    return {
      'version': pick['version'] ?? 'unknown',
      'channel': pick['channel'] ?? channel,
      'hash': pick['hash'] ?? '',
      'archive': pick['archive'] ?? '',
      'dartVersion': pick['dart_sdk_version'],
    };
  }

  /// مثل `flutter.latest`.
  static Future<Map<String, dynamic>> latest(String channel) async {
    final feed = await _fetchFeed();
    final r = _resolveFromFeed(feed, null, channel);
    final url = '$_releasesBase/${r['archive']}';
    final size = await Downloader.headSize(url);
    return {...r, 'url': url, 'size': size};
  }

  /// يحلّ إصداراً محدداً أو الأحدث على قناة — مع الحجم والرابط.
  /// يُستخدم لعرض "الهدف" قبل التثبيت في شاشة الإعداد الفوري.
  static Future<Map<String, dynamic>> resolve({
    String? version,
    String channel = 'stable',
  }) async {
    final feed = await _fetchFeed();
    final r = _resolveFromFeed(feed, version, channel);
    final url = '$_releasesBase/${r['archive']}';
    final size = await Downloader.headSize(url);
    return {...r, 'url': url, 'size': size};
  }

  /// التحقق بعد التنزيل: الأرشيف موجود وله حجم معقول وبنية سليمة.
  /// Post-download sanity check: non-empty, plausible size, valid archive.
  static String? verifyArchive(File archive) {
    if (!archive.existsSync()) return 'archive missing after download';
    final size = archive.lengthSync();
    if (size == 0) return 'archive is empty (0 bytes)';
    if (size < 1024 * 1024) {
      return 'archive is implausibly small '
          '(${Downloader.formatBytes(size)}) — likely an error page';
    }
    final sig = _magicBytes(archive);
    if (archive.path.endsWith('.zip')) {
      // zip local file header: 50 4B
      if (sig.length < 2 || sig[0] != 0x50 || sig[1] != 0x4B) {
        return 'not a valid zip archive (bad signature)';
      }
    } else {
      // xz magic: FD 37 7A 58 5A 00
      const xz = [0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00];
      if (sig.length < xz.length) return 'archive too short to validate';
      for (var i = 0; i < xz.length; i++) {
        if (sig[i] != xz[i]) return 'not a valid xz archive (bad signature)';
      }
    }
    return null;
  }

  /// يقرأ أول [n] بايت للتحقق من التوقيع — دون تحميل الملف كاملاً.
  static List<int> _magicBytes(File f, [int n = 6]) {
    try {
      final raf = f.openSync();
      final bytes = raf.readSync(n);
      raf.closeSync();
      return bytes;
    } catch (_) {
      return const [];
    }
  }

  /// مثل `flutter.list` — يبحث في الأماكن المعتادة + مداخل PATH.
  static Map<String, dynamic> list() {
    final home = HostPlatform.homeDir();
    final sep = Platform.pathSeparator;
    final roots = <String>[
      '$home${sep}development${sep}flutter',
      '$home${sep}flutter',
      if (!Platform.isWindows) '/opt/flutter',
    ];
    final pathEnv = Platform.environment['PATH'] ?? '';
    for (final d in pathEnv.split(Platform.isWindows ? ';' : ':')) {
      if (d.isEmpty) continue;
      final dir = Directory(d);
      if (dir.path.endsWith('${sep}bin')) {
        final flutterExe = Platform.isWindows ? 'flutter.bat' : 'flutter';
        if (File('${dir.path}$sep$flutterExe').existsSync()) {
          roots.add(Directory(dir.path).parent.path);
        }
      }
    }
    final seen = <String>{};
    final sdks = <Map<String, dynamic>>[];
    for (final root in roots) {
      if (!seen.add(root)) continue;
      final marker = Platform.isWindows ? 'flutter.bat' : 'flutter';
      if (!File('$root${sep}bin$sep$marker').existsSync()) continue;
      final (version, channel, dart) = _readSdkVersion(root);
      sdks.add({
        'path': root,
        'version': version,
        'channel': channel,
        'dartVersion': dart,
        'onPath': _onPath(root),
      });
    }
    return {'sdks': sdks};
  }

  static (String?, String?, String?) _readSdkVersion(String root) {
    final sep = Platform.pathSeparator;
    final cache = File('$root${sep}bin${sep}cache${sep}flutter.version.json');
    if (cache.existsSync()) {
      try {
        final v = jsonDecode(cache.readAsStringSync()) as Map<String, dynamic>;
        return (
          v['frameworkVersion'] as String?,
          v['channel'] as String?,
          v['dartSdkVersion'] as String?,
        );
      } catch (_) {}
    }
    final vf = File('$root${sep}version');
    if (vf.existsSync()) {
      final t = vf.readAsStringSync().trim();
      if (HostPlatform.looksLikeVersion(t)) return (t, null, null);
    }
    return (null, null, null);
  }

  static bool _onPath(String root) {
    final bin = '$root${Platform.pathSeparator}bin';
    final pathEnv = Platform.environment['PATH'] ?? '';
    return pathEnv
        .split(Platform.isWindows ? ';' : ':')
        .any((d) => d == bin);
  }

  /// مثل `flutter.install` — تنزيل عبر `HttpClient` وفكّ عبر أوامر النظام.
  static Future<Map<String, dynamic>> install({
    String? version,
    String channel = 'stable',
    String? dir,
    bool addToPath = true,
    bool replace = true,
    void Function(double percent)? onProgress,
    void Function(String line)? onLog,
  }) async {
    final feed = await _fetchFeed();
    final release = _resolveFromFeed(feed, version, channel);
    final relVersion = release['version'] as String;

    final parentPath = dir != null && dir.isNotEmpty
        ? HostPlatform.expandHome(dir)
        : '${HostPlatform.homeDir()}${Platform.pathSeparator}development';
    await Directory(parentPath).create(recursive: true);

    final archiveName =
        (release['archive'] as String).split('/').last;
    final tmp = File(
        '${Directory.systemTemp.path}${Platform.pathSeparator}flutter_installer_$archiveName');

    onLog?.call('task started: flutter $relVersion');
    await Downloader.download(
      '$_releasesBase/${release['archive']}',
      tmp,
      onProgress == null
          ? null
          : (pct, done, total) => onProgress(pct),
    );

    final flutterRoot = '$parentPath${Platform.pathSeparator}flutter';
    if (Directory(flutterRoot).existsSync()) {
      if (!replace) {
        throw StateError('$flutterRoot already exists; pass replace: true to overwrite');
      }
      await Directory(flutterRoot).delete(recursive: true);
    }

    onLog?.call('Extracting $flutterRoot ...');
    await Downloader.extractArchive(
      archivePath: tmp.path,
      destDir: parentPath,
      onLog: (l) => onLog?.call(l),
    );
    try {
      await tmp.delete();
    } catch (_) {}

    final binMarker = Platform.isWindows ? 'flutter.bat' : 'flutter';
    if (!File('$flutterRoot${Platform.pathSeparator}bin${Platform.pathSeparator}$binMarker')
        .existsSync()) {
      throw StateError('extraction did not produce $flutterRoot/bin/$binMarker');
    }

    final result = <String, dynamic>{
      'path': flutterRoot,
      'version': relVersion,
      'channel': release['channel'],
      'dartVersion': release['dartVersion'],
      'addToPath': addToPath,
    };
    if (addToPath) {
      try {
        result['pathResult'] = await PathService.ensure(
            '$flutterRoot${Platform.pathSeparator}bin');
      } catch (e) {
        result['pathWarning'] = '$e';
      }
    }
    onLog?.call('task completed: flutter $relVersion');
    return result;
  }

  /// مثل `flutter.uninstall`.
  static Future<Map<String, dynamic>> uninstall(String flutterRoot) async {
    final root = HostPlatform.expandHome(flutterRoot);
    final sep = Platform.pathSeparator;
    final marker = Platform.isWindows ? 'flutter.bat' : 'flutter';
    if (!File('$root${sep}bin$sep$marker').existsSync()) {
      throw StateError('$root does not look like a Flutter SDK');
    }
    await Directory(root).delete(recursive: true);
    return {'path': root, 'removed': true};
  }
}
