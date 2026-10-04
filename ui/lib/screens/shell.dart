import 'package:flutter/material.dart';

import '../services/install_detector.dart';
import '../state/app_state.dart';
import '../state/app_scope.dart';
import '../widgets/adaptive_layout.dart';
import 'dart_manager_screen.dart';
import 'flutter_manager_screen.dart';
import 'install_wizard_screen.dart';
import 'instant_setup_screen.dart';
import 'path_manager_screen.dart';
import 'process_screen.dart';
import 'sdk_manager_screen.dart';
import 'system_screen.dart';

/// Desktop shell: adapts to the available app window width.
///
/// - Wide windows (`maxWidth > [largeScreenMinWidth]`): a navigation rail on
///   the left, the page on the right, and the diagnostics log as an end
///   drawer.
/// - Narrow windows: a standard navigation drawer + app bar, with the same
///   pages in an [IndexedStack]. Base the decision strictly on window space
///   via [LayoutBuilder] — never on orientation or hardware type.
class Shell extends StatefulWidget {
  const Shell({super.key, this.state});

  final AppState? state;

  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> {
  late final AppState _state = widget.state ?? AppState();
  final _scaffoldKey = GlobalKey<ScaffoldState>();
  int _index = 0;

  static const _pages = [
    InstantSetupScreen(),
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

  void _select(int i) {
    setState(() => _index = i);
    // Close the navigation drawer on small screens after a selection.
    if ((_scaffoldKey.currentContext == null) ||
        MediaQuery.sizeOf(_scaffoldKey.currentContext!).width <=
            largeScreenMinWidth) {
      _scaffoldKey.currentState?.closeDrawer();
    }
  }

  void _toggleLog() {
    _scaffoldKey.currentState?.openEndDrawer();
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
      child: LayoutBuilder(
        builder: (context, constraints) {
          final isLarge = constraints.maxWidth > largeScreenMinWidth;
          if (isLarge) {
            return _buildLargeScreenLayout();
          } else {
            return _buildSmallScreenLayout();
          }
        },
      ),
    );
  }

  Widget _buildLargeScreenLayout() {
    return Scaffold(
      key: _scaffoldKey,
      endDrawer: _LogDrawer(appState: _state),
      body: Row(
        children: [
          _Rail(
            index: _index,
            onSelect: _select,
          ),
          const VerticalDivider(width: 1),
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
        ],
      ),
    );
  }

  Widget _buildSmallScreenLayout() {
    return Scaffold(
      key: _scaffoldKey,
      appBar: AppBar(
        title: Text(_labels[_index]),
      ),
      drawer: Drawer(
        child: SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 20, 16, 16),
                child: Row(
                  children: [
                    Icon(Icons.flutter_dash,
                        color: Color(0xFF45D1FD), size: 28),
                    SizedBox(width: 8),
                    Text('Flutter Installer',
                        style: TextStyle(
                            fontWeight: FontWeight.bold, fontSize: 15)),
                  ],
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: ListView.builder(
                  itemCount: _labels.length,
                  itemBuilder: (context, i) => _NavItem(
                    icon: _icons[i],
                    label: _labels[i],
                    selected: i == _index,
                    onTap: () => _select(i),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
      endDrawer: _LogDrawer(appState: _state),
      body: Column(
        children: [
          _StatusBanner(onViewLog: _toggleLog),
          Expanded(
            child: IndexedStack(index: _index, children: _pages),
          ),
        ],
      ),
    );
  }
}

const _icons = [
  Icons.bolt,
  Icons.rocket_launch,
  Icons.inventory_2,
  Icons.flutter_dash,
  Icons.code,
  Icons.route,
  Icons.memory,
  Icons.health_and_safety,
];

const _labels = [
  'Instant Setup',
  'Installer',
  'SDK Manager',
  'Flutter',
  'Dart',
  'PATH',
  'Processes',
  'System',
];

class _Rail extends StatelessWidget {
  const _Rail({required this.index, required this.onSelect});

  final int index;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 200,
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
                Flexible(
                  child: Text('Flutter Installer',
                      style:
                          TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: ListView.builder(
              itemCount: _labels.length,
              itemBuilder: (context, i) => _NavItem(
                icon: _icons[i],
                label: _labels[i],
                selected: i == index,
                onTap: () => onSelect(i),
              ),
            ),
          ),
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
            Expanded(child: Text(label, style: const TextStyle(fontSize: 13.5))),
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
    const color = Color(0xFF2BD576);
    return Container(
      color: const Color(0xFF0B131F),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          const Icon(Icons.circle, size: 10, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'وضع محلي: ${state.backendLabel} — كشف النظام وتنزيل عبر الأوامر',
              style: Theme.of(context).textTheme.bodySmall,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          // شارة التثبيت: هل Flutter موجود على هذا الجهاز وأي إصدار؟
          _InstallBadge(state: state),
          if (state.activeTask != null)
            Flexible(
              child: Text(state.activeTask!,
                  style: const TextStyle(color: Color(0xFF45D1FD), fontSize: 12),
                  overflow: TextOverflow.ellipsis),
            ),
          IconButton(
            tooltip: 'Open log',
            onPressed: onViewLog,
            icon: const Icon(Icons.terminal, size: 18),
          ),
        ],
      ),
    );
  }
}

/// شارة صغيرة تعرض حالة تثبيت Flutter الفعلية على هذا الجهاز.
class _InstallBadge extends StatelessWidget {
  const _InstallBadge({required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    final d = state.detection;
    final (Color color, IconData icon) = switch (d.state) {
      InstallState.notInstalled => (const Color(0xFFFFB020), Icons.error_outline),
      InstallState.outdated => (const Color(0xFFFFB020), Icons.update),
      InstallState.upToDate => (const Color(0xFF2BD576), Icons.check_circle),
      InstallState.newer => (const Color(0xFF45D1FD), Icons.new_releases),
    };
    return Container(
      margin: const EdgeInsets.only(left: 10, right: 4),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.6)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: color),
          const SizedBox(width: 5),
          Text(
            state.installedBadge,
            style: TextStyle(fontSize: 11, color: color),
          ),
        ],
      ),
    );
  }
}

/// A slim end drawer showing the last command/install log lines.
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
                  const Text('سجل الأوامر',
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
