import 'package:flutter/material.dart';

import '../state/app_state.dart';
import '../state/app_scope.dart';
import '../widgets/sections.dart';

/// Flutter Manager: every installed Flutter SDK, its PATH status, and
/// uninstall / add-to-PATH actions.
class FlutterManagerScreen extends StatefulWidget {
  const FlutterManagerScreen({super.key});

  @override
  State<FlutterManagerScreen> createState() => _FlutterManagerScreenState();
}

class _FlutterManagerScreenState extends State<FlutterManagerScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      AppScope.of(context).refreshSdks();
    });
  }

  Future<void> _relink(AppState app, Map<String, dynamic> sdk) async {
    final bin = '${sdk['path']}/bin';
    try {
      final r = await app.rpc('path.ensure', {'binDir': bin});
      await app.refreshSdks();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('Added to PATH via '
                '${(r['profile'] as String? ?? 'profile')}')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Failed: $e')));
      }
    }
  }

  Future<void> _uninstall(AppState app, Map<String, dynamic> sdk) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Remove Flutter SDK?'),
        content: Text('Delete ${sdk['path']}?\n'
            'Version ${sdk['version']} will be permanently removed.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Delete')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await app.rpc('flutter.uninstall', {'flutterRoot': sdk['path']});
      await app.refreshSdks();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Failed: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final sdks = app.flutterSdks;
    return Padding(
      padding: const EdgeInsets.all(24),
      child: ListView(
        children: [
          Row(
            children: [
              const Text('Flutter Manager',
                  style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
              const Spacer(),
              IconButton(
                tooltip: 'Refresh',
                icon: const Icon(Icons.refresh),
                onPressed: app.refreshSdks,
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            'Install a new SDK from the Installer page.',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          const SizedBox(height: 16),

          if (sdks.isEmpty)
            const SectionCard(
              title: 'No Flutter SDKs found',
              child: Text('Install one using the Installer wizard.',
                  style: TextStyle(color: Colors.white54)),
            )
          else
            for (final sdk in sdks)
              Card(
                child: ListTile(
                  leading: const Icon(Icons.flutter_dash,
                      color: Color(0xFF45D1FD)),
                  title: Text(
                    'Flutter ${sdk['version']}',
                    style: const TextStyle(fontSize: 14),
                  ),
                  subtitle: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(sdk['path']?.toString() ?? '',
                          style: const TextStyle(fontSize: 12)),
                      Text(
                        [if (sdk['channel'] != null) 'channel ${sdk['channel']}',
                          if (sdk['dartVersion'] != null) 'dart ${sdk['dartVersion']}']
                            .join(' · '),
                        style: const TextStyle(
                            fontSize: 11, color: Colors.white54),
                      ),
                    ],
                  ),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (sdk['onPath'] == true)
                        const Chip(
                          label: Text('on PATH'),
                          visualDensity: VisualDensity.compact,
                          backgroundColor: Color(0xFF123A26),
                        )
                      else
                        IconButton(
                          tooltip: 'Add to PATH',
                          icon: const Icon(Icons.route, size: 20),
                          onPressed: () => _relink(app, sdk),
                        ),
                      IconButton(
                        tooltip: 'Uninstall',
                        icon: const Icon(Icons.delete_outline, size: 20),
                        onPressed: () => _uninstall(app, sdk),
                      ),
                    ],
                  ),
                ),
              ),
        ],
      ),
    );
  }
}

 