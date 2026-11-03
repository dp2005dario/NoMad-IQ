// Modo fácil: Inicio con letras grandes, el vuelo, a qué hora salir de casa
// y los botones grandes (hotel, familia, papeles, Flyra y emergencia).
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:eclipta/auth/session.dart';
import 'package:eclipta/core/router.dart';
import 'package:eclipta/core/settings.dart';
import 'package:eclipta/features/easy/easy_mode.dart';

import 'helpers.dart';

void main() {
  group('cuentas', () {
    test('se sale de casa 3 horas antes del vuelo', () {
      expect(
        leaveHomeAt(DateTime(2026, 10, 24, 10, 30)),
        DateTime(2026, 10, 24, 7, 30),
      );
    });

    test('el viaje se guarda y lo raro se descarta', () async {
      final MemorySettingsStore store = MemorySettingsStore();
      expect(loadEasyTrip(store).isEmpty, isTrue);
      final EasyTrip trip = EasyTrip.parse(<String, Object?>{
        'departure': '2026-10-24T10:30:00.000',
        'from': 'mad',
        'to': 'LIS',
        'gate': 'B12',
        'hotel_address': '  Rua Augusta 1, Lisboa  ',
      });
      expect(trip.from, 'MAD');
      expect(trip.hotelAddress, 'Rua Augusta 1, Lisboa');
      expect(trip.hasFlight, isTrue);
      await saveEasyTrip(store, trip);
      expect(loadEasyTrip(store).gate, 'B12');
      // Un código que no es de aeropuerto, fuera.
      expect(EasyTrip.parse(<String, Object?>{'from': 'MADRID'}).from, isNull);
      await store.writeData(LocalData.easyTrip, 'roto');
      expect(loadEasyTrip(store).isEmpty, isTrue);
    });

    test('el enlace al hotel va con la dirección', () {
      final Uri u = directionsTo('Rua Augusta 1, Lisboa');
      expect(u.scheme, 'https');
      expect(u.queryParameters['destination'], 'Rua Augusta 1, Lisboa');
    });

    test('el modo se recuerda en el móvil', () async {
      final MemorySettingsStore store = MemorySettingsStore();
      final EasyMode mode = EasyMode(store);
      expect(mode.value, isFalse);
      await mode.set(true);
      expect(EasyMode(store).value, isTrue);
    });
  });

  testWidgets('Inicio en Modo fácil: vuelo, hotel, familia y volver', (
    WidgetTester tester,
  ) async {
    final FakeGateway g = FakeGateway();
    final SessionController session = await signedInSession(g);
    final MemorySettingsStore store = MemorySettingsStore();
    await store.writeData(LocalData.easyMode, '1');
    await saveEasyTrip(
      store,
      EasyTrip(
        departure: DateTime(2030, 3, 9, 10, 30),
        from: 'MAD',
        to: 'LIS',
        gate: 'B12',
        hotelAddress: 'Rua Augusta 1, Lisboa',
      ),
    );
    await store.writeData(
      LocalData.sosContacts,
      jsonEncode(<Object?>[
        <String, Object?>{'name': 'Noelia', 'phone': '+34 600 11 22 33'},
      ]),
    );
    final List<Uri> opened = <Uri>[];
    tester.view.physicalSize = const Size(1200, 4000);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await pumpApp(
      tester,
      locale: 'es',
      session: session,
      initialLocation: Routes.home,
      services: fakeServices(
        session,
        gateway: g,
        prefs: store,
        openLink: (Uri u) async {
          opened.add(u);
          return true;
        },
      ),
    );
    // Los aeropuertos de verdad (assets/geo) tardan un poco en cargarse.
    // (Son tres archivos seguidos: se deja avanzar varias veces.)
    for (int i = 0; i < 4; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 600)),
      );
      await tester.pumpAndSettle();
    }
    expect(find.text('Madrid → Lisbon'), findsOneWidget);
    expect(find.textContaining('B12'), findsOneWidget);
    expect(find.textContaining('sal de casa a las 7:30'), findsOneWidget);

    // El hotel: ir andando abre la ruta a pie con la dirección.
    await tester.tap(find.text('Llévame al hotel'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('🚶 Ir andando · te guío'));
    await tester.pumpAndSettle();
    expect(opened.last.queryParameters['destination'], contains('Augusta'));
    expect(opened.last.queryParameters['travelmode'], 'walking');
    // Para el taxista: la frase en portugués (el idioma de Lisboa).
    await tester.tap(find.text('🚕 Enseñar al taxista'));
    await tester.pumpAndSettle();
    expect(find.text('POR FAVOR, LLÉVEME A:'), findsOneWidget);
    expect(
      find.text('Por favor, leve-me a este hotel. Obrigado.'),
      findsOneWidget,
    );
    await tester.tap(find.text('Volver'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Cerrar'));
    await tester.pumpAndSettle();

    // La familia: tocar la persona llama; el botón verde abre WhatsApp.
    await tester.tap(find.text('Ver a la familia'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Noelia'));
    await tester.pumpAndSettle();
    expect(opened.last.scheme, 'tel');
    await tester.tap(find.text('Ver a la familia'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('WhatsApp'));
    await tester.pumpAndSettle();
    expect(opened.last.toString(), 'https://wa.me/34600112233');

    // La ayuda del aeropuerto: se pide, se guarda y cambia el cuadrado.
    await tester.tap(find.text('Ayuda en el aeropuerto'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Que me acompañen andando'));
    await tester.tap(find.text('Pedirla ahora'));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('Hecho: que me acompañen andando'),
      findsOneWidget,
    );
    expect(loadEasyTrip(store).help, 1);
    await tester.tap(find.byTooltip('Cerrar'));
    await tester.pumpAndSettle();
    expect(find.text('✓ Ayuda pedida'), findsOneWidget);

    // "Modo normal" vuelve a la Inicio de siempre y se recuerda.
    await tester.tap(find.text('Modo normal'));
    await tester.pumpAndSettle();
    expect(find.text('Llévame al hotel'), findsNothing);
    expect(store.readData(LocalData.easyMode), isNull);
  });

  testWidgets('sin viaje invita a ponerlo y lo guarda', (
    WidgetTester tester,
  ) async {
    final FakeGateway g = FakeGateway();
    final SessionController session = await signedInSession(g);
    final MemorySettingsStore store = MemorySettingsStore();
    await store.writeData(LocalData.easyMode, '1');
    tester.view.physicalSize = const Size(1200, 4000);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await pumpApp(
      tester,
      locale: 'es',
      session: session,
      initialLocation: Routes.home,
      services: fakeServices(session, gateway: g, prefs: store),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Llévame al hotel'));
    await tester.pumpAndSettle();
    expect(find.textContaining('dirección del hotel'), findsOneWidget);

    await tester.tap(find.text('Poner mi viaje'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, 'Dirección del hotel'),
      'Rua Augusta 1',
    );
    await tester.ensureVisible(find.text('Guardar'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Guardar'));
    await tester.pumpAndSettle();
    expect(loadEasyTrip(store).hotelAddress, 'Rua Augusta 1');
  });
}
