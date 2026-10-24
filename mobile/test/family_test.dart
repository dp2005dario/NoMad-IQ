// Perfiles de familia: lo que se guarda, los consejos que salen de cada
// persona y la pantalla entera (añadir, editar, borrar).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nomadiq/auth/session.dart';
import 'package:nomadiq/core/router.dart';
import 'package:nomadiq/features/family/family.dart';

import 'helpers.dart';

void main() {
  group('perfiles', () {
    test('ida y vuelta por JSON', () {
      const FamilyMember carmen = FamilyMember(
        name: 'Carmen',
        age: 72,
        allergies: <String>['gluten'],
        needs: <Need>{Need.walksLittle},
        likes: <Like>{Like.museums},
      );
      final FamilyMember? back = FamilyMember.parse(carmen.toJson());
      expect(back?.name, 'Carmen');
      expect(back?.age, 72);
      expect(back?.allergies, <String>['gluten']);
      expect(back?.needs, <Need>{Need.walksLittle});
      expect(back?.likes, <Like>{Like.museums});
      expect(back!.isSenior, isTrue);
      expect(back.isChild, isFalse);
    });

    test('lo raro se descarta', () {
      expect(FamilyMember.parse(<String, Object?>{'name': ''}), isNull);
      expect(FamilyMember.parse('Leo'), isNull);
      expect(FamilyMember.parse(<String, Object?>{'name': 'x' * 41}), isNull);
      // Una necesidad que no existe se ignora, la persona sigue.
      final FamilyMember? leo = FamilyMember.parse(<String, Object?>{
        'name': 'Leo',
        'needs': <Object?>['carSeat', 'jetpack'],
      });
      expect(leo?.needs, <Need>{Need.carSeat});
    });

    test('las alergias se separan por comas', () {
      expect(splitAllergies(' frutos secos, ,gluten '), <String>[
        'frutos secos',
        'gluten',
      ]);
    });
  });

  test('consejos: cada uno dice por quién es', () {
    final List<FamilyTip> tips = tipsFor(const <FamilyMember>[
      FamilyMember(name: 'Carmen', age: 72, needs: <Need>{Need.walksLittle}),
      FamilyMember(name: 'Leo', age: 5, allergies: <String>['frutos secos']),
      FamilyMember(name: 'Ana', age: 40),
    ]);
    final Map<TipKind, List<String>> byKind = <TipKind, List<String>>{
      for (final FamilyTip t in tips) t.kind: t.who,
    };
    expect(byKind[TipKind.allergy], <String>['Leo']);
    expect(byKind[TipKind.walk], <String>['Carmen']);
    expect(byKind[TipKind.kids], <String>['Leo']);
    expect(byKind[TipKind.seniors], <String>['Carmen']);
    expect(byKind.containsKey(TipKind.stroller), isFalse);
    expect(tipsFor(const <FamilyMember>[]), isEmpty);
  });

  test('el almacén guarda como mucho 12 y vacío borra', () async {
    final MemoryFamilyStore store = MemoryFamilyStore();
    await store.save(<FamilyMember>[
      for (int i = 0; i < 20; i++) FamilyMember(name: 'P$i'),
    ]);
    expect(await store.load(), hasLength(maxFamily));
    await store.save(<FamilyMember>[]);
    expect(store.raw, isNull);
    store.raw = 'basura';
    expect(await store.load(), isEmpty);
  });

  testWidgets('pantalla: añadir a la abuela y ver sus consejos', (
    WidgetTester tester,
  ) async {
    final FakeGateway g = FakeGateway();
    final SessionController session = await signedInSession(g);
    final MemoryFamilyStore store = MemoryFamilyStore();
    tester.view.physicalSize = const Size(1200, 3600);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await pumpApp(
      tester,
      locale: 'es',
      session: session,
      initialLocation: Routes.family,
      services: fakeServices(session, gateway: g, family: store),
    );
    await tester.pumpAndSettle();
    expect(find.text('Perfiles de familia'), findsOneWidget);

    await tester.tap(find.text('Añadir persona'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Nombre'), 'Carmen');
    await tester.enterText(find.widgetWithText(TextField, 'Edad'), '72');
    await tester.enterText(
      find.widgetWithText(TextField, 'Alergias o comida (separadas por comas)'),
      'gluten',
    );
    await tester.tap(find.widgetWithText(FilterChip, 'Camina poco'));
    await tester.pumpAndSettle();
    final Finder save = find.widgetWithText(FilledButton, 'Guardar');
    await tester.ensureVisible(save);
    await tester.tap(save);
    await tester.pumpAndSettle();

    expect(find.text('Carmen · 72 años'), findsOneWidget);
    expect(find.text('Alergia: gluten'), findsOneWidget);
    expect(
      find.text('Tranvía o taxi en las cuestas, y descansos a menudo.'),
      findsOneWidget,
    );
    expect(find.text('Por Carmen'), findsWidgets);
    final List<FamilyMember> saved = await store.load();
    expect(saved.single.needs, <Need>{Need.walksLittle});
    expect(saved.single.allergies, <String>['gluten']);
  });
}
