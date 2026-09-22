import 'package:flutter/material.dart';

import '../state/app_state.dart';
import '../state/app_scope.dart';
import '../widgets/log_view.dart';
import '../widgets/sections.dart';

/// Dart Manager: standalone Dart SDK installs, plus fetching and installing
/// a specific (or latest) Dart SDK.
class DartManagerScreen extends StatefulWidget {
  const DartManagerScreen({super.key});

  @override
  State<DartManagerScreen> createState() => _DartManagerScreenState();
}

class _DartManagerScreenState extends State<DartManagerScreen> {
  final _versionController = TextEditingController();
  final _dirController = TextEditingController(text: '~/development');
  bool _addToPath = true;
  bool _installing = false;
  Map<String, dynamic>? _result;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      AppScope.of(context).refreshSdks();
      AppScope.of(context).refreshKnown();
    });
  }

  @override
  void dispose() {
    _versionController.dispose();
    _dirController.dispose();
    super.dispose();
  }

  Future<void> _install(AppState app) async {
    setState(() {
      _installing = true;
      _result = null;
      _error = null;
    });
    app.downloadProgress.value = 0;
    try {
      final v = _versionController.text.trim();
      final result = await app.rpc('dart.install', {
        if (v.isNotEmpty) 'version': v,
        'dir': _dirController.text,
        'addToPath': _addToPath,
        'replace': true,
      });
      if (mounted) setState(() => _result = result);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      app.downloadProgress.value = null;
      if (mounted) setState(() => _installing = false);
      await app.refreshSdks();
    }
  }

  Future<void> _uninstall(AppState app, Map<String, dynamic> sdk) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Remove Dart SDK?'),
        content: Text('Delete ${sdk['path']}?'),
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
      await app.rpc('dart.uninstall', {'dartRoot': sdk['path']});
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
    final sdks = app.dartSdks;
    return Padding(
      padding: const EdgeInsets.all(24),
      child: ListView(
        children: [
          const Text('Dart Manager',
              style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          Text(
            'Latest standalone Dart SDK: '
            '${app.dartLatestVersion == '—' ? 'unknown' : app.dartLatestVersion}',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          const SizedBox(height: 16),

          SectionCard(
            title: 'Install standalone Dart SDK',
            child: Column(
              children: [
                TextField(
                  controller: _versionController,
                  decoration: const InputDecoration(
                    labelText: 'Version (empty = latest)', 
                    hintText: 'e.g. 3.13.4',
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _dirController,
                  decoration: const InputDecoration(
                    labelText: 'Install to',
                    helperText: 'Placed in <dir>/dart-sdk',
                  ),
                ),
                const SizedBox(height: 12),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Add dart/bin to PATH'),
                  value: _addToPath,
                  onChanged: (v) => setState(() => _addToPath = v),
                ),
                Align(
                  alignment: Alignment.centerRight,
                  child: FilledButton.icon(
                    onPressed: _installing ? null : () => _install(app),
                    icon: const Icon(Icons.download),
                    label: Text(_installing ? 'Installing...' : 'Install Dart'),
                  ),
                ),
                ValueListenableBuilder<double?>(
                  valueListenable: app.downloadProgress,
                  builder: (context, pct, _) {
                    if (pct == null) return const SizedBox.shrink();
                    return Padding(
                      padding: const EdgeInsets.only(top: 10),
                      child: LinearProgressIndicator(value: pct / 100),
                    );
                  },
                ),
              ],
            ),
          ),

          if (_result != null)
            SectionCard(
              title: 'Result',
              child: Text(
                'Installed Dart ${_result!['version']} at ${_result!['path']}',
                style: const TextStyle(color: Color(0xFF2BD576)),
              ),
            ),
          if (_error != null)
            SectionCard(
              title: 'Error',
              child: Text(_error!,
                  style: const TextStyle(color: Color(0xFFE5533D))),
            ),

          if (sdks.isEmpty)
            const SectionCard(
              title: 'No standalone Dart SDKs found',
              child: Text(
                  'Note: your Flutter SDK already bundles Dart — this page '
                  'manages a separate dart command.',
                  style: TextStyle(color: Colors.white54)),
            )
          else
            for (final sdk in sdks)
              Card(
                child: ListTile(
                  leading: const Icon(Icons.code),
                  title: Text(
                    sdk['version']?.toString() ?? 'Dart SDK',
                    style: const TextStyle(fontSize: 14),
                  ),
                  subtitle: Text(sdk['path']?.toString() ?? '',
                      style: const TextStyle(fontSize: 12)),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (sdk['onPath'] == true)
                        const Chip(
                          label: Text('on PATH'),
                          visualDensity: VisualDensity.compact,
                          backgroundColor: Color(0xFF123A26),
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

          if (_installing)
            SectionCard(
              title: 'Log',
              child: SizedBox(
                height: 220,
                child: LogView(lines: app.logBuffer),
              ),
            ),
        ],
      ),
    );
  }
}