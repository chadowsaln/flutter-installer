import 'package:flutter/material.dart';

import '../state/app_state.dart';
import '../state/app_scope.dart';
import '../widgets/log_view.dart';
import '../widgets/sections.dart';

/// Process Manager: spawn commands through the Rust core and stream their
/// output, view running processes, terminate them, or run one-shot `exec`s.
class ProcessScreen extends StatefulWidget {
  const ProcessScreen({super.key});

  @override
  State<ProcessScreen> createState() => _ProcessScreenState();
}

class _ProcessScreenState extends State<ProcessScreen> {
  final _cmdController = TextEditingController();
  final _argsController = TextEditingController();
  final _cwdController = TextEditingController();
  final _execController = TextEditingController();
  bool _showOutput = false;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      AppScope.of(context).refreshProcesses();
    });
  }

  @override
  void dispose() {
    _cmdController.dispose();
    _argsController.dispose();
    _cwdController.dispose();
    _execController.dispose();
    super.dispose();
  }

  List<String> _args() => _argsController.text
      .split(RegExp(r'\s+'))
      .where((a) => a.isNotEmpty)
      .toList();

  Future<void> _spawn(AppState app) async {
    final cmd = _cmdController.text.trim();
    if (cmd.isEmpty) return;
    setState(() => _busy = true);
    try {
      await app.rpc('process.spawn', {
        'cmd': cmd,
        'args': _args(),
        if (_cwdController.text.trim().isNotEmpty) 'cwd': _cwdController.text.trim(),
      });
      await app.refreshProcesses();
      setState(() => _showOutput = true);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Spawn failed: $e')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _exec(AppState app) async {
    final cmd = _execController.text.trim();
    if (cmd.isEmpty) return;
    setState(() => _busy = true);
    try {
      final r = await app.rpc('process.exec', {
        'cmd': cmd,
        'args': const [],
        'timeoutMs': 20000,
      });
      if (mounted) {
        showDialog<void>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('exec result'),
            content: SizedBox(
              width: 520,
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('$cmd\n→ exit code: ${r['code']}',
                        style: const TextStyle(
                            fontFamily: 'monospace', fontSize: 12)),
                    const SizedBox(height: 10),
                    if ((r['stdout'] ?? '').isNotEmpty)
                      Text('stdout:\n${r['stdout']}',
                          style: const TextStyle(
                              fontFamily: 'monospace', fontSize: 12)),
                    if ((r['stderr'] ?? '').isNotEmpty)
                      Text('stderr:\n${r['stderr']}',
                          style: const TextStyle(
                              fontFamily: 'monospace',
                              fontSize: 12,
                              color: Colors.orange)),
                  ],
                ),
              ),
            ),
            actions: [
              FilledButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Close')),
            ],
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('exec failed: $e')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _terminate(AppState app, int pid) async {
    try {
      await app.rpc('process.terminate', {'pid': pid});
      await app.refreshProcesses();
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
    return Padding(
      padding: const EdgeInsets.all(24),
      child: ListView(
        children: [
          const Text('Process Manager',
              style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          Text('Commands are spawned by the Rust core and their output '
              'streams into the log drawer.',
              style: Theme.of(context).textTheme.bodyMedium),
          const SizedBox(height: 16),

          SectionCard(
            title: 'Spawn',
            child: Column(
              children: [
                TextField(
                  controller: _cmdController,
                  decoration: const InputDecoration(
                    labelText: 'Command',
                    hintText: 'flutter',
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: _argsController,
                  decoration: const InputDecoration(
                    labelText: 'Arguments (space separated)',
                    hintText: 'create --platforms=linux demo',
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: _cwdController,
                  decoration: const InputDecoration(
                    labelText: 'Working directory (optional)',
                  ),
                ),
                const SizedBox(height: 12),
                Align(
                  alignment: Alignment.centerRight,
                  child: FilledButton.icon(
                    onPressed: _busy ? null : () => _spawn(app),
                    icon: const Icon(Icons.play_arrow),
                    label: const Text('Spawn'),
                  ),
                ),
              ],
            ),
          ),

          SectionCard(
            title: 'One-shot exec',
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _execController,
                    decoration: const InputDecoration(
                      labelText: 'Command',
                      hintText: 'echo hello world',
                    ),
                    onSubmitted: (_) => _exec(app),
                  ),
                ),
                const SizedBox(width: 10),
                OutlinedButton.icon(
                  onPressed: _busy ? null : () => _exec(app),
                  icon: const Icon(Icons.terminal),
                  label: const Text('Run & show output'),
                ),
              ],
            ),
          ),

          SectionCard(
            title: 'Running processes (${app.processes.length})',
            trailing: IconButton(
              tooltip: 'Refresh',
              icon: const Icon(Icons.refresh),
              onPressed: app.refreshProcesses,
            ),
            child: app.processes.isEmpty
                ? const Text('No managed processes running.',
                    style: TextStyle(color: Colors.white54))
                : Column(
                    children: [
                      for (final p in app.processes)
                        ListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          leading: const Icon(Icons.settings_input_component,
                              size: 18),
                          title: Text(
                            '${p['exe']}',
                            style: const TextStyle(fontSize: 13),
                          ),
                          subtitle: Text('pid ${p['pid']}',
                              style: const TextStyle(fontSize: 11)),
                          trailing: IconButton(
                            tooltip: 'Terminate',
                            icon: const Icon(Icons.stop_circle_outlined,
                                size: 20),
                            onPressed: () => _terminate(app, p['pid'] as int),
                          ),
                        ),
                    ],
                  ),
          ),

          if (_showOutput)
            SectionCard(
              title: 'Streamed output (shared log)',
              child: SizedBox(
                height: 260,
                child: LogView(lines: app.logBuffer),
              ),
            ),
        ],
      ),
    );
  }
}