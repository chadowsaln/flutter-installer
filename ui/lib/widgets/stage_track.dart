import 'package:flutter/material.dart';

import '../services/installer_service.dart';

/// A horizontal track of stage pills showing install/update progress.
class StageTrack extends StatelessWidget {
  const StageTrack({super.key, required this.stage, required this.steps});

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

/// A card showing live progress with speed/ETA, progress bar, error, and log.
class LiveProgressCard extends StatelessWidget {
  const LiveProgressCard({super.key, required this.progress, this.onCopy});

  final SetupProgress progress;
  final ValueChanged<String>? onCopy;

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
            if (onCopy != null) ...[
              const SizedBox(height: 6),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  onPressed: () => onCopy!(progress.log.join('\n')),
                  icon: const Icon(Icons.copy, size: 14),
                  label: const Text('Copy log'),
                ),
              ),
            ],
          ],
        ],
      ),
    );
  }
}
