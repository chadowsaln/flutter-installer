import 'package:flutter/material.dart';

import '../state/app_state.dart';
import '../state/app_scope.dart';
import '../widgets/sections.dart';

/// System Checker: machine information and prerequisite checks for installing
/// the Flutter/Dart SDKs.
class SystemScreen extends StatefulWidget {
  const SystemScreen({super.key});

  @override
  State<SystemScreen> createState() => _SystemScreenState();
}

class _SystemScreenState extends State<SystemScreen> {
  bool _runningCheck = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      AppScope.of(context).runChecks();
      AppScope.of(context).refreshSystem();
    });
  }

  Future<void> _runCheck(AppState app) async {
    setState(() => _runningCheck = true);
    await app.runChecks();
    await app.refreshSystem();
    if (mounted) setState(() => _runningCheck = false);
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final info = app.systemInfo;
    final checks = app.systemChecks;
    final okCount = checks.where((c) => c['ok'] == true).length;

    return Padding(
      padding: const EdgeInsets.all(24),
      child: ListView(
        children: [
          Row(
            children: [
              const Text('System Checker',
                  style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
              const Spacer(),
              FilledButton.icon(
                onPressed: _runningCheck ? null : () => _runCheck(app),
                icon: const Icon(Icons.health_and_safety),
                label: Text(_runningCheck ? 'Running...' : 'Run checks'),
              ),
            ],
          ),
          const SizedBox(height: 16),

          SectionCard(
            title: 'Host',
            child: Wrap(
              spacing: 24,
              runSpacing: 10,
              children: [
                _InfoChip(label: 'OS', value: '${info['os'] ?? '?'}'),
                _InfoChip(label: 'Arch', value: '${info['arch'] ?? '?'}'),
                _InfoChip(label: 'Host', value: '${info['hostname'] ?? '?'}'),
                _InfoChip(label: 'User', value: '${info['user'] ?? '?'}'),
                _InfoChip(label: 'Shell', value: '${info['shell'] ?? '?'}'),
                _InfoChip(
                    label: 'Home', value: '${info['home'] ?? '?'}', wide: true),
                _InfoChip(
                    label: 'flutter',
                    value: '${info['flutterOnPath'] ?? 'not on PATH'}',
                    wide: true),
                _InfoChip(
                    label: 'dart',
                    value: '${info['dartOnPath'] ?? 'not on PATH'}',
                    wide: true),
              ],
            ),
          ),

          SectionCard(
            title: 'Prerequisites',
            trailing: checks.isEmpty
                ? null
                : Text('$okCount/${checks.length} ok',
                    style: const TextStyle(fontSize: 12, color: Colors.white54)),
            child: checks.isEmpty
                ? const Padding(
                    padding: EdgeInsets.all(24),
                    child: Center(child: CircularProgressIndicator()),
                  )
                : Column(
                    children: [
                      for (final check in checks) CheckTile(check: check),
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}

class _InfoChip extends StatelessWidget {
  const _InfoChip({required this.label, required this.value, this.wide = false});
  final String label;
  final String value;
  final bool wide;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: wide ? 280 : 200,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFF0B131F),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label.toUpperCase(),
              style: const TextStyle(fontSize: 10, color: Colors.white38)),
          const SizedBox(height: 2),
          Text(value,
              style: const TextStyle(fontSize: 13),
              maxLines: 1,
              overflow: TextOverflow.ellipsis),
        ],
      ),
    );
  }
}