import 'package:flutter/material.dart';

import '../services/app_update_service.dart';

/// يعرض تحديثاً متوفراً: الإصدار الحالي والجديد + رابط التنزيل.
class UpdateDialog extends StatelessWidget {
  const UpdateDialog({super.key, required this.release});

  final AppRelease release;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final asset = AppUpdateService.assetForCurrentPlatform(release);
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
            'الإصدار الحالي: ${AppUpdateService.currentVersionLabel}',
            style: theme.textTheme.bodyMedium,
            textDirection: TextDirection.rtl,
          ),
          Text(
            'الإصدار الجديد: ${AppUpdateService.normalizeVersion(release.tagName)}',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: const Color(0xFF2BD576),
              fontWeight: FontWeight.bold,
            ),
            textDirection: TextDirection.rtl,
          ),
          if (asset != null) ...[
            const SizedBox(height: 8),
            Text(
              'الحزمة: ${asset.name}${asset.humanSize.isEmpty ? '' : ' (${asset.humanSize})'}',
              style: theme.textTheme.bodySmall,
              textDirection: TextDirection.rtl,
            ),
          ],
          if (release.name.isNotEmpty) ...[
            const SizedBox(height: 16),
            Text(release.name, style: theme.textTheme.titleMedium, textDirection: TextDirection.rtl),
          ],
          if (release.body.isNotEmpty && release.body.length < 500)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                release.body,
                style: theme.textTheme.bodySmall,
                textDirection: TextDirection.rtl,
                maxLines: 8,
                overflow: TextOverflow.ellipsis,
              ),
            ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('لاحقاً'),
        ),
        OutlinedButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('قسم التحديث'),
        ),
        FilledButton.icon(
          onPressed: () => Navigator.of(context).pop(true),
          icon: const Icon(Icons.download, size: 18),
          label: const Text('تحديث الآن'),
        ),
      ],
      actionsAlignment: MainAxisAlignment.end,
    );
  }
}