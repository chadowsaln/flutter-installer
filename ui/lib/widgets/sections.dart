import 'package:flutter/material.dart';

/// One row of a system prerequisite check result.
class CheckTile extends StatelessWidget {
  const CheckTile({super.key, required this.check});
  final Map<String, dynamic> check;

  @override
  Widget build(BuildContext context) {
    final ok = check['ok'] == true;
    final icon = ok ? Icons.check_circle : Icons.error;
    final color = ok ? const Color(0xFF2BD576) : const Color(0xFFE5533D);
    return ListTile(
      dense: true,
      leading: Icon(icon, color: color),
      title: Text(check['name']?.toString() ?? '?',
          style: const TextStyle(fontSize: 13.5)),
      subtitle: Text(
        check['detail']?.toString() ?? '',
        style: const TextStyle(fontSize: 12, color: Colors.white54),
      ),
      trailing: ok
          ? null
          : Tooltip(
              message: check['fix']?.toString() ?? '',
              child: const Icon(Icons.help_outline, size: 18, color: Colors.white38),
            ),
    );
  }
}

/// A titled card section used across all screens.
class SectionCard extends StatelessWidget {
  const SectionCard({super.key, required this.title, this.trailing, required this.child});
  final String title;
  final Widget? trailing;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(title,
                      style: const TextStyle(
                          fontWeight: FontWeight.bold, fontSize: 14)),
                ),
                if (trailing != null) ?trailing,
              ],
            ),
            const SizedBox(height: 12),
            child,
          ],
        ),
      ),
    );
  }
}