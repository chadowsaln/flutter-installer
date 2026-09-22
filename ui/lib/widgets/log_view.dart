import 'package:flutter/material.dart';

/// A scrollable, auto-following terminal-style view for process/install output.
class LogView extends StatefulWidget {
  const LogView({super.key, required this.lines, this.height});
  final List<String> lines;
  final double? height;

  @override
  State<LogView> createState() => _LogViewState();
}

class _LogViewState extends State<LogView> {
  final _controller = ScrollController();
  bool _follow = true;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_follow && _controller.hasClients) {
        _controller.jumpTo(_controller.position.maxScrollExtent);
      }
    });
    return Container(
      height: widget.height,
      decoration: BoxDecoration(
        color: const Color(0xFF05080F),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFF23314D)),
      ),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            child: Row(
              children: [
                const Text('Output',
                    style: TextStyle(fontSize: 12, color: Colors.white54)),
                const Spacer(),
                InkWell(
                  onTap: () => setState(() => _follow = !_follow),
                  child: Text(
                    _follow ? 'auto-scroll on' : 'auto-scroll off',
                    style: const TextStyle(
                        fontSize: 11, color: Color(0xFF45D1FD)),
                  ),
                ),
                const SizedBox(width: 12),
                InkWell(
                  onTap: () => setState(() {}),
                  child: const Icon(Icons.refresh, size: 14,
                      color: Colors.white54),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: ListView.builder(
              controller: _controller,
              padding: const EdgeInsets.all(10),
              itemCount: widget.lines.length,
              itemBuilder: (context, i) => Text(
                widget.lines[i],
                style: const TextStyle(
                    fontFamily: 'monospace', fontSize: 11.5, height: 1.5),
              ),
            ),
          ),
        ],
      ),
    );
  }
}