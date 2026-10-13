import 'package:flutter/material.dart';

import '../services/flutter_upgrader.dart';
import '../services/install_detector.dart';
import '../services/installer_service.dart';
import '../state/app_scope.dart';
import '../widgets/adaptive_layout.dart';
import '../widgets/log_view.dart';
import '../widgets/sections.dart';

class UpdatesScreen extends StatefulWidget {
  const UpdatesScreen({super.key});

  @override
  State<UpdatesScreen> createState() => _UpdatesScreenState();
}

class _UpdatesScreenState extends State<UpdatesScreen> {
  final _dirController = TextEditingController(text: '~/development');
  String _channel = 'stable';
  bool _precache = true;

  Map<String, dynamic>? _target;
  bool _resolving = false;
  String? _resolveError;

  InstallDetection _detection = const InstallDetection.absent();
  bool _detecting = false;

  GitCheckoutInfo? _git;
  UpgradePlan? _plan;
  bool _planning = false;
  bool _updating = false;
  bool _reinstalling = false;

  SetupProgress _progress = SetupProgress();

  @override
  void initState() {
    super.initState();
    _progress = InstallerService.preflight();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _detectAgainst();
    });
    _resolve();
  }

  @override
  void dispose() {
    _dirController.dispose();
    super.dispose();
  }

  Future<void> _detectAgainst({String? targetVersion}) async {
    final version = targetVersion ?? _target?['version'] as String?;
    setState(() {
      _detecting = true;
      _detection = InstallationDetector.detect(targetVersion: version);
    });
    if (mounted) {
      AppScope.of(context).refreshDetection(targetVersion: version);
      _probeGit(version);
    }
    if (mounted) setState(() => _detecting = false);
  }

  void _probeGit(String? targetVersion) {
    final root = _detection.flutterPath;
    if (root == null) {
      if (mounted) setState(() => _git = null);
      return;
    }
    final info = FlutterUpgrader.probe(root);
    if (mounted) {
      setState(() {
        _git = info.canUpgradeInPlace ? info : null;
        _plan = null;
      });
    }
    if (info.canUpgradeInPlace && _detection.state == InstallState.outdated) {
      _planUpdate();
    }
  }

  Future<void> _planUpdate() async {
    final info = _git;
    if (info == null) return;
    setState(() => _planning = true);
    try {
      final plan = await FlutterUpgrader.plan(info);
      if (mounted) setState(() => _plan = plan);
    } catch (e) {
      if (mounted) setState(() => _plan = null);
    }
    if (mounted) setState(() => _planning = false);
  }

  Future<void> _runUpdate({bool hardReset = false}) async {
    final plan = _plan;
    final info = _git;
    if (plan == null || info == null || !plan.feasible) return;
    setState(() {
      _updating = true;
      _progress = SetupProgress();
    });
    await FlutterUpgrader.run(
      root: info.root,
      plan: plan,
      allowHardReset: hardReset,
      precache: _precache,
      report: (p) {
        if (mounted) setState(() => _progress = p);
      },
    );
    if (!mounted) return;
    setState(() => _updating = false);
    _detectAgainst();
  }

  Future<void> _confirmDestructive(UpgradePlan plan) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Discard local changes?'),
        content: Text(
          'The fast-forward was refused, so this SDK has local commits or '
          'edits that upstream does not have.\n\n'
          'A hard reset will permanently discard them and force the SDK to '
          '${plan.targetLabel}.\n\n'
          '${plan.dirtyFiles} modified file(s) detected.',
          style: const TextStyle(fontSize: 13),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Hard reset')),
        ],
      ),
    );
    if (ok == true) await _runUpdate(hardReset: true);
  }

  Future<void> _resolve() async {
    setState(() {
      _resolving = true;
      _resolveError = null;
    });
    try {
      final t = await InstallerService.resolveTarget(channel: _channel);
      if (!mounted) return;
      setState(() {
        _target = t;
        _detection = InstallationDetector.detect(
          targetVersion: t['version'] as String?,
        );
        _detecting = false;
      });
    } catch (e) {
      if (mounted) setState(() => _resolveError = '$e');
    }
    if (mounted) {
      setState(() {
        _resolving = false;
        _detecting = false;
      });
    }
  }

  Future<void> _reinstall() async {
    FocusScope.of(context).unfocus();
    setState(() {
      _reinstalling = true;
      _progress = SetupProgress();
    });
    await InstallerService.install(
      channel: _channel,
      dir: _dirController.text,
      addToPath: true,
      precache: _precache,
      report: (p) {
        if (mounted) setState(() => _progress = p);
      },
    );
    if (mounted) {
      setState(() => _reinstalling = false);
      _detectAgainst();
    }
  }

  bool get _running =>
      _updating || _reinstalling || _progress.stage.isActive;

  @override
  Widget build(BuildContext context) {
    return AdaptiveScreenBody(
      maxWidth: 900,
      children: [
        _buildHeader(),
        const SizedBox(height: 16),
        _buildStatusCard(),
        const SizedBox(height: 16),
        if (_git != null && !_updating && !_reinstalling) ...[
          _buildInPlaceCard(),
          const SizedBox(height: 16),
        ],
        _StageTrack(
          stage: _progress.stage,
          steps: _updating || _reinstalling
              ? (_reinstalling
                  ? SetupStageLabel.installSteps
                  : SetupStageLabel.updateSteps)
              : const [],
        ),
        const SizedBox(height: 16),
        if (_running ||
            _progress.stage == SetupStage.done ||
            _progress.stage == SetupStage.failed) ...[
          _LiveProgressCard(progress: _progress),
          const SizedBox(height: 16),
        ],
        _buildReinstallCard(),
      ],
    );
  }

  Widget _buildHeader() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Updates',
            style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
        const SizedBox(height: 6),
        Text(
          'Update Flutter SDKs in place via git, or reinstall from archive.',
          style: Theme.of(context).textTheme.bodyMedium,
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            DropdownButton<String>(
              value: _channel,
              items: const [
                DropdownMenuItem(value: 'stable', child: Text('stable')),
                DropdownMenuItem(value: 'beta', child: Text('beta')),
                DropdownMenuItem(value: 'dev', child: Text('dev')),
                DropdownMenuItem(value: 'master', child: Text('master')),
              ],
              onChanged: _running
                  ? null
                  : (v) {
                      if (v != null) {
                        setState(() => _channel = v);
                        _resolve();
                      }
                    },
            ),
            if (_resolving)
              const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
          ],
        ),
        if (_resolveError != null) ...[
          const SizedBox(height: 8),
          Text(_resolveError!,
              style: const TextStyle(color: Color(0xFFE5533D), fontSize: 12)),
        ],
      ],
    );
  }

  Widget _buildStatusCard() {
    final d = _detection;
    final (Color color, IconData icon, String title) = switch (d.state) {
      InstallState.notInstalled => (
          const Color(0xFFFFB020),
          Icons.error_outline,
          'Flutter غير مثبّت',
        ),
      InstallState.outdated => (
          const Color(0xFFFFB020),
          Icons.update,
          'تحديث متاح',
        ),
      InstallState.upToDate => (
          const Color(0xFF2BD576),
          Icons.check_circle,
          'مثبّت وأحدث إصدار',
        ),
      InstallState.newer => (
          const Color(0xFF45D1FD),
          Icons.new_releases,
          'أحدث من الهدف',
        ),
    };

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF16233A),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.45)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (_detecting)
                const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              else
                Icon(icon, size: 18, color: color),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title,
                        style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 14,
                            color: color)),
                    const SizedBox(height: 2),
                    Text(d.summary,
                        style: const TextStyle(
                            fontSize: 12.5, color: Colors.white70)),
                  ],
                ),
              ),
              IconButton(
                tooltip: 'Re-scan',
                onPressed: _detecting ? null : () => _detectAgainst(),
                icon: const Icon(Icons.refresh, size: 18),
              ),
            ],
          ),
          if (d.isInstalled) ...[
            const SizedBox(height: 12),
            _kv('Path', d.flutterPath ?? '—'),
            if (d.channel != null) _kv('Channel', d.channel!),
            if (d.dartVersion != null) _kv('Dart', d.dartVersion!),
            _kv('On PATH', d.onPath ? 'yes' : 'no'),
          ],
        ],
      ),
    );
  }

  Widget _buildInPlaceCard() {
    final info = _git!;
    final p = _plan;
    final notReady = _planning || p == null || !p.feasible;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF16233A),
        borderRadius: BorderRadius.circular(12),
        border:
            Border.all(color: const Color(0xFF45D1FD).withValues(alpha: 0.4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.sync_alt, size: 18, color: Color(0xFF45D1FD)),
              const SizedBox(width: 10),
              const Expanded(
                child: Text('Update in place',
                    style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 14,
                        color: Color(0xFF45D1FD))),
              ),
              if (_planning)
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              else
                IconButton(
                  tooltip: 'Re-check upstream',
                  onPressed: _planUpdate,
                  icon: const Icon(Icons.refresh, size: 18),
                ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            'git on ${info.branch ?? '?'} (${info.shortSha}) — no archive downloaded.',
            style: const TextStyle(fontSize: 12, color: Colors.white54),
          ),
          const SizedBox(height: 12),
          if (notReady)
            Text(
              p == null
                  ? 'Checking upstream for changes...'
                  : (p.problem ?? 'In-place update is not available here.'),
              style: const TextStyle(fontSize: 12.5, color: Colors.white70),
            )
          else ...[
            Text(p.summary,
                style: const TextStyle(fontSize: 13, color: Colors.white70)),
            if (p.hasLocalChanges) ...[
              const SizedBox(height: 6),
              const Text(
                'A fast-forward keeps local modifications in place.',
                style: TextStyle(fontSize: 11.5, color: Colors.white54),
              ),
            ],
            if (p.diverged) ...[
              const SizedBox(height: 6),
              const Text(
                'Local commits diverged from upstream.',
                style: TextStyle(fontSize: 11.5, color: Color(0xFFFFB020)),
              ),
            ],
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (p.alreadyCurrent)
                  const Chip(
                    avatar:
                        Icon(Icons.check, size: 14, color: Color(0xFF2BD576)),
                    label: Text('Already current'),
                    backgroundColor: Color(0xFF123A26),
                    visualDensity: VisualDensity.compact,
                  )
                else if (p.diverged || p.hasLocalChanges)
                  OutlinedButton.icon(
                    onPressed: () => _confirmDestructive(p),
                    icon: const Icon(Icons.warning_amber, size: 16),
                    label: const Text('Force reset…'),
                  )
                else
                  FilledButton.tonalIcon(
                    onPressed: _running ? null : () => _runUpdate(),
                    icon: const Icon(Icons.sync, size: 16),
                    label: const Text('Update in place'),
                  ),
                if (!p.alreadyCurrent)
                  TextButton.icon(
                    onPressed: _planning ? null : () => _planUpdate(),
                    icon: const Icon(Icons.refresh, size: 15),
                    label: const Text('Re-check'),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildReinstallCard() {
    return SectionCard(
      title: 'Reinstall from archive (full download)',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _dirController,
            enabled: !_running,
            decoration: const InputDecoration(
              labelText: 'Install to',
              helperText: 'The SDK will be placed in <dir>/flutter',
            ),
          ),
          const SizedBox(height: 12),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Pre-cache tools after install'),
            value: _precache,
            onChanged: _running ? null : (v) => setState(() => _precache = v),
          ),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton.icon(
              onPressed: _running ? null : _reinstall,
              icon: const Icon(Icons.download),
              label: Text(_reinstalling ? 'Reinstalling...' : 'Reinstall'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _kv(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 82,
            child: Text(label,
                style: const TextStyle(fontSize: 12, color: Colors.white38)),
          ),
          Expanded(
            child: SelectableText(
              value,
              style: const TextStyle(
                  fontSize: 12.5, fontFamily: 'monospace', color: Colors.white70),
            ),
          ),
        ],
      ),
    );
  }
}

class _StageTrack extends StatelessWidget {
  const _StageTrack({required this.stage, required this.steps});

  final SetupStage stage;
  final List<SetupStage> steps;

  @override
  Widget build(BuildContext context) {
    if (steps.isEmpty) return const SizedBox.shrink();
    final currentIndex = stage == SetupStage.failed ? 0 : steps.indexOf(stage);
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        for (var i = 0; i < steps.length; i++)
          _StepPill(
            index: i + 1,
            label: steps[i].label,
            state: currentIndex < 0
                ? _StepState.pending
                : i < currentIndex
                    ? _StepState.done
                    : i == currentIndex
                        ? (stage == SetupStage.done
                            ? _StepState.done
                            : _StepState.active)
                        : _StepState.pending,
          ),
      ],
    );
  }
}

enum _StepState { done, active, pending }

class _StepPill extends StatelessWidget {
  const _StepPill({
    required this.index,
    required this.label,
    required this.state,
  });

  final int index;
  final String label;
  final _StepState state;

  @override
  Widget build(BuildContext context) {
    final color = switch (state) {
      _StepState.done => const Color(0xFF2BD576),
      _StepState.active => const Color(0xFF45D1FD),
      _StepState.pending => const Color(0xFF3A4A66),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.6)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (state == _StepState.active)
            SizedBox(
              width: 11,
              height: 11,
              child: CircularProgressIndicator(strokeWidth: 2, color: color),
            )
          else
            Icon(
              state == _StepState.done ? Icons.check : Icons.circle,
              size: 11,
              color: color,
            ),
          const SizedBox(width: 7),
          Text('$index · $label',
              style: TextStyle(
                  fontSize: 11.5, color: color, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}

class _LiveProgressCard extends StatelessWidget {
  const _LiveProgressCard({required this.progress});

  final SetupProgress progress;

  @override
  Widget build(BuildContext context) {
    final failed = progress.stage == SetupStage.failed;
    final done = progress.stage == SetupStage.done;
    final color = failed
        ? const Color(0xFFE5533D)
        : done
            ? const Color(0xFF2BD576)
            : const Color(0xFF45D1FD);

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF16233A),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                failed
                    ? Icons.error_outline
                    : done
                        ? Icons.check_circle
                        : Icons.bolt,
                size: 18,
                color: color,
              ),
              const SizedBox(width: 8),
              Text(progress.stage.label,
                  style: TextStyle(
                      fontWeight: FontWeight.bold, color: color, fontSize: 14)),
              const Spacer(),
              if (progress.stage == SetupStage.download) ...[
                Text('${progress.speedLabel} · ETA ${progress.eta}',
                    style: const TextStyle(
                        fontSize: 12, color: Color(0xFF45D1FD))),
              ],
            ],
          ),
          if (progress.stage == SetupStage.download) ...[
            const SizedBox(height: 10),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: progress.percent / 100,
                minHeight: 8,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              '${progress.doneLabel} / ${progress.totalLabel} '
              '(${progress.percent.toStringAsFixed(1)}%)',
              style: const TextStyle(fontSize: 11.5, color: Colors.white54),
            ),
          ],
          if (progress.error != null) ...[
            const SizedBox(height: 10),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: const Color(0xFF05080F),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(progress.error!,
                  style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 12,
                      color: Color(0xFFFF8A75))),
            ),
          ],
          if (progress.log.isNotEmpty) ...[
            const SizedBox(height: 12),
            SizedBox(
              height: 190,
              child: LogView(lines: progress.log),
            ),
          ],
        ],
      ),
    );
  }
}
