import 'package:flutter/material.dart';

import '../state/app_scope.dart';
import '../widgets/sections.dart';

/// SDK Manager: overview of every Flutter and Dart SDK the core has found,
/// plus the newest known versions.
class SdkManagerScreen extends StatefulWidget {
  const SdkManagerScreen({super.key});

  @override
  State<SdkManagerScreen> createState() => _SdkManagerScreenState();
}

class _SdkManagerScreenState extends State<SdkManagerScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      AppScope.of(context).refreshAll();
    });
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    return Padding(
      padding: const EdgeInsets.all(24),
      child: ListView(
        children: [
          Row(
            children: [
              const Text('SDK Manager',
                  style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
              const Spacer(),
              IconButton(
                tooltip: 'Refresh',
                icon: const Icon(Icons.refresh),
                onPressed: app.refreshAll,
              ),
            ],
          ),
          const SizedBox(height: 8),

          SectionCard(
            title: 'Available now',
            child: Row(
              children: [
                Expanded(
                  child: _Stat(
                    label: 'Latest Flutter',
                    value: app.flutterLatestVersion,
                    icon: Icons.flutter_dash,
                  ),
                ),
                Expanded(
                  child: _Stat(
                    label: 'Latest Dart',
                    value: app.dartLatestVersion,
                    icon: Icons.code,
                  ),
                ),
              ],
            ),
          ),

          SectionCard(
            title: 'Installed SDKs',
            child: Column(
              children: [
                _SdkSummary(
                  kind: 'Flutter',
                  count: app.flutterSdks.length,
                  icon: Icons.flutter_dash,
                  detail: app.flutterSdks.isEmpty
                      ? 'No Flutter SDK detected'
                      : app.flutterSdks
                          .map((s) => s['version'])
                          .toSet()
                          .join(', '),
                ),
                const Divider(),
                _SdkSummary(
                  kind: 'Dart',
                  count: app.dartSdks.length,
                  icon: Icons.code,
                  detail: app.dartSdks.isEmpty
                      ? 'No standalone Dart SDK detected'
                      : app.dartSdks
                          .map((s) => s['version'])
                          .toSet()
                          .join(', '),
                ),
              ],
            ),
          ),

          SectionCard(
            title: 'Quick actions',
            child: Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                FilledButton.icon(
                  onPressed: () => _switchTo('flutter'),
                  icon: const Icon(Icons.flutter_dash),
                  label: const Text('Install / manage Flutter'),
                ),
                FilledButton.tonalIcon(
                  onPressed: () => _switchTo('dart'),
                  icon: const Icon(Icons.code),
                  label: const Text('Install / manage Dart'),
                ),
                OutlinedButton.icon(
                  onPressed: app.runChecks,
                  icon: const Icon(Icons.health_and_safety),
                  label: const Text('Run system checks'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  void _switchTo(String kind) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Open the "$kind" page from the sidebar.')),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.label, required this.value, required this.icon});
  final String label;
  final String value;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Icon(icon, color: const Color(0xFF45D1FD)),
        const SizedBox(height: 6),
        Text(value == 'null' || value == '—' ? 'unknown' : value,
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
        const SizedBox(height: 2),
        Text(label,
            style: const TextStyle(fontSize: 12, color: Colors.white54)),
      ],
    );
  }
}

class _SdkSummary extends StatelessWidget {
  const _SdkSummary({
    required this.kind,
    required this.count,
    required this.icon,
    required this.detail,
  });
  final String kind;
  final int count;
  final IconData icon;
  final String detail;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(icon),
      title: Text(kind, style: const TextStyle(fontSize: 14)),
      subtitle: Text(detail,
          style: const TextStyle(fontSize: 12, color: Colors.white54)),
      trailing: Chip(
        label: Text('$count'),
        visualDensity: VisualDensity.compact,
      ),
    );
  }
}