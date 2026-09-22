import 'package:flutter/material.dart';

import '../state/app_state.dart';
import '../state/app_scope.dart';
import '../widgets/log_view.dart';
import '../widgets/sections.dart';

/// The main installer wizard: pick a channel, confirm the destination, watch
/// the download/extraction progress, then review the result.
class InstallWizardScreen extends StatefulWidget {
  const InstallWizardScreen({super.key});

  @override
  State<InstallWizardScreen> createState() => _InstallWizardScreenState();
}

class _InstallWizardScreenState extends State<InstallWizardScreen> {
  final _dirController = TextEditingController(text: '~/development');
  String _channel = 'stable';
  bool _addToPath = true;
  bool _loadingLatest = false;
  Map<String, dynamic>? _latest;
  String? _latestError;
  bool _installing = false;
  Map<String, dynamic>? _result;
  String? _installError;

  @override
  void initState() {
    super.initState();
    _loadLatest();
  }

  @override
  void dispose() {
    _dirController.dispose();
    super.dispose();
  }

  Future<void> _loadLatest() async {
    setState(() {
      _loadingLatest = true;
      _latestError = null;
    });
    try {
      final app = AppScope.of(context);
      final latest = await app.rpc('flutter.latest', {'channel': _channel});
      if (mounted) setState(() => _latest = latest);
    } catch (e) {
      if (mounted) setState(() => _latestError = '$e');
    }
    if (mounted) setState(() => _loadingLatest = false);
  }

  Future<void> _install(AppState app) async {
    setState(() {
      _installing = true;
      _result = null;
      _installError = null;
    });
    app.downloadProgress.value = 0;
    try {
      final result = await app.rpc('flutter.install', {
        'version': _latest?['version'],
        'channel': _channel,
        'dir': _dirController.text,
        'addToPath': _addToPath,
        'replace': true,
      });
      if (mounted) setState(() => _result = result);
    } catch (e) {
      if (mounted) setState(() => _installError = '$e');
    } finally {
      app.downloadProgress.value = null;
      if (mounted) setState(() => _installing = false);
      await app.refreshSdks();
    }
  }

  String _fmtSize(num? bytes) {
    if (bytes == null) return '?';
    final mb = bytes / (1024 * 1024);
    return mb > 1024
        ? '${(mb / 1024).toStringAsFixed(1)} GB'
        : '${mb.toStringAsFixed(0)} MB';
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final progress = app.downloadProgress;
    return Padding(
      padding: const EdgeInsets.all(24),
      child: ListView(
        children: [
          const Text('Flutter SDK Installer',
              style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
          const SizedBox(height: 6),
          Text(
            'Download and install the official Flutter SDK, managed by the Rust core.',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          const SizedBox(height: 20),

          SectionCard(
            title: '1 · Configure',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                DropdownButtonFormField<String>(
                  initialValue: _channel,
                  decoration: const InputDecoration(labelText: 'Release channel'),
                  items: const [
                    DropdownMenuItem(value: 'stable', child: Text('stable')),
                    DropdownMenuItem(value: 'beta', child: Text('beta')),
                    DropdownMenuItem(value: 'dev', child: Text('dev')),
                    DropdownMenuItem(value: 'master', child: Text('master')),
                  ],
                  onChanged: (v) {
                    if (v == null) return;
                    setState(() => _channel = v);
                    _loadLatest();
                  },
                ),
                const SizedBox(height: 14),
                TextField(
                  controller: _dirController,
                  decoration: const InputDecoration(
                    labelText: 'Install to',
                    helperText: 'The SDK will be placed in <dir>/flutter',
                  ),
                ),
                const SizedBox(height: 14),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Add flutter/bin to PATH'),
                  value: _addToPath,
                  onChanged: (v) => setState(() => _addToPath = v),
                ),
              ],
            ),
          ),

          SectionCard(
            title: '2 · Resolve version',
            trailing: IconButton(
              tooltip: 'Re-check',
              icon: const Icon(Icons.refresh, size: 18),
              onPressed: _loadingLatest ? null : _loadLatest,
            ),
            child: _loadingLatest
                ? Column(
                    children: [
                      const Padding(
                        padding: EdgeInsets.all(12),
                        child: CircularProgressIndicator(),
                      ),
                      Text(
                        'Fetching Flutter release feed '
                        '(first check can take a few seconds)...',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  )
                : _latest == null
                    ? Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('Could not reach the release feed.',
                              style: TextStyle(color: Colors.white54)),
                          const SizedBox(height: 8),
                          OutlinedButton.icon(
                            onPressed: _loadLatest,
                            icon: const Icon(Icons.refresh, size: 16),
                            label: const Text('Retry'),
                          ),
                          if (_latestError != null)
                            Padding(
                              padding: const EdgeInsets.only(top: 8),
                              child: Text(
                                _latestError!,
                                style: const TextStyle(
                                    fontSize: 11, color: Colors.white38),
                              ),
                            ),
                        ],
                      )
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _FactRow('Flutter', _latest!['version']?.toString()),
                          _FactRow('Channel', _latest!['channel']?.toString()),
                          _FactRow(
                              'Dart SDK', _latest!['dartVersion']?.toString()),
                          _FactRow(
                              'Download size',
                              _fmtSize(_latest!['size'] as num?)),
                          const SizedBox(height: 8),
                          Text(
                            _latest!['url']?.toString() ?? '',
                            style: const TextStyle(
                                fontSize: 11, color: Colors.white38),
                          ),
                        ],
                      ),
          ),

          SectionCard(
            title: '3 · Install',
            trailing: FilledButton.icon(
              onPressed:
                  _installing || _loadingLatest || app.starting ? null : () => _install(app),
              icon: const Icon(Icons.download),
              label: Text(_installing ? 'Installing...' : 'Install Flutter'),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ValueListenableBuilder<double?>(
                  valueListenable: progress,
                  builder: (context, pct, _) {
                    if (pct == null) return const SizedBox.shrink();
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        ClipRRect(
                          borderRadius: BorderRadius.circular(4),
                          child: LinearProgressIndicator(
                            value: pct / 100,
                            minHeight: 8,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text('Download ${pct.toStringAsFixed(0)}%',
                            style: const TextStyle(
                                fontSize: 12, color: Colors.white54)),
                        const SizedBox(height: 12),
                      ],
                    );
                  },
                ),
                LogView(
                  lines: app.logBuffer,
                  height: _result != null || _installError != null ? 200 : null,
                ),
                if (_installError != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text('Install failed: $_installError',
                        style: const TextStyle(color: Color(0xFFE5533D))),
                  ),
                if (_result != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: const Color(0xFF123A26),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Row(children: [
                            Icon(Icons.check_circle,
                                color: Color(0xFF2BD576), size: 18),
                            SizedBox(width: 6),
                            Text('Installation complete',
                                style: TextStyle(fontWeight: FontWeight.bold)),
                          ]),
                          const SizedBox(height: 8),
                          Text('Path: ${_result!['path']}'),
                          Text('Version: ${_result!['version']}'),
                          if (_result!['pathResult'] != null)
                            Text(
                                'Added to PATH: ${(_result!['pathResult'] as Map)['profile']}'),
                          if (_result!['pathWarning'] != null)
                            Text('PATH warning: ${_result!['pathWarning']}',
                                style:
                                    const TextStyle(color: Color(0xFFE0B33D))),
                        ],
                      ),
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

class _FactRow extends StatelessWidget {
  const _FactRow(this.label, this.value);
  final String label;
  final String? value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Text('$label:  ',
              style: const TextStyle(color: Colors.white54, fontSize: 13)),
          Text(value ?? '—',
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500)),
        ],
      ),
    );
  }
}