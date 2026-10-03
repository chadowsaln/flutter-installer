import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/flutter_upgrader.dart';
import '../services/install_detector.dart';
import '../services/installer_service.dart';
import '../services/system_service.dart';
import '../state/app_scope.dart';
import '../widgets/adaptive_layout.dart';

/// شاشة "الإعداد الفوري": زر واحد يكتشف النظام، ينزّل، يفكّ، يضبط PATH،
/// يهيّئ الأدوات، ويتحقق فعلياً بتشغيل `flutter --version`.
///
/// One button, zero configuration. Every step is a visible stage with live
/// speed/ETA, a copy-paste fix command for anything missing, and a real
/// verification step — all through system commands, no backend.
class InstantSetupScreen extends StatefulWidget {
  const InstantSetupScreen({super.key});

  @override
  State<InstantSetupScreen> createState() => _InstantSetupScreenState();
}

class _InstantSetupScreenState extends State<InstantSetupScreen> {
  final _dirController = TextEditingController(text: '~/development');
  String _channel = 'stable';
  bool _addToPath = true;
  bool _precache = true;

  SetupProgress _progress = SetupProgress();
  Map<String, dynamic>? _target;
  bool _resolving = false;
  String? _resolveError;
  Timer? _logTimer;

  /// نتيجة كشف التثبيت الحالية على هذا الجهاز.
  InstallDetection _detection = const InstallDetection.absent();
  bool _detecting = false;

  /// هل الـ SDK مستودع git يسمح بالتحديث داخل المكان؟
  GitCheckoutInfo? _git;

  /// خطة التحديث المحسوبة (تقود فقط: fetch تحديث بيانات refs لا شجرة العمل).
  UpgradePlan? _plan;
  bool _planning = false;
  bool _updating = false;

  /// مسار المراحل المعروض — يتبدّل بين التثبيت والتحديث.
  List<SetupStage> get _activeSteps => _updating
      ? SetupStageLabel.updateSteps
      : SetupStageLabel.installSteps;

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
    _logTimer?.cancel();
    _dirController.dispose();
    super.dispose();
  }

  /// يفحص إن كان Flutter مثبتاً على هذا الجهاز — ويزامن النتيجة مع AppState
  /// حتى تعكس الشارة العلوية نفس الحقيقة. لا يشغّل `flutter`.
  void _detectAgainst({String? targetVersion}) {
    final version = targetVersion ?? _target?['version'] as String?;
    setState(() {
      _detecting = true;
      _detection = InstallationDetector.detect(targetVersion: version);
    });
    if (mounted) AppScope.of(context).refreshDetection(targetVersion: version);
    _probeGit(version);
  }

  /// يفحص ما إذا كان الـ SDK قابلاً للتحديث عبر git — قراءة فقط.
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
    // خطة مفيدة فقط عند وجود تحديث فعلاً落后的 عن الهدف.
    if (info.canUpgradeInPlace && _detection.state == InstallState.outdated) {
      _planUpdate();
    }
  }

  /// يجلب بيانات ref فقط ويحسب الخطة — لا يكتب في شجرة العمل.
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

  /// ينفّذ التحديث داخل المكان — لا تنزيل أرشيف ولا حذف للتثبيت الحالي.
  Future<void> _runUpdate({bool hardReset = false}) async {
    final plan = _plan;
    final info = _git;
    if (plan == null || info == null || !plan.feasible) return;
    FocusScope.of(context).unfocus();
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
    // أعد الكشف: الإصدار تغيّر على القرص فعلاً.
    _detectAgainst();
  }

  /// يطلب تأكيداً صريحاً قبل أي عملية تمسح عملاً محلياً.
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
          '${plan.dirtyFiles} modified file(s) detected. Reinstalling from '
          'the archive is the non-destructive alternative.',
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
        // الهدف تغيّر ⇒ أعد المقارنة مع المثبَّت فعلياً.
        _detection = InstallationDetector.detect(
          targetVersion: t['version'] as String?,
        );
        _detecting = false;
      });
    } catch (e) {
      if (mounted) setState(() => _resolveError = '$e');
    }
    // يُصفَّر في الحالتين — وإلا بقيت الشاشة محجوبة بعد فشل الشبكة.
    if (mounted) {
      setState(() {
        _resolving = false;
        _detecting = false;
      });
    }
  }

  Future<void> _install() async {
    FocusScope.of(context).unfocus();
    setState(() => _progress = SetupProgress());
    await InstallerService.install(
      channel: _channel,
      dir: _dirController.text,
      addToPath: _addToPath,
      precache: _precache,
      report: (p) {
        if (mounted) setState(() => _progress = p);
      },
    );
    if (mounted) _detectAgainst();
  }

  /// يفتح مجلد التثبيت في مدير الملفات عبر أمر النظام.
  void _reveal(String? path) {
    if (path == null || path.isEmpty) return;
    final cmd = Platform.isWindows
        ? ['explorer', path]
        : Platform.isMacOS
            ? ['open', path]
            : ['xdg-open', path];
    Process.run(cmd.first, cmd.sublist(1)).then((r) {
      if (r.exitCode != 0 && mounted) {
        _copy(path);
      }
    });
  }

  void _copy(String text) {
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Copied to clipboard')),
    );
  }

  bool get _running => _progress.stage.isActive;

  @override
  Widget build(BuildContext context) {
    final missing = SystemService.missingTools();
    final installAll = missing.isEmpty
        ? ''
        : SystemService.installCommand(
            missing.map(SystemService.packageName).toList());

    return AdaptiveScreenBody(
      maxWidth: 900,
      children: [
        _Header(
          target: _target,
          resolving: _resolving,
          resolveError: _resolveError,
          onRetryResolve: _resolve,
        ),
        const SizedBox(height: 16),

        _DetectionCard(
          detection: _detection,
          detecting: _detecting,
          onRedetect: _detectAgainst,
          onCopy: _copy,
          onReveal: _reveal,
        ),
        const SizedBox(height: 16),

        if (missing.isNotEmpty)
          _MissingToolsCard(missing: missing, installAll: installAll,
              onCopy: _copy),
        if (missing.isNotEmpty) const SizedBox(height: 16),

        if (_git != null && !_updating) ...[
          _UpdateInPlaceCard(
            info: _git!,
            plan: _plan,
            planning: _planning,
            root: _detection.flutterPath ?? '',
            onPlan: _planUpdate,
            onUpdate: _runUpdate,
            onDestructive: _confirmDestructive,
          ),
          const SizedBox(height: 16),
        ],

        _StageTrack(stage: _progress.stage, steps: _activeSteps),
        const SizedBox(height: 16),

        if (_running || _progress.stage == SetupStage.done ||
            _progress.stage == SetupStage.failed) ...[
          _LiveProgressCard(
            progress: _progress,
            onCopy: _copy,
          ),
          const SizedBox(height: 16),
        ],

        _OptionsCard(
          channel: _channel,
          dir: _dirController,
          addToPath: _addToPath,
          precache: _precache,
          enabled: !_running,
          onChannel: (v) {
            setState(() => _channel = v);
            _resolve();
          },
          onDir: (_) => setState(() {}),
          onAddToPath: (v) => setState(() => _addToPath = v),
          onPrecache: (v) => setState(() => _precache = v),
        ),
        const SizedBox(height: 16),

        _GoButton(
          running: _running,
          done: _progress.stage == SetupStage.done,
          blocked:
              missing.isNotEmpty || _resolving || _detecting || _updating,
          detection: _detection,
          gitAvailable: _git != null,
          onPress: _install,
        ),
      ],
    );
  }
}

// ----------------------------------------------------------------- header --

class _Header extends StatelessWidget {
  const _Header({
    required this.target,
    required this.resolving,
    required this.resolveError,
    required this.onRetryResolve,
  });

  final Map<String, dynamic>? target;
  final bool resolving;
  final String? resolveError;
  final VoidCallback onRetryResolve;

  @override
  Widget build(BuildContext context) {
    final info = SystemService.info();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Title row stacks on narrow windows so the spinner never overflows.
        LayoutBuilder(
          builder: (context, constraints) {
            final title = const Text(
              'Instant setup',
              style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
            );
            final spinner = SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            );
            if (resolving && constraints.maxWidth < 300) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  title,
                  const SizedBox(height: 8),
                  spinner,
                ],
              );
            }
            return Row(
              children: [
                Expanded(child: title),
                if (resolving) spinner,
              ],
            );
          },
        ),
        const SizedBox(height: 6),
        Text(
          'One button. Detects this machine, downloads, extracts, sets PATH, '
          'pre-caches and verifies — using system commands only.',
          style: Theme.of(context).textTheme.bodyMedium,
        ),
        const SizedBox(height: 14),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            _Chip(
              icon: Icons.memory,
              label: '${info['os']} · ${info['arch']}',
            ),
            _Chip(icon: Icons.laptop, label: '${info['distro']}'),
            _Chip(
              icon: Icons.inventory_2,
              label: '${info['packageManager'] ?? 'no pm'}',
            ),
            _Chip(
              icon: Icons.terminal,
              label: '${info['shell']}',
            ),
          ],
        ),
        const SizedBox(height: 12),
        if (resolveError != null)
          _Banner(
            color: const Color(0xFFE5533D),
            icon: Icons.cloud_off,
            text: 'Cannot reach the Flutter release feed: $resolveError',
            action: TextButton(
                onPressed: onRetryResolve, child: const Text('Retry')),
          )
        else if (target != null)
          _Banner(
            color: const Color(0xFF2BD576),
            icon: Icons.download,
            text: 'Target: Flutter ${target!['version']} '
                '(${target!['channel']}) · '
                '${_fmt(target!['size'])} · '
                '${(target!['archive'] as String).split('/').last}',
          )
        else if (!resolving)
          _Banner(
            color: Colors.white38,
            icon: Icons.help_outline,
            text: 'Could not resolve the latest Flutter release.',
          ),
      ],
    );
  }

  static String _fmt(dynamic bytes) =>
      bytes is int && bytes > 0
          ? '${(bytes / (1024 * 1024)).toStringAsFixed(0)} MB'
          : '? size';
}

class _Chip extends StatelessWidget {
  const _Chip({required this.icon, required this.label});
  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0xFF0B131F),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: const Color(0xFF23314D)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: const Color(0xFF45D1FD)),
          const SizedBox(width: 6),
          // A long shell path must not overflow the chip on narrow windows.
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12, color: Colors.white70),
            ),
          ),
        ],
      ),
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner({
    required this.color,
    required this.icon,
    required this.text,
    this.action,
  });

  final Color color;
  final IconData icon;
  final String text;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: Row(
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Text(text,
                style: const TextStyle(fontSize: 12.5, color: Colors.white70)),
          ),
          ?action,
        ],
      ),
    );
  }
}

// ----------------------------------------------------------- missing tools --

/// بطاقة «تحديث داخل المكان» — تستبدل تنزيل نسخة كاملة بـ git fast-forward.
///
/// يعرض ما سيفعله git بالضبط قبل التنفيذ، ويمنع أي عملية تمسح عملاً محلياً
/// بدون تأكيد صريح.
class _UpdateInPlaceCard extends StatelessWidget {
  const _UpdateInPlaceCard({
    required this.info,
    required this.plan,
    required this.planning,
    required this.root,
    required this.onPlan,
    required this.onUpdate,
    required this.onDestructive,
  });

  final GitCheckoutInfo info;
  final UpgradePlan? plan;
  final bool planning;
  final String root;
  final Future<void> Function() onPlan;
  final Future<void> Function({bool hardReset}) onUpdate;
  final Future<void> Function(UpgradePlan plan) onDestructive;

  @override
  Widget build(BuildContext context) {
    final p = plan;
    final notReady = planning || p == null || !p.feasible;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF16233A),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFF45D1FD).withValues(alpha: 0.4)),
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
              if (planning)
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              else
                IconButton(
                  tooltip: 'Re-check upstream',
                  onPressed: onPlan,
                  icon: const Icon(Icons.refresh, size: 18),
                ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            'git checkout on ${info.branch ?? '?'} '
            '(${info.shortSha}) — no archive is downloaded.',
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
                'A fast-forward keeps local modifications in place; '
                'it never overwrites files git tracks as modified.',
                style: TextStyle(fontSize: 11.5, color: Colors.white54),
              ),
            ],
            if (p.diverged) ...[
              const SizedBox(height: 6),
              const Text(
                'Local commits diverged from upstream — a fast-forward is '
                'impossible.',
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
                    avatar: Icon(Icons.check, size: 14, color: Color(0xFF2BD576)),
                    label: Text('Already current'),
                    backgroundColor: Color(0xFF123A26),
                    visualDensity: VisualDensity.compact,
                  )
                else if (p.diverged || p.hasLocalChanges)
                  OutlinedButton.icon(
                    onPressed: () => onDestructive(p),
                    icon: const Icon(Icons.warning_amber, size: 16),
                    label: const Text('Force reset…'),
                  )
                else
                  FilledButton.tonalIcon(
                    onPressed: () => onUpdate(),
                    icon: const Icon(Icons.sync, size: 16),
                    label: const Text('Update in place'),
                  ),
                if (!p.alreadyCurrent)
                  TextButton.icon(
                    onPressed: () => onPlan(),
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
}

/// بطاقة الكشف: هل Flutter مثبت فعلاً؟ وأين؟ وهل هو الأحدث؟
///
/// كل القيم من فحص حقيقي للقرص و`PATH` — لا تخمين.
class _DetectionCard extends StatelessWidget {
  const _DetectionCard({
    required this.detection,
    required this.detecting,
    required this.onRedetect,
    required this.onCopy,
    required this.onReveal,
  });

  final InstallDetection detection;
  final bool detecting;
  final VoidCallback onRedetect;
  final ValueChanged<String> onCopy;
  final ValueChanged<String?> onReveal;

  static const _style = {
    InstallState.notInstalled: (
      color: Color(0xFFFFB020),
      icon: Icons.error_outline,
      title: 'Flutter غير مثبّت',
    ),
    InstallState.outdated: (
      color: Color(0xFFFFB020),
      icon: Icons.update,
      title: 'تحديث متاح',
    ),
    InstallState.upToDate: (
      color: Color(0xFF2BD576),
      icon: Icons.check_circle,
      title: 'مثبّت وأحدث إصدار',
    ),
    InstallState.newer: (
      color: Color(0xFF45D1FD),
      icon: Icons.new_releases,
      title: 'أحدث من الهدف',
    ),
  };

  @override
  Widget build(BuildContext context) {
    final s = _style[detection.state]!;
    final d = detection;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF16233A),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: s.color.withValues(alpha: 0.45)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (detecting)
                const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              else
                Icon(s.icon, size: 18, color: s.color),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(s.title,
                        style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 14,
                            color: s.color)),
                    const SizedBox(height: 2),
                    Text(d.summary,
                        style: const TextStyle(
                            fontSize: 12.5, color: Colors.white70)),
                  ],
                ),
              ),
              IconButton(
                tooltip: 'Re-scan this machine',
                onPressed: detecting ? null : onRedetect,
                icon: const Icon(Icons.refresh, size: 18),
              ),
            ],
          ),

          // التفاصيل الفعلية: المسار، القناة، Dart، حالة PATH.
          if (d.isInstalled) ...[
            const SizedBox(height: 12),
            _Kv(label: 'Path', value: d.flutterPath ?? '—', onCopy: onCopy),
            if (d.channel != null)
              _Kv(label: 'Channel', value: d.channel!),
            if (d.dartVersion != null)
              _Kv(label: 'Dart', value: d.dartVersion!),
            _Kv(
              label: 'On PATH',
              value: d.onPath ? 'yes — ready in new terminals' : 'no',
              valueColor:
                  d.onPath ? const Color(0xFF2BD576) : const Color(0xFFFFB020),
            ),
            if (d.sdkCount > 1)
              _Kv(label: 'SDKs found', value: '${d.sdkCount}'),
            for (final note in d.notes) ...[
              const SizedBox(height: 6),
              Text('· $note',
                  style: const TextStyle(
                      fontSize: 11.5, color: Colors.white38)),
            ],
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: [
                TextButton.icon(
                  onPressed: () => onReveal(d.flutterPath),
                  icon: const Icon(Icons.folder_open, size: 15),
                  label: const Text('Open folder'),
                ),
                TextButton.icon(
                  onPressed: () => onCopy(d.flutterPath ?? ''),
                  icon: const Icon(Icons.copy, size: 15),
                  label: const Text('Copy path'),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

/// سطر مفتاح/قيمة مع زر نسخ — يضمن عدم فيض المسارات الطويلة.
class _Kv extends StatelessWidget {
  const _Kv({
    required this.label,
    required this.value,
    this.valueColor,
    this.onCopy,
  });

  final String label;
  final String value;
  final Color? valueColor;
  final ValueChanged<String>? onCopy;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 82,
            child: Text(label,
                style: const TextStyle(
                    fontSize: 12, color: Colors.white38)),
          ),
          Expanded(
            child: SelectableText(
              value,
              style: TextStyle(
                fontSize: 12.5,
                fontFamily: 'monospace',
                color: valueColor ?? Colors.white70,
              ),
            ),
          ),
          if (onCopy != null)
            InkWell(
              onTap: () => onCopy!(value),
              child: const Padding(
                padding: EdgeInsets.only(left: 6, top: 1),
                child: Icon(Icons.copy, size: 13, color: Colors.white38),
              ),
            ),
        ],
      ),
    );
  }
}

class _MissingToolsCard extends StatelessWidget {
  const _MissingToolsCard({
    required this.missing,
    required this.installAll,
    required this.onCopy,
  });

  final List<String> missing;
  final String installAll;
  final ValueChanged<String> onCopy;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF3A1F14),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFFE5533D)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Missing ${missing.length} tool(s): ${missing.join(', ')}',
              style: const TextStyle(
                  fontWeight: FontWeight.bold, color: Color(0xFFFF8A75))),
          const SizedBox(height: 10),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: const Color(0xFF05080F),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(installAll,
                style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 12,
                    color: Color(0xFF45D1FD))),
          ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed: () => onCopy(installAll),
              icon: const Icon(Icons.copy, size: 15),
              label: const Text('Copy command'),
            ),
          ),
        ],
      ),
    );
  }
}

// ------------------------------------------------------------ stage track --

class _StageTrack extends StatelessWidget {
  const _StageTrack({required this.stage, required this.steps});

  final SetupStage stage;

  /// مسار المراحل المعروض — تثبيت جديد أو تحديث داخلي.
  final List<SetupStage> steps;

  @override
  Widget build(BuildContext context) {
    final currentIndex = stage == SetupStage.failed ? 0 : steps.indexOf(stage);
    return LayoutBuilder(
      builder: (context, constraints) {
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
      },
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

// ----------------------------------------------------------- live progress --

class _LiveProgressCard extends StatelessWidget {
  const _LiveProgressCard({required this.progress, required this.onCopy});

  final SetupProgress progress;
  final ValueChanged<String> onCopy;

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
            Container(
              height: 190,
              decoration: BoxDecoration(
                color: const Color(0xFF05080F),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: const Color(0xFF23314D)),
              ),
              child: ListView.builder(
                padding: const EdgeInsets.all(10),
                itemCount: progress.log.length,
                itemBuilder: (context, i) {
                  final line = progress.log[i];
                  final isErr = line.startsWith('!');
                  return Text(
                    line,
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 11.5,
                      height: 1.45,
                      color: isErr
                          ? const Color(0xFFE5533D)
                          : line.startsWith(r'$')
                              ? const Color(0xFF45D1FD)
                              : Colors.white70,
                    ),
                  );
                },
              ),
            ),
            const SizedBox(height: 6),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: () => onCopy(progress.log.join('\n')),
                icon: const Icon(Icons.copy, size: 14),
                label: const Text('Copy log'),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

// --------------------------------------------------------------- options ---

class _OptionsCard extends StatelessWidget {
  const _OptionsCard({
    required this.channel,
    required this.dir,
    required this.addToPath,
    required this.precache,
    required this.enabled,
    required this.onChannel,
    required this.onDir,
    required this.onAddToPath,
    required this.onPrecache,
  });

  final String channel;
  final TextEditingController dir;
  final bool addToPath;
  final bool precache;
  final bool enabled;
  final ValueChanged<String> onChannel;
  final ValueChanged<String> onDir;
  final ValueChanged<bool> onAddToPath;
  final ValueChanged<bool> onPrecache;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF16233A),
        borderRadius: BorderRadius.circular(12),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final channelField = DropdownButtonFormField<String>(
            initialValue: channel,
            decoration: const InputDecoration(labelText: 'Release channel'),
            items: const [
              DropdownMenuItem(value: 'stable', child: Text('stable')),
              DropdownMenuItem(value: 'beta', child: Text('beta')),
              DropdownMenuItem(value: 'dev', child: Text('dev')),
            ],
            onChanged: enabled
                ? (v) {
                    if (v != null) onChannel(v);
                  }
                : null,
          );
          final dirField = TextField(
            controller: dir,
            enabled: enabled,
            decoration: const InputDecoration(
              labelText: 'Install to',
              helperText: 'The SDK will be placed in <dir>/flutter',
            ),
            onChanged: onDir,
          );
          if (constraints.maxWidth < 520) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                channelField,
                const SizedBox(height: 12),
                dirField,
              ],
            );
          }
          return Row(
            children: [
              Expanded(child: channelField),
              const SizedBox(width: 12),
              Expanded(flex: 2, child: dirField),
            ],
          );
        },
      ),
    );
  }
}

// ------------------------------------------------------------- go button ---

class _GoButton extends StatelessWidget {
  const _GoButton({
    required this.running,
    required this.done,
    required this.blocked,
    required this.detection,
    required this.gitAvailable,
    required this.onPress,
  });

  final bool running;
  final bool done;
  final bool blocked;
  final InstallDetection detection;
  final bool gitAvailable;
  final VoidCallback onPress;

  @override
  Widget build(BuildContext context) {
    final d = detection;
    // الزر يعكس الحالة الحقيقية: تثبيت / تثبيت كامل / لا إجراء.
    final (IconData icon, String label) = switch (d.state) {
      InstallState.notInstalled => (Icons.bolt, 'Install Flutter now'),
      InstallState.outdated => (Icons.download, 'Reinstall from archive'),
      InstallState.upToDate => (Icons.check_circle, 'Already installed'),
      InstallState.newer => (
          Icons.download,
          'Reinstall from archive'
        ),
    };
    final upToDate = d.state == InstallState.upToDate;
    final target = d.targetVersion;
    final subtitle = upToDate
        ? 'Flutter ${d.installedVersion} is already installed at '
            '${d.flutterPath}'
        : gitAvailable && d.state == InstallState.outdated
            // لا نريد أن يُقرأ الزر الرئيسي كخيار الرخيص.
            ? 'The full archive (${target ?? '?'}) is a reinstall: it deletes '
                'and re-extracts. Prefer "Update in place" above.'
            : 'Runs only system commands: tar / unzip / export / '
                'flutter precache.';

    return Column(
      children: [
        SizedBox(
          width: double.infinity,
          height: 52,
          child: FilledButton.icon(
            // "Up to date" لا ينفّذ تنزيلاً بلا داعٍ.
            onPressed: (running || blocked || upToDate) ? null : onPress,
            icon: running
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : Icon(done ? Icons.refresh : icon),
            label: Text(
              running
                  ? 'Installing — do not close'
                  : blocked
                      ? 'Install missing tools first'
                      : done
                          ? 'Run again'
                          : label,
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          subtitle,
          style: Theme.of(context).textTheme.bodySmall,
          textAlign: TextAlign.center,
        ),
      ],
    );
  }
}