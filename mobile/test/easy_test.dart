// Modo fácil: Inicio con letras grandes, el vuelo, a qué hora salir de casa
// y los botones grandes (hotel, familia, ayuda, papeles y Flyra).
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:eclipta/auth/session.dart';
import 'package:eclipta/core/router.dart';
import 'package:eclipta/core/settings.dart';
import 'package:eclipta/features/easy/easy_home_screen.dart';
import 'package:eclipta/features/easy/easy_mode.dart';

import 'helpers.dart';
import 'money_test.dart' as m;
import 'voice_test.dart' as v;

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

  testWidgets('Inicio en Modo fácil: vuelo, hotel, familia, Flyra y volver', (
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
    final List<String> shared = <String>[];
    final m.PageSpy spy = m.PageSpy();
    final v.FakeMic mic = v.FakeMic()..heard.add('llévame al hotel');
    final v.FakeSpeaker speaker = v.FakeSpeaker();
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
        webScene: spy.build,
        speechInput: mic,
        speaker: speaker,
        share: (List<String> files, {String? text}) async => shared.add(text!),
        openLink: (Uri u) async {
          opened.add(u);
          return true;
        },
      ),
    );
    await spy.wait(
      tester,
      () => spy.pages.any((String h) => h.contains('ECLIPTA · Modo fácil')),
    );
    // Los aeropuertos de verdad (assets/geo) tardan un poco en cargarse.
    // (Son tres archivos seguidos: se deja avanzar varias veces.)
    for (int i = 0; i < 4; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 600)),
      );
      await tester.pumpAndSettle();
    }
    Map<String, Object?> data() =>
        spy.data(EasyHomeScreen.lastBridge!, title: 'ECLIPTA · Modo fácil');
    final Map<String, Object?> flight =
        data()['flight']! as Map<String, Object?>;
    expect(flight['route'], 'Madrid → Lisbon');
    expect(flight['time'], '10:30');
    expect(flight['gate'], 'B12');
    expect(flight['leave'], ' · sal de casa a las 7:30');
    void send(String msg) => spy.to('ECLIPTA · Modo fácil')(msg);

    // El hotel: ir andando abre la ruta a pie con la dirección; para el
    // taxista, la frase en portugués (el idioma de Lisboa).
    send('walk');
    expect(opened.last.queryParameters['destination'], contains('Augusta'));
    expect(opened.last.queryParameters['travelmode'], 'walking');
    expect(
      (data()['hotel']! as Map<String, Object?>)['phrase'],
      'Por favor, leve-me a este hotel. Obrigado.',
    );

    // La familia: tocar la persona llama; el botón verde abre WhatsApp.
    expect(
      ((data()['family']! as List<Object?>).single!
          as Map<String, Object?>)['name'],
      'Noelia',
    );
    send('call:0');
    expect(opened.last.scheme, 'tel');
    send('video:0');
    expect(opened.last.toString(), 'https://wa.me/34600112233');

    // La ayuda del aeropuerto: se pide, se guarda y se manda el mensaje.
    send('help:1');
    await tester.pumpAndSettle();
    expect(loadEasyTrip(store).help, 1);
    expect(data()['help'], 1);
    expect(data()['helpDone'], startsWith('Hecho: que me acompañen andando'));
    send('send');
    expect(shared.single, contains('que me acompañen andando'));

    // Flyra escucha y contesta con tu viaje; su botón abre la ruta.
    send('listen');
    await tester.pumpAndSettle();
    expect(data()['flyN'], 1);
    expect(data()['flyQ'], 'llévame al hotel');
    expect(data()['flyAct'], 'Llévame');
    expect(speaker.said.single, contains('Rua Augusta'));
    send('act');
    expect(opened.last.queryParameters['travelmode'], 'transit');

    // "Modo normal" vuelve a la Inicio de siempre y se recuerda.
    send('normal');
    await tester.pumpAndSettle();
    expect(store.readData(LocalData.easyMode), isNull);
  });

  testWidgets('sin viaje invita a ponerlo y lo guarda', (
    WidgetTester tester,
  ) async {
    final FakeGateway g = FakeGateway();
    final SessionController session = await signedInSession(g);
    final MemorySettingsStore store = MemorySettingsStore();
    await store.writeData(LocalData.easyMode, '1');
    final m.PageSpy spy = m.PageSpy();
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
        webScene: spy.build,
      ),
    );
    await spy.wait(
      tester,
      () => spy.pages.any((String h) => h.contains('ECLIPTA · Modo fácil')),
    );
    final Map<String, Object?> d = spy.data(
      EasyHomeScreen.lastBridge!,
      title: 'ECLIPTA · Modo fácil',
    );
    expect(d['flight'], <String, Object?>{'k': 'TU VUELO'});
    expect(
      (d['t']! as Map<String, Object?>)['noHotel'],
      contains('dirección del hotel'),
    );

    spy.to('ECLIPTA · Modo fácil')('edit');
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
