import 'package:flutter/material.dart';

/// Breakpoint below which the app switches to its small-screen layout.
/// Base all layout decisions strictly on available window space — never on
/// orientation or hardware type (phone vs. tablet).
const double largeScreenMinWidth = 600.0;

/// Maximum content width for readability on large displays.
const double contentMaxWidth = 800.0;

/// Switches between a large-screen and a small-screen widget tree based on
/// the parent's allocated space ([BoxConstraints.maxWidth]).
///
/// Example:
/// ```dart
/// AdaptiveLayout(
///   largeBuilder: (context) => Row(...),
///   smallBuilder: (context) => Column(...),
/// )
/// ```
class AdaptiveLayout extends StatelessWidget {
  const AdaptiveLayout({
    super.key,
    required this.largeBuilder,
    required this.smallBuilder,
    this.breakpoint = largeScreenMinWidth,
  });

  final WidgetBuilder largeBuilder;
  final WidgetBuilder smallBuilder;
  final double breakpoint;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth > breakpoint) {
          return largeBuilder(context);
        } else {
          return smallBuilder(context);
        }
      },
    );
  }
}

/// Prevents content from stretching unnaturally on large screens.
///
/// Wraps [child] in a [Center] + [ConstrainedBox] with
/// `BoxConstraints(maxWidth: [maxWidth])`, per the large-screen workflow.
class ConstrainedContent extends StatelessWidget {
  const ConstrainedContent({
    super.key,
    required this.child,
    this.maxWidth = contentMaxWidth,
  });

  final Widget child;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: child,
      ),
    );
  }
}

/// A scrollable screen body that stays centered and width-constrained on
/// large screens while filling small screens edge-to-edge.
///
/// Thin wrapper over `Center > ConstrainedBox > ListView` so every screen
/// follows the same adaptive pattern without duplicating it.
class AdaptiveScreenBody extends StatelessWidget {
  const AdaptiveScreenBody({
    super.key,
    required this.children,
    this.maxWidth = contentMaxWidth,
    this.padding = const EdgeInsets.all(24),
  });

  final List<Widget> children;
  final double maxWidth;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: ListView(
          padding: padding,
          children: children,
        ),
      ),
    );
  }
}

/// Distributes [children] horizontally on wide parents and stacks them
/// vertically on narrow ones. Used for stat rows / form rows that would
/// otherwise overflow on small windows.
class AdaptiveRowOrColumn extends StatelessWidget {
  const AdaptiveRowOrColumn({
    super.key,
    required this.children,
    this.breakpoint = 420.0,
    this.spacing = 12.0,
    this.rowCrossAxisAlignment = CrossAxisAlignment.start,
  });

  final List<Widget> children;
  final double breakpoint;
  final double spacing;
  final CrossAxisAlignment rowCrossAxisAlignment;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth > breakpoint) {
          return Row(
            crossAxisAlignment: rowCrossAxisAlignment,
            children: [
              for (var i = 0; i < children.length; i++) ...[
                if (i > 0) SizedBox(width: spacing),
                Expanded(child: children[i]),
              ],
            ],
          );
        } else {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var i = 0; i < children.length; i++) ...[
                if (i > 0) SizedBox(height: spacing),
                children[i],
              ],
            ],
          );
        }
      },
    );
  }
}
