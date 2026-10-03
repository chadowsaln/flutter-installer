import 'dart:io';

import 'downloader.dart';
import 'path_service.dart';
import 'platform.dart';

/// إدارة Dart — نفس منطق `dart.rs` لكن بـ Dart وأوامر النظام فقط.
class DartService {
  static const _base =
      'https://storage.googleapis.com/dart-archive/channels/stable/release';

  /// مثل `dart.latest`.
  static Future<Map<String, dynamic>> latest() async {
    final v = await Downloader.fetchJson('$_base/latest/VERSION');
    final version = v['version'] as String?;
    if (version == null) throw StateError('dart VERSION missing version');
    return {'version': version, 'date': v['date']};
  }

  static String _archiveName() =>
      'dartsdk-${HostPlatform.os()}-${HostPlatform.arch()}-release.zip';

  /// مثل `dart.list`.
  static Map<String, dynamic> list() {
    final home = HostPlatform.homeDir();
    final sep = Platform.pathSeparator;
    final roots = <String>[
      '$home${sep}development${sep}dart-sdk',
      '$home${sep}dart-sdk',
      if (!Platform.isWindows) '/opt/dart-sdk',
    ];
    final pathEnv = Platform.environment['PATH'] ?? '';
    for (final d in pathEnv.split(Platform.isWindows ? ';' : ':')) {
      if (d.isEmpty || !d.endsWith('${sep}bin')) continue;
      final dartExe = Platform.isWindows ? 'dart.exe' : 'dart';
      if (File('$d$sep$dartExe').existsSync()) {
        roots.add(Directory(d).parent.path);
      }
    }
    final seen = <String>{};
    final sdks = <Map<String, dynamic>>[];
    for (final root in roots) {
      if (!seen.add(root)) continue;
      final dartExe = Platform.isWindows ? 'dart.exe' : 'dart';
      if (!File('$root${sep}bin$sep$dartExe').existsSync()) continue;
      sdks.add({
        'path': root,
        'version': _readVersion(root),
        'onPath': _onPath(root),
      });
    }
    return {'sdks': sdks};
  }

  static String? _readVersion(String root) {
    final sep = Platform.pathSeparator;
    try {
      final t = File('$root${sep}version').readAsStringSync().trim();
      if (HostPlatform.looksLikeVersion(t)) return t;
    } catch (_) {}
    try {
      final exe = '$root${sep}bin$sep${Platform.isWindows ? 'dart.exe' : 'dart'}';
      final r = Process.runSync(exe, ['--version']);
      final text = ('${r.stderr}${r.stdout}').trim();
      final m = RegExp(r'version:\s*([0-9][^\s]*)').firstMatch(text);
      if (m != null) return m.group(1);
      if (text.isNotEmpty) return text;
    } catch (_) {}
    return null;
  }

  static bool _onPath(String root) {
    final bin = '$root${Platform.pathSeparator}bin';
    return (Platform.environment['PATH'] ?? '')
        .split(Platform.isWindows ? ';' : ':')
        .any((d) => d == bin);
  }

  /// مثل `dart.install`.
  static Future<Map<String, dynamic>> install({
    String? version,
    String? dir,
    bool addToPath = true,
    bool replace = true,
    void Function(double percent)? onProgress,
    void Function(String line)? onLog,
  }) async {
    var resolved = (version ?? '').trim();
    if (resolved.isEmpty) {
      resolved = (await latest())['version'] as String;
    }
    if (!HostPlatform.looksLikeVersion(resolved)) {
      throw StateError('could not resolve a Dart SDK version');
    }

    final archive = _archiveName();
    final url = '$_base/$resolved/sdk/$archive';
    final tmp = File(
        '${Directory.systemTemp.path}${Platform.pathSeparator}flutter_installer_$archive');

    onLog?.call('task started: dart $resolved');
    await Downloader.download(
      url,
      tmp,
      onProgress == null ? null : (pct, _, _) => onProgress(pct),
    );

    final parentPath = dir != null && dir.isNotEmpty
        ? HostPlatform.expandHome(dir)
        : '${HostPlatform.homeDir()}${Platform.pathSeparator}development';
    await Directory(parentPath).create(recursive: true);

    final stage = Directory(
        '${Directory.systemTemp.path}${Platform.pathSeparator}flutter_installer_dart_stage_$resolved');
    if (stage.existsSync()) await stage.delete(recursive: true);
    await stage.create(recursive: true);
    await Downloader.extractArchive(
      archivePath: tmp.path,
      destDir: stage.path,
      onLog: (l) => onLog?.call(l),
    );

    final inner = _findSdk(stage);
    final target = '$parentPath${Platform.pathSeparator}dart-sdk';
    if (Directory(target).existsSync()) {
      if (!replace) throw StateError('$target already exists');
      await Directory(target).delete(recursive: true);
    }
    await inner.rename(target);
    try {
      await stage.delete(recursive: true);
    } catch (_) {}
    try {
      await tmp.delete();
    } catch (_) {}

    final result = <String, dynamic>{
      'path': target,
      'version': resolved,
      'addToPath': addToPath,
    };
    if (addToPath) {
      try {
        result['pathResult'] = await PathService.ensure(
            '$target${Platform.pathSeparator}bin');
      } catch (e) {
        result['pathWarning'] = '$e';
      }
    }
    onLog?.call('task completed: dart $resolved');
    return result;
  }

  static Directory _findSdk(Directory stage) {
    for (final e in stage.listSync()) {
      if (e is Directory) {
        final dartExe = Platform.isWindows ? 'dart.exe' : 'dart';
        if (File('${e.path}${Platform.pathSeparator}bin${Platform.pathSeparator}$dartExe')
            .existsSync()) {
          return e;
        }
      }
    }
    final first = stage.listSync().whereType<Directory>().firstOrNull;
    if (first != null) return first;
    throw StateError('extraction did not produce a dart-sdk directory');
  }

  /// مثل `dart.uninstall`.
  static Future<Map<String, dynamic>> uninstall(String dartRoot) async {
    final root = HostPlatform.expandHome(dartRoot);
    final sep = Platform.pathSeparator;
    final marker = Platform.isWindows ? 'dart.exe' : 'dart';
    if (!File('$root${sep}bin$sep$marker').existsSync()) {
      throw StateError('$root does not look like a Dart SDK');
    }
    await Directory(root).delete(recursive: true);
    return {'path': root, 'removed': true};
  }
}

extension<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
