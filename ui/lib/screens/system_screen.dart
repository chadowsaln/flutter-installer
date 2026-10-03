import 'package:flutter/material.dart';

import '../state/app_state.dart';
import '../state/app_scope.dart';
import '../widgets/adaptive_layout.dart';
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

    final hostFacts = [
      _InfoData('OS', '${info['os'] ?? '?'}'),
      _InfoData('Arch', '${info['arch'] ?? '?'}'),
      _InfoData('Host', '${info['hostname'] ?? '?'}'),
      _InfoData('User', '${info['user'] ?? '?'}'),
      _InfoData('Shell', '${info['shell'] ?? '?'}'),
      _InfoData('Home', '${info['home'] ?? '?'}', wide: true),
      _InfoData(
          'flutter', '${info['flutterOnPath'] ?? 'not on PATH'}', wide: true),
      _InfoData('dart', '${info['dartOnPath'] ?? 'not on PATH'}', wide: true),
    ];

    return AdaptiveScreenBody(
      children: [
          LayoutBuilder(
            builder: (context, constraints) {
              final narrow = constraints.maxWidth < 480;
              final title = const Text('System Checker',
                  style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold));
              final action = FilledButton.icon(
                onPressed: _runningCheck ? null : () => _runCheck(app),
                icon: const Icon(Icons.health_and_safety),
                label: Text(_runningCheck ? 'Running...' : 'Run checks'),
              );
              if (narrow) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    title,
                    const SizedBox(height: 12),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: action,
                    ),
                  ],
                );
              }
              return Row(
                children: [
                  title,
                  const Spacer(),
                  action,
                ],
              );
            },
          ),
          const SizedBox(height: 16),

          SectionCard(
            title: 'Host',
            child: GridView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              gridDelegate:
                  const SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 220,
                mainAxisSpacing: 10,
                crossAxisSpacing: 12,
                mainAxisExtent: 62,
              ),
              itemCount: hostFacts.length,
              itemBuilder: (context, index) {
                final fact = hostFacts[index];
                return _InfoChip(
                    label: fact.label, value: fact.value, wide: fact.wide);
              },
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
                : ListView.builder(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    itemCount: checks.length,
                    itemBuilder: (context, index) =>
                        CheckTile(check: checks[index]),
                  ),
          ),
      ],
    );
  }
}

class _InfoData {
  const _InfoData(this.label, this.value, {this.wide = false});
  final String label;
  final String value;
  final bool wide;
}

class _InfoChip extends StatelessWidget {
  const _InfoChip({required this.label, required this.value, this.wide = false});
  final String label;
  final String value;
  final bool wide;

  @override
  Widget build(BuildContext context) {
    return Container(
      // Width is driven by the surrounding GridView extent; keep the tile
      // flexible so it adapts instead of overflowing on narrow windows.
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