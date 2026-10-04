import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/app_update_service.dart';

/// قسم تحديث التطبيق نفسه من GitHub Releases.
class AppUpdateScreen extends StatefulWidget {
  const AppUpdateScreen({super.key});

  @override
  State<AppUpdateScreen> createState() => _AppUpdateScreenState();
}

class _AppUpdateScreenState extends State<AppUpdateScreen> {
  AppRelease? _release;
  bool _checking = false;
  bool _downloading = false;
  int _received = 0;
  int _total = 0;
  DownloadedUpdate? _downloaded;
  String? _message;

  AppAsset? get _asset {
    final release = _release;
    if (release == null) return null;
    return AppUpdateService.assetForCurrentPlatform(release);
  }

  bool get _upToDate =>
      _release != null && !AppUpdateService.hasUpdate(_release!);

  double? get _progress =>
      _total > 0 ? (_received / _total).clamp(0.0, 1.0) : null;

  Future<void> _check() async {
    setState(() {
      _checking = true;

      _message = null;
    });
    final release = await AppUpdateService.checkForUpdates();
    if (!mounted) return;
    setState(() {
      _release = release;
      _checking = false;

      _message = release == null ? 'تعذّر الوصول إلى الإصدارات' : null;
      _received = 0;
      _total = 0;
      _downloaded = null;
    });
  }

  Future<void> _download() async {
    final asset = _asset;
    if (asset == null) return;
    setState(() {
      _downloading = true;

      _message = null;
      _received = 0;
      _total = asset.size;
    });
    try {
      final result = await AppUpdateService.downloadAsset(
        asset,
        onProgress: (received, total) {
          if (!mounted) return;
          setState(() {
            _received = received;
            _total = total;
          });
        },
      );
      if (!mounted) return;
      setState(() {
        _downloading = false;
        _downloaded = result;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _downloading = false;

        _message = 'فشل التنزيل: $e';
      });
    }
  }

  Future<void> _copy(String text, String label) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('$label: تم النسخ'), duration: const Duration(seconds: 2)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(
          'تحديث التطبيق',
          style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold),
          textDirection: TextDirection.rtl,
        ),
        const SizedBox(height: 4),
        Text(
          'يقرأ الإصدارات من GitHub Releases — ${AppUpdateService.repoOwner}/${AppUpdateService.repoName}',
          style: theme.textTheme.bodySmall,
          textDirection: TextDirection.rtl,
        ),
        const SizedBox(height: 16),
        _card(
          theme,
          'النسخة المثبّتة',
          Row(
            children: [
              Icon(Icons.desktop_windows_outlined, size: 18, color: const Color(0xFF45D1FD)),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  AppUpdateService.currentVersionLabel,
                  style: theme.textTheme.titleMedium,
                ),
              ),
              FilledButton.icon(
                onPressed: _checking ? null : _check,
                icon: _checking
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.refresh, size: 18),
                label: Text(_checking ? 'جارٍ الفحص…' : 'فحص عن تحديث'),
              ),
            ],
          ),
        ),
        if (_message != null) ...[
          const SizedBox(height: 12),
          _card(
            theme,
            'تعذّر الفحص',
            Row(
              children: [
                const Icon(Icons.error_outline, size: 18, color: Color(0xFFFFB020)),
                const SizedBox(width: 8),
                Expanded(child: Text(_message!, style: theme.textTheme.bodyMedium)),
              ],
            ),
          ),
        ],
        if (_release != null && _upToDate)
          _card(
            theme,
            'آخر إصدار',
            Row(
              children: [
                const Icon(Icons.check_circle, size: 18, color: Color(0xFF2BD576)),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '${AppUpdateService.currentVersionLabel} هي الأحدث',
                    style: theme.textTheme.bodyMedium,
                  ),
                ),
              ],
            ),
          ),
        if (_release != null && !_upToDate) ...[
          _card(
            theme,
            'إصدار متوفر',
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.new_releases, size: 18, color: Color(0xFF2BD576)),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '${AppUpdateService.normalizeVersion(_release!.tagName)}  →  ${AppUpdateService.currentVersionLabel}',
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ],
                ),
                if (_release!.name.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(_release!.name, style: theme.textTheme.bodyMedium),
                ],
                if (_release!.body.trim().isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(
                    _release!.body,
                    style: theme.textTheme.bodySmall,
                    maxLines: 10,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 12),
          if (_asset == null)
            _card(
              theme,
              'غير مدعوم',
              const Text('لا يوجد حزمة لهذا النظام في الإصدار الحالي.'),
            )
          else
            _card(
              theme,
              'الحزمة',
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(_asset!.name, style: theme.textTheme.bodyMedium),
                  if (_asset!.humanSize.isNotEmpty)
                    Text(
                      _asset!.humanSize,
                      style: theme.textTheme.bodySmall,
                    ),
                  const SizedBox(height: 12),
                  if (_downloading) ...[
                    LinearProgressIndicator(value: _progress),
                    const SizedBox(height: 6),
                    Text(
                      '${(_received / (1024 * 1024)).toStringAsFixed(1)} / ${(_total / (1024 * 1024)).toStringAsFixed(1)} MB',
                      style: theme.textTheme.bodySmall,
                    ),
                  ] else
                    FilledButton.icon(
                      onPressed: _download,
                      icon: const Icon(Icons.download, size: 18),
                      label: Text(_downloaded == null ? 'تنزيل التحديث' : 'إعادة التنزيل'),
                    ),
                ],
              ),
            ),
        ],
        if (_downloaded != null) ...[
          const SizedBox(height: 12),
          _card(
            theme,
            'الخطوة الأخيرة',
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  AppUpdateService.canSelfReplace
                      ? 'أغلق التطبيق ثم نفّذ الأمر لاستبدال النسخة الحالية:'
                      : 'يحتاج الاستبدال صلاحيات root. أغلق التطبيق ثم نفّذ:',
                  style: theme.textTheme.bodyMedium,
                ),
                const SizedBox(height: 8),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: const Color(0xFF0B131F),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: SelectableText(
                    AppUpdateService.installCommand(_downloaded!.path),
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 12,
                      color: Color(0xFF45D1FD),
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    OutlinedButton.icon(
                      onPressed: () => _copy(
                        AppUpdateService.installCommand(_downloaded!.path),
                        'الأمر',
                      ),
                      icon: const Icon(Icons.copy, size: 16),
                      label: const Text('نسخ الأمر'),
                    ),
                    const SizedBox(width: 8),
                    OutlinedButton.icon(
                      onPressed: () => _copy(_downloaded!.path, 'المسار'),
                      icon: const Icon(Icons.folder_open, size: 16),
                      label: const Text('نسخ المسار'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }

  Widget _card(ThemeData theme, String title, Widget child) => Container(
        margin: const EdgeInsets.only(bottom: 4),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: const Color(0xFF16233A),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: theme.textTheme.labelLarge?.copyWith(color: const Color(0xFF45D1FD)),
            ),
            const SizedBox(height: 10),
            child,
          ],
        ),
      );
}