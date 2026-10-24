// "Viajo con…": mascota en cabina o bodega, lo que hace falta para la UE y
// las semanas de embarazo.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nomadiq/auth/session.dart';
import 'package:nomadiq/core/router.dart';
import 'package:nomadiq/core/settings.dart';
import 'package:nomadiq/features/travel_with/travel_with.dart';

import 'helpers.dart';

void main() {
  group('embarazo', () {
    test('28 y 36 semanas son las fronteras', () {
      expect(pregnancyVerdict(20), PregnancyVerdict.fly);
      expect(pregnancyVerdict(27), PregnancyVerdict.fly);
      expect(pregnancyVerdict(28), PregnancyVerdict.certificate);
      expect(pregnancyVerdict(35), PregnancyVerdict.certificate);
      expect(pregnancyVerdict(36), PregnancyVerdict.dontFly);
    });

    test('con gemelos se adelanta a la semana 32', () {
      expect(pregnancyVerdict(31, twins: true), PregnancyVerdict.certificate);
      expect(pregnancyVerdict(32, twins: true), PregnancyVerdict.dontFly);
      expect(noFlyFromWeek(twins: false), 36);
    });
  });

  group('mascota', () {
    test('8 kg contando el transportín', () {
      expect(petPlace(petKg: 6, carrierKg: 2), PetPlace.cabin);
      expect(petPlace(petKg: 6.5, carrierKg: 2), PetPlace.hold);
      expect(petPlace(petKg: 30, carrierKg: 0), PetPlace.hold);
    });

    test('la vacuna de la rabia necesita 21 días', () {
      final DateTime puesta = DateTime(2026, 11);
      expect(
        rabiesReady(vaccinated: puesta, flight: DateTime(2026, 11, 21)),
        isFalse,
      );
      expect(
        rabiesReady(vaccinated: puesta, flight: DateTime(2026, 11, 22)),
        isTrue,
      );
    });

    test('las casillas se guardan en el móvil', () async {
      final MemorySettingsStore store = MemorySettingsStore();
      final PetChecks checks = PetChecks(store);
      expect(checks.done(), isEmpty);
      await checks.set(PetCheck.microchip, ready: true);
      await checks.set(PetCheck.passport, ready: true);
      await checks.set(PetCheck.passport, ready: false);
      expect(PetChecks(store).done(), <PetCheck>{PetCheck.microchip});
      // Algo raro guardado no rompe nada.
      await store.writeData(LocalData.petChecks, 'basura');
      expect(PetChecks(store).done(), isEmpty);
    });
  });

  testWidgets('pantalla: peso del perro y semanas de embarazo', (
    WidgetTester tester,
  ) async {
    final FakeGateway g = FakeGateway();
    final SessionController session = await signedInSession(g);
    final MemorySettingsStore store = MemorySettingsStore();
    tester.view.physicalSize = const Size(1200, 3600);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await pumpApp(
      tester,
      locale: 'es',
      session: session,
      initialLocation: Routes.travelWith,
      services: fakeServices(session, gateway: g, prefs: store),
    );
    await tester.pumpAndSettle();
    expect(find.text('Viajo con…'), findsOneWidget);

    // Toby: 7 kg + 2 de transportín = 9 → bodega. Con 5 kg cabe.
    await tester.enterText(
      find.widgetWithText(TextField, 'Peso de tu mascota (kg)'),
      '7',
    );
    await tester.pumpAndSettle();
    expect(find.text('Tendrá que ir en bodega'), findsOneWidget);
    await tester.enterText(
      find.widgetWithText(TextField, 'Peso de tu mascota (kg)'),
      '5,5',
    );
    await tester.pumpAndSettle();
    expect(find.text('Puede ir contigo en cabina'), findsOneWidget);

    await tester.tap(find.text('Microchip'));
    await tester.pumpAndSettle();
    expect(store.readData(LocalData.petChecks), contains('microchip'));

    // Embarazo: de 20 semanas se puede volar; con gemelos a las 32, no.
    await tester.tap(find.text('Embarazada'));
    await tester.pumpAndSettle();
    expect(find.text('Puedes volar sin papeles'), findsOneWidget);
    final Slider slider = tester.widget(find.byType(Slider));
    slider.onChanged!(32);
    await tester.pumpAndSettle();
    expect(find.text('Necesitas un certificado médico'), findsOneWidget);
    await tester.tap(find.text('Embarazo de gemelos'));
    await tester.pumpAndSettle();
    expect(find.text('Mejor no volar'), findsOneWidget);
  });
}
