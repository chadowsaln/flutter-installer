import 'package:flutter/material.dart';

import '../state/app_state.dart';
import '../state/app_scope.dart';
import 'dart_manager_screen.dart';
import 'flutter_manager_screen.dart';
import 'install_wizard_screen.dart';
import 'path_manager_screen.dart';
import 'process_screen.dart';
import 'sdk_manager_screen.dart';
import 'system_screen.dart';

/// Desktop shell: a navigation rail on the left, a page on the right, and a
/// collapsible diagnostics drawer showing the daemon log.
class Shell extends StatefulWidget {
  const Shell({super.key});

  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> {
  late final AppState _state = AppState();
  int _index = 0;

  static const _pages = [
    InstallWizardScreen(),
    SdkManagerScreen(),
    FlutterManagerScreen(),
    DartManagerScreen(),
    PathManagerScreen(),
    ProcessScreen(),
    SystemScreen(),
  ];

  @override
  void dispose() {
    _state.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_state.starting) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }
    return AppScope(
      state: _state,
      child: Builder(
        builder: (context) {
          return Scaffold(
            body: Row(
              children: [
                _Rail(
                  index: _index,
                  onSelect: (i) => setState(() => _index = i),
                ),
                Expanded(
                  child: Column(
                    children: [
                      _StatusBanner(onViewLog: _toggleLog),
                      Expanded(
                        child: IndexedStack(index: _index, children: _pages),
                      ),
                    ],
                  ),
                ),
                _LogDrawer(appState: _state),
              ],
            ),
          );
        },
      ),
    );
  }

  void _toggleLog() {
    Scaffold.of(context).openEndDrawer();
  }
}

class _Rail extends StatelessWidget {
  const _Rail({required this.index, required this.onSelect});

  final int index;
  final ValueChanged<int> onSelect;

  static const _icons = [
    Icons.rocket_launch,
    Icons.inventory_2,
    Icons.flutter_dash,
    Icons.code,
    Icons.route,
    Icons.memory,
    Icons.health_and_safety,
  ];

  static const _labels = [
    'Installer',
    'SDK Manager',
    'Flutter',
    'Dart',
    'PATH',
    'Processes',
    'System',
  ];

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 184,
      color: const Color(0xFF0B131F),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 20, 16, 16),
            child: Row(
              children: [
                Icon(Icons.flutter_dash, color: Color(0xFF45D1FD), size: 28),
                SizedBox(width: 8),
                Text('Flutter Installer',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
              ],
            ),
          ),
          const Divider(height: 1),
          for (var i = 0; i < _labels.length; i++)
            _NavItem(
              icon: _icons[i],
              label: _labels[i],
              selected: i == index,
              onTap: () => onSelect(i),
            ),
          const Spacer(),
          Padding(
            padding: const EdgeInsets.all(12),
            child: Text(
              'v0.1.0 · Rust core + Flutter UI',
              style: Theme.of(context).textTheme.bodySmall,
              textAlign: TextAlign.center,
            ),
          ),
        ],
      ),
    );
  }
}

class _NavItem extends StatelessWidget {
  const _NavItem({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: selected ? scheme.primary.withValues(alpha: 0.18) : null,
          borderRadius: BorderRadius.circular(8),
          border: selected ? Border.all(color: scheme.primary, width: 1) : null,
        ),
        child: Row(
          children: [
            Icon(icon, size: 20, color: selected ? scheme.primary : null),
            const SizedBox(width: 10),
            Text(label, style: const TextStyle(fontSize: 13.5)),
          ],
        ),
      ),
    );
  }
}

class _StatusBanner extends StatelessWidget {
  const _StatusBanner({required this.onViewLog});

  final VoidCallback onViewLog;

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final connected = state.hasConnection;
    final color = connected ? const Color(0xFF2BD576) : const Color(0xFFE5533D);
    return Container(
      color: const Color(0xFF0B131F),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          Icon(Icons.circle, size: 10, color: color),
          const SizedBox(width: 8),
Text(
              connected
                  ? 'Core connected: ${state.client?.daemonPath.split('/').last ?? 'core'}'
                  : state.starting
                      ? 'Starting core...'
                      : 'Core NOT connected — build the Rust core (see README)',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          const Spacer(),
          if (state.activeTask != null)
            Flexible(
              child: Text(state.activeTask!,
                  style: const TextStyle(color: Color(0xFF45D1FD), fontSize: 12)),
            ),
          IconButton(
            tooltip: 'Open daemon log',
            onPressed: onViewLog,
            icon: const Icon(Icons.terminal, size: 18),
          ),
        ],
      ),
    );
  }
}

/// A slim end drawer showing the last daemon/install log lines.
class _LogDrawer extends StatelessWidget {
  const _LogDrawer({required this.appState});

  final AppState appState;

  @override
  Widget build(BuildContext context) {
    return Drawer(
      width: 340,
      backgroundColor: const Color(0xFF0B131F),
      shape: const RoundedRectangleBorder(),
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.all(14),
              child: Row(
                children: [
                  const Text('Daemon log',
                      style: TextStyle(fontWeight: FontWeight.bold)),
                  const Spacer(),
                  IconButton(
                    tooltip: 'Close',
                    icon: const Icon(Icons.close, size: 18),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: ListView.builder(
                padding: const EdgeInsets.all(10),
                itemCount: appState.logBuffer.length,
                itemBuilder: (context, i) => Text(
                  appState.logBuffer[i],
                  style: const TextStyle(
                      fontSize: 11.5, fontFamily: 'monospace', height: 1.5),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}