import 'package:flutter/material.dart';

import '../state/app_state.dart';
import '../state/app_scope.dart';
import '../widgets/sections.dart';

/// PATH Manager: inspect the current PATH, the shell profiles the core knows
/// about, and add/remove entries.
class PathManagerScreen extends StatefulWidget {
  const PathManagerScreen({super.key});

  @override
  State<PathManagerScreen> createState() => _PathManagerScreenState();
}

class _PathManagerScreenState extends State<PathManagerScreen> {
  final _entryController = TextEditingController();
  String? _selectedProfile;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      AppScope.of(context).refreshPath();
    });
  }

  @override
  void dispose() {
    _entryController.dispose();
    super.dispose();
  }

  Future<void> _ensure(AppState app) async {
    final value = _entryController.text.trim();
    if (value.isEmpty) return;
    setState(() => _busy = true);
    try {
      final r = await app.rpc('path.ensure', {
        'binDir': value,
        if (_selectedProfile != null) 'profile': _selectedProfile,
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(r['added'] == true
              ? 'Added to ${r['profile']}'
              : 'Already present in ${r['profile']}'),
        ));
      }
      await app.refreshPath();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Failed: $e')));
      }
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _remove(AppState app, String entry) async {
    try {
      final r = await app.rpc('path.remove', {'binDir': entry});
      await app.refreshPath();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('Removed from ${(r['removed'] as List).length} '
                'profile(s)')));
      }
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
    final profiles = app.pathProfiles;
    return Padding(
      padding: const EdgeInsets.all(24),
      child: ListView(
        children: [
          Row(
            children: [
              const Text('PATH Manager',
                  style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
              const Spacer(),
              IconButton(
                tooltip: 'Refresh',
                icon: const Icon(Icons.refresh),
                onPressed: app.refreshPath,
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text('Entries listed here are a snapshot of this process\'s PATH.',
              style: Theme.of(context).textTheme.bodyMedium),
          const SizedBox(height: 16),

          SectionCard(
            title: 'Add a bin directory to PATH',
            child: Column(
              children: [
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _entryController,
                        decoration: const InputDecoration(
                          labelText: 'bin path',
                          hintText: '/home/you/development/flutter/bin',
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    DropdownButton<String>(
                      value: _selectedProfile,
                      hint: const Text('auto profile'),
                      items: [
                        const DropdownMenuItem(
                            value: null, child: Text('auto profile')),
                        for (final p in profiles)
                          DropdownMenuItem(
                            value: p['path'] as String?,
                            child: Text(
                              p['path']!.split('/').last,
                              style: const TextStyle(fontSize: 12),
                            ),
                          ),
                      ],
                      onChanged: (v) => setState(() => _selectedProfile = v),
                    ),
                    const SizedBox(width: 10),
                    FilledButton.icon(
                      onPressed: _busy ? null : () => _ensure(app),
                      icon: const Icon(Icons.add),
                      label: const Text('Add'),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  'Profiles detected:\n'
                  '${profiles.map((p) => '  ${p['path']}'
                          '${p['exists'] == true ? '' : ' (missing)'}').join('\n')}',
                  style: const TextStyle(
                      fontSize: 12, color: Colors.white54, height: 1.5),
                ),
              ],
            ),
          ),

          SectionCard(
            title: 'PATH entries (${app.pathEntries.length})',
            child: app.pathEntries.isEmpty
                ? const Text('PATH is empty — unusual!',
                    style: TextStyle(color: Colors.white54))
                : Column(
                    children: [
                      for (final e in app.pathEntries)
                        ListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          leading: const Icon(Icons.folder, size: 18),
                          title: Text(e['entry']?.toString() ?? e.toString(),
                              style: const TextStyle(fontSize: 12.5)),
                          trailing: IconButton(
                            tooltip: 'Remove from profiles',
                            icon: const Icon(Icons.remove_circle_outline,
                                size: 18),
                            onPressed: () =>
                                _remove(app, e['entry']?.toString() ?? ''),
                          ),
                        ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}