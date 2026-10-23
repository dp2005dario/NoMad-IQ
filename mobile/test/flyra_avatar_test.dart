import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nomadiq/widgets/flyra_avatar.dart';

void main() {
  testWidgets('el avatar de Flyra se anuncia solo si tiene etiqueta', (
    WidgetTester tester,
  ) async {
    final SemanticsHandle semantics = tester.ensureSemantics();
    await tester.pumpWidget(
      const Directionality(
        textDirection: TextDirection.ltr,
        child: Row(
          children: <Widget>[
            FlyraAvatar(size: 64, semanticLabel: 'Flyra'),
            FlyraAvatar(size: 24),
          ],
        ),
      ),
    );
    expect(find.bySemanticsLabel('Flyra'), findsOneWidget);
    expect(tester.getSize(find.byType(FlyraAvatar).first), const Size(64, 64));
    semantics.dispose();
  });
}
