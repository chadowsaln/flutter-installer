import 'dart:io';

import 'package:flutter_installer_ui/services/app_update_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('version comparison', () {
    test('normalizes a leading v', () {
      expect(AppUpdateService.normalizeVersion('v1.2.3'), '1.2.3');
      expect(AppUpdateService.normalizeVersion('V2.0.0'), '2.0.0');
      expect(AppUpdateService.normalizeVersion('0.1.0'), '0.1.0');
    });

    test('detects newer candidates', () {
      expect(AppUpdateService.isNewer('v0.2.0', '0.1.0'), isTrue);
      expect(AppUpdateService.isNewer('v1.0.0', '0.9.9'), isTrue);
      expect(AppUpdateService.isNewer('v0.1.1', '0.1.0'), isTrue);
    });

    test('rejects older and identical candidates', () {
      expect(AppUpdateService.isNewer('v0.1.0', '0.1.0'), isFalse);
      expect(AppUpdateService.isNewer('v0.0.9', '0.1.0'), isFalse);
      expect(AppUpdateService.isNewer('v0.1.0+3', '0.1.0'), isFalse);
    });

    test('compares numerically, not lexicographically', () {
      expect(AppUpdateService.isNewer('v0.10.0', '0.9.0'), isTrue);
      expect(AppUpdateService.isNewer('v0.2.0', '0.10.0'), isFalse);
    });

    test('treats missing components as zero', () {
      expect(AppUpdateService.isNewer('v0.2', '0.1.0'), isTrue);
      expect(AppUpdateService.isNewer('v0.1', '0.1.0'), isFalse);
    });
  });

  group('hasUpdate', () {
    AppRelease release(String tag) => AppRelease.fromJson({
          'tag_name': tag,
          'name': 'Release $tag',
          'html_url': 'https://example.invalid/releases/$tag',
          'assets': <dynamic>[],
        });

    test('is true only for a newer tag than the shipped version', () {
      expect(
        AppUpdateService.hasUpdate(release('v99.0.0')),
        isTrue,
        reason: 'a far-future tag must be treated as an update',
      );
      expect(AppUpdateService.hasUpdate(release('v0.0.1')), isFalse);
    });
  });

  group('asset selection', () {
    AppRelease withAssets(List<String> names) => AppRelease.fromJson({
          'tag_name': 'v9.9.9',
          'name': 'Release',
          'html_url': 'https://example.invalid',
          'assets': [
            for (final n in names)
              {
                'name': n,
                'browser_download_url': 'https://example.invalid/$n',
                'size': 1024,
              },
          ],
        });

    test('picks the first suffix matching this platform', () {
      final names = Platform.isLinux
          ? <String>['flutter-installer-x86_64.AppImage']
          : Platform.isWindows
              ? <String>['flutter-installer-x86_64.zip']
              : <String>['flutter-installer.dmg'];
      final asset = AppUpdateService.assetForCurrentPlatform(withAssets(names));
      expect(asset?.name, names.first);
    });

    test('returns null when nothing matches', () {
      expect(
        AppUpdateService.assetForCurrentPlatform(withAssets(['checksums.txt'])),
        isNull,
      );
    });

    test('formats a human readable size', () {
      const asset = AppAsset(
        name: 'a',
        browserDownloadUrl: 'u',
        size: 5 * 1024 * 1024,
      );
      expect(asset.humanSize, '5.0 MB');
      expect(const AppAsset(name: 'a', browserDownloadUrl: 'u', size: 0).humanSize, '');
    });
  });

  group('install command', () {
    test('maps a package suffix to the matching package manager', () {
      final rpm = AppUpdateService.installCommand('/tmp/app-1.0.rpm');
      final deb = AppUpdateService.installCommand('/tmp/app_1.0_amd64.deb');
      final pkg = AppUpdateService.installCommand('/tmp/app-1.0.pkg.tar.zst');
      expect(rpm, contains('rpm -Uvh'));
      expect(deb, contains('apt install'));
      expect(pkg, contains('pacman -U'));
    });

    test('quotes paths containing spaces', () {
      final command = AppUpdateService.installCommand('/tmp/my apps/app.AppImage');
      expect(command, contains('"/tmp/my apps/app.AppImage"'));
    });
  });

  group('release parsing', () {
    test('tolerates a minimal payload', () {
      final release = AppRelease.fromJson({'tag_name': 'v1.0.0'});
      expect(release.tagName, 'v1.0.0');
      expect(release.assets, isEmpty);
      expect(release.draft, isFalse);
      expect(release.prerelease, isFalse);
    });

    test('parses nested assets', () {
      final release = AppRelease.fromJson({
        'tag_name': 'v1.2.0',
        'assets': [
          {
            'name': 'app.AppImage',
            'browser_download_url': 'https://example.invalid/a.AppImage',
            'size': 42,
          },
        ],
      });
      expect(release.assets, hasLength(1));
      expect(release.assets.single.size, 42);
    });
  });
}