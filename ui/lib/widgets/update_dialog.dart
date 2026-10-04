import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../services/app_update_service.dart';

class UpdateDialog extends StatelessWidget {
  const UpdateDialog({super.key, required this.release});

  final AppRelease release;

  Future<void> _openDownload() async {
    final assetUrl = AppUpdateService.getAssetForCurrentPlatform(release);
    final url = assetUrl ?? release.htmlUrl;
    final uri = Uri.parse(url);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  Future<void> _openReleases() async {
    final uri = Uri.parse(release.htmlUrl);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      backgroundColor: const Color(0xFF16233A),
      title: Row(
        children: [
          const Icon(Icons.system_update_alt, color: Color(0xFF45D1FD)),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'تحديث جديد متوفر',
              style: theme.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.bold,
              ),
              textDirection: TextDirection.rtl,
            ),
          ),
        ],
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'الإصدار الحالي: ${AppUpdateService.currentVersion}',
            style: theme.textTheme.bodyMedium,
            textDirection: TextDirection.rtl,
          ),
          Text(
            'الإصدار الجديد: ${release.tagName.replaceAll('v', '')}',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: const Color(0xFF2BD576),
              fontWeight: FontWeight.bold,
            ),
            textDirection: TextDirection.rtl,
          ),
          const SizedBox(height: 16),
          if (release.name.isNotEmpty)
            Text(
              release.name,
              style: theme.textTheme.titleMedium,
              textDirection: TextDirection.rtl,
            ),
          if (release.body.isNotEmpty && release.body.length < 500)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                release.body,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.textTheme.bodySmall?.color?.withValues(alpha: 0.9),
                ),
                textDirection: TextDirection.rtl,
                maxLines: 8,
                overflow: TextOverflow.ellipsis,
              ),
            ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('لاحقاً'),
        ),
        OutlinedButton(
          onPressed: _openReleases,
          child: const Text('كل الإصدارات'),
        ),
        FilledButton.icon(
          onPressed: _openDownload,
          icon: const Icon(Icons.download, size: 18),
          label: const Text('تحميل التحديث'),
        ),
      ],
      actionsAlignment: MainAxisAlignment.end,
    );
  }
}
