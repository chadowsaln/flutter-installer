import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';

class AppRelease {
  final String tagName;
  final String name;
  final String htmlUrl;
  final bool draft;
  final bool prerelease;
  final List<AppAsset> assets;
  final String body;

  AppRelease({
    required this.tagName,
    required this.name,
    required this.htmlUrl,
    required this.draft,
    required this.prerelease,
    required this.assets,
    required this.body,
  });

  factory AppRelease.fromJson(Map<String, dynamic> json) {
    return AppRelease(
      tagName: json['tag_name'] as String? ?? '',
      name: json['name'] as String? ?? '',
      htmlUrl: json['html_url'] as String? ?? '',
      draft: json['draft'] as bool? ?? false,
      prerelease: json['prerelease'] as bool? ?? false,
      assets: (json['assets'] as List<dynamic>? ?? [])
          .map((e) => AppAsset.fromJson(e as Map<String, dynamic>))
          .toList(),
      body: json['body'] as String? ?? '',
    );
  }
}

class AppAsset {
  final String name;
  final String browserDownloadUrl;
  final int size;

  AppAsset({
    required this.name,
    required this.browserDownloadUrl,
    required this.size,
  });

  factory AppAsset.fromJson(Map<String, dynamic> json) {
    return AppAsset(
      name: json['name'] as String? ?? '',
      browserDownloadUrl: json['browser_download_url'] as String? ?? '',
      size: json['size'] as int? ?? 0,
    );
  }
}

class AppUpdateService {
  static const String repoOwner = 'chadowsaln';
  static const String repoName = 'flutter-installer';
  static const String currentVersion = '0.1.0';

  static String _normalizeVersion(String v) {
    if (v.startsWith('v') || v.startsWith('V')) {
      return v.substring(1);
    }
    return v;
  }

  static bool _isNewer(String latest, String current) {
    try {
      List<int> parse(String s) {
        return _normalizeVersion(s)
            .split('.')
            .map((e) => int.tryParse(RegExp(r'\d+').firstMatch(e)?.group(0) ?? '0') ?? 0)
            .toList();
      }

      final l = parse(latest);
      final c = parse(current);
      final maxLen = l.length > c.length ? l.length : c.length;
      for (int i = 0; i < maxLen; i++) {
        final lv = i < l.length ? l[i] : 0;
        final cv = i < c.length ? c[i] : 0;
        if (lv > cv) return true;
        if (lv < cv) return false;
      }
      return false;
    } catch (_) {
      return false;
    }
  }

  static Future<AppRelease?> checkForUpdates() async {
    try {
      final client = HttpClient();
      client.connectionTimeout = const Duration(seconds: 10);
      final uri = Uri.parse(
        'https://api.github.com/repos/$repoOwner/$repoName/releases/latest',
      );
      final request = await client.getUrl(uri);
      request.headers.set('User-Agent', 'flutter-installer');
      final response = await request.close();
      if (response.statusCode != 200) {
        return null;
      }
      final body = await response.transform(utf8.decoder).join();
      final json = jsonDecode(body) as Map<String, dynamic>;
      final release = AppRelease.fromJson(json);
      if (release.draft || release.prerelease) {
        return null;
      }
      client.close();
      return release;
    } catch (e) {
      debugPrint('checkForUpdates error: $e');
      return null;
    }
  }

  static bool hasUpdate(AppRelease release) {
    return _isNewer(release.tagName, currentVersion);
  }

  static String? getAssetForCurrentPlatform(AppRelease release) {
    if (Platform.isLinux) {
      for (final a in release.assets) {
        final name = a.name.toLowerCase();
        if (name.endsWith('.appimage')) return a.browserDownloadUrl;
      }
      for (final a in release.assets) {
        final name = a.name.toLowerCase();
        if (name.endsWith('.deb')) return a.browserDownloadUrl;
      }
      for (final a in release.assets) {
        final name = a.name.toLowerCase();
        if (name.endsWith('.rpm')) return a.browserDownloadUrl;
      }
    } else if (Platform.isWindows) {
      for (final a in release.assets) {
        final name = a.name.toLowerCase();
        if (name.endsWith('.zip') || name.endsWith('.msix')) {
          return a.browserDownloadUrl;
        }
      }
    } else if (Platform.isMacOS) {
      for (final a in release.assets) {
        final name = a.name.toLowerCase();
        if (name.endsWith('.dmg') || name.endsWith('.zip')) {
          return a.browserDownloadUrl;
        }
      }
    }
    return null;
  }
}
