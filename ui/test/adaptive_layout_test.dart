import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_installer_ui/widgets/adaptive_layout.dart';

Widget _harness(double width, Widget child) {
  return MaterialApp(
    home: Scaffold(
      body: SizedBox(
        width: width,
        child: child,
      ),
    ),
  );
}

void main() {
  testWidgets('AdaptiveLayout switches on maxWidth breakpoint',
      (tester) async {
    const large = Key('large');
    const small = Key('small');

    await tester.pumpWidget(_harness(
      1000,
      AdaptiveLayout(
        largeBuilder: (_) => const SizedBox(key: large),
        smallBuilder: (_) => const SizedBox(key: small),
      ),
    ));
    expect(find.byKey(large), findsOneWidget);
    expect(find.byKey(small), findsNothing);

    await tester.pumpWidget(_harness(
      400,
      AdaptiveLayout(
        largeBuilder: (_) => const SizedBox(key: large),
        smallBuilder: (_) => const SizedBox(key: small),
      ),
    ));
    expect(find.byKey(small), findsOneWidget);
    expect(find.byKey(large), findsNothing);
  });

  testWidgets('AdaptiveScreenBody constrains width to maxWidth',
      (tester) async {
    await tester.pumpWidget(_harness(
      1400,
      const AdaptiveScreenBody(children: [Text('hello')]),
    ));
    final boxes = tester
        .widgetList<ConstrainedBox>(find.byType(ConstrainedBox))
        .toList();
    expect(boxes.any((b) => b.constraints.maxWidth == 800.0), isTrue);
    expect(find.byType(Center), findsWidgets);
  });

  testWidgets('AdaptiveRowOrColumn stacks on narrow widths', (tester) async {
    Widget build(double width) => _harness(
          width,
          const AdaptiveRowOrColumn(children: [
            Text('a'),
            Text('b'),
          ]),
        );

    await tester.pumpWidget(build(800));
    expect(find.byType(Row), findsOneWidget);

    await tester.pumpWidget(build(300));
    expect(find.byType(Column), findsWidgets);
  });
}
