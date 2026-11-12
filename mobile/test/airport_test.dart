// Aeropuerto: la flecha a tu puerta y al baño, con distancia y "te da
// tiempo". GPS y brújula de mentira.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:eclipta/core/router.dart';
import 'package:eclipta/core/settings.dart';
import 'package:eclipta/features/airport/airport_guide.dart';
import 'package:eclipta/features/camera/speaker.dart';
import 'package:eclipta/features/easy/easy_mode.dart';
import 'package:eclipta/features/map/geo.dart';
import 'package:eclipta/features/map/location.dart';

import 'helpers.dart';

/// Dentro de la T4 de Barajas.
class BarajasLocation extends FakeLocation {
  BarajasLocation() {
    access = LocationAccess.granted;
  }

  @override
  Stream<PositionFix> watch({TrackingNotice? background}) =>
      Stream<PositionFix>.value(
        PositionFix(
          point: const GeoPoint(40.4900, -3.5900),
          accuracyM: 15,
          recordedAt: DateTime.utc(2026, 10, 25),
        ),
      );
}

const Map<String, Object?> guideJson = <String, Object?>{
  'iata': 'MAD',
  'lat': 40.472,
  'lon': -3.563,
  'attribution': '© OpenStreetMap contributors (ODbL)',
  'spots': <Object?>[
    // ~111 m al norte.
    <String, Object?>{
      'id': 'n1',
      'kind': 'gate',
      'lat': 40.4910,
      'lon': -3.5900,
      'ref': 'K42',
      'level': '1',
    },
    // ~59 m al este.
    <String, Object?>{
      'id': 'n2',
      'kind': 'toilets',
      'lat': 40.4900,
      'lon': -3.5893,
    },
    // Más lejos: no es el más cercano.
    <String, Object?>{
      'id': 'n3',
      'kind': 'toilets',
      'lat': 40.4950,
      'lon': -3.5900,
    },
    <String, Object?>{'id': 'n4', 'kind': 'nonsense', 'lat': 1, 'lon': 1},
  ],
};

/// Apunta lo que Flyra "dice" en voz alta.
class SaidSpeaker implements Speaker {
  final List<String> said = <String>[];

  @override
  Future<void> speak(String text, String language) async => said.add(text);

  @override
  Future<void> stop() async {}
}

void main() {
  test('Flyra no habla con cada temblor de la brújula', () {
    final TurnAnnouncer a = TurnAnnouncer();
    final DateTime t0 = DateTime.utc(2026, 11, 3, 10);
    DateTime at(int ms) => t0.add(Duration(milliseconds: ms));
    // La primera, enseguida.
    expect(a.update(Cue.straight, at(0)), Cue.straight);
    expect(a.update(Cue.straight, at(500)), isNull);
    // Un temblor de medio segundo hacia la izquierda: nada.
    expect(a.update(Cue.left, at(600)), isNull);
    expect(a.update(Cue.straight, at(1100)), isNull);
    // Izquierda de verdad (dura más de 1,2 s y ya pasaron 3 s).
    expect(a.update(Cue.left, at(3000)), isNull);
    expect(a.update(Cue.left, at(4300)), Cue.left);
    expect(a.update(Cue.left, at(6000)), isNull);
    // Llegar se dice aunque no hayan pasado 3 s desde el último aviso.
    expect(a.update(Cue.arrived, at(6100)), isNull);
    expect(a.update(Cue.arrived, at(7400)), Cue.arrived);
    // Destino nuevo: vuelve a decirse al momento.
    a.reset();
    expect(a.update(Cue.right, at(7500)), Cue.right);
    expect(cueFor(10, 90), Cue.arrived);
    expect(cueFor(100, -90), Cue.left);
  });

  test('rumbo, giro y minutos andando', () {
    const GeoPoint here = GeoPoint(40.49, -3.59);
    expect(bearingTo(here, const GeoPoint(40.50, -3.59)), closeTo(0, 0.5));
    expect(bearingTo(here, const GeoPoint(40.49, -3.58)), closeTo(90, 0.5));
    expect(turnFor(10), Turn.straight);
    expect(turnFor(-90), Turn.left);
    expect(turnFor(90), Turn.right);
    expect(turnFor(180), Turn.back);
    expect(turnFor(350), Turn.straight);
    expect(walkMinutes(10), 1);
    expect(walkMinutes(450), 6);
  });

  test('la puerta se encuentra escrita de cualquier manera', () {
    final AirportGuide g = AirportGuide.parse(guideJson);
    expect(g.spots, hasLength(3));
    expect(g.gate('k 42')?.id, 'n1');
    expect(g.gate('K43'), isNull);
    expect(g.nearest(SpotKind.toilets, const GeoPoint(40.49, -3.59))?.id, 'n2');
  });

  testWidgets('tu vuelo sale de Barajas: flecha a la K42 y al baño', (
    WidgetTester tester,
  ) async {
    final FakeGateway g = FakeGateway()..publicPrefixes.add('/v1/airports/');
    g.services['/v1/airports/MAD/spots'] = (http.Request r) =>
        FakeGateway.json(guideJson);
    final MemorySettingsStore store = MemorySettingsStore('es');
    await saveEasyTrip(
      store,
      EasyTrip(
        departure: DateTime.now().add(const Duration(hours: 3)),
        from: 'MAD',
        to: 'HND',
        gate: 'K42',
      ),
    );
    final session = newSession()..continueAsGuest();
    final SaidSpeaker voice = SaidSpeaker();
    tester.view.physicalSize = const Size(1200, 4000);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await pumpApp(
      tester,
      locale: 'es',
      session: session,
      initialLocation: Routes.airport(),
      services: fakeServices(
        session,
        gateway: g,
        prefs: store,
        location: BarajasLocation(),
        speaker: voice,
      ),
    );
    await tester.pumpAndSettle();

    // Arriba, el aeropuerto; en la tarjeta y en el panel de Flyra, el giro.
    expect(find.textContaining('MAD'), findsOneWidget);
    expect(find.text('Sigue recto 111 m'), findsNWidgets(2));
    // Como en la maqueta, la voz empieza apagada: se enciende y lo dice.
    expect(voice.said, isEmpty);
    await tester.tap(find.bySemanticsLabel('Voz de Flyra'));
    await tester.pumpAndSettle();
    expect(voice.said, contains('Sigue recto 111 m'));
    expect(find.text('TU PUERTA'), findsOneWidget);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      'K42',
    );
    expect(find.text('Planta 1 · Sigue también los carteles'), findsOneWidget);
    expect(find.text('2 min'), findsOneWidget);

    await tester.tap(find.text('Baño'));
    await tester.pumpAndSettle();
    expect(find.text('Gira a la derecha'), findsNWidgets(2));
    expect(voice.said.last, 'Gira a la derecha');

    // Con la voz apagada, Flyra se calla (el aviso sigue en pantalla).
    await tester.tap(find.bySemanticsLabel('Voz de Flyra'));
    await tester.pumpAndSettle();
    final int before = voice.said.length;
    await tester.tap(find.text('Puerta'));
    await tester.pumpAndSettle();
    expect(voice.said, hasLength(before));
    await tester.tap(find.text('Baño'));
    await tester.pumpAndSettle();
    expect(find.text('1 min'), findsOneWidget);
    expect(find.text('59 m'), findsOneWidget);
  });

  testWidgets('un aeropuerto sin dibujar dentro lo dice', (
    WidgetTester tester,
  ) async {
    final FakeGateway g = FakeGateway()..publicPrefixes.add('/v1/airports/');
    g.services['/v1/airports/LIS/spots'] = (http.Request r) =>
        FakeGateway.json(<String, Object?>{
          'iata': 'LIS',
          'lat': 38.78,
          'lon': -9.13,
          'spots': <Object?>[],
        });
    final session = newSession()..continueAsGuest();
    await pumpApp(
      tester,
      locale: 'es',
      session: session,
      initialLocation: Routes.airport(iata: 'LIS'),
      services: fakeServices(session, gateway: g),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('aún no está dibujado'), findsOneWidget);
  });

  testWidgets('pide la ubicación al entrar y busca el aeropuerto por nombre', (
    WidgetTester tester,
  ) async {
    final FakeGateway g = FakeGateway()..publicPrefixes.add('/v1/airports/');
    final List<String> asked = <String>[];
    g.services['/v1/airports/AGP/spots'] = (http.Request r) {
      asked.add(r.url.path);
      return FakeGateway.json(<String, Object?>{
        'iata': 'AGP',
        'lat': 36.67,
        'lon': -4.49,
        'spots': <Object?>[],
      });
    };
    final FakeLocation gps = FakeLocation()
      ..onRequest = LocationAccess.deniedForever;
    final session = newSession()..continueAsGuest();
    tester.view.physicalSize = const Size(1200, 4000);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await pumpApp(
      tester,
      locale: 'es',
      session: session,
      initialLocation: Routes.airport(),
      services: fakeServices(session, gateway: g, location: gps),
    );
    await tester.pumpAndSettle();
    // La pregunta del sistema sale sola, sin botón "Activar ubicación".
    expect(gps.requests, 1);
    expect(find.text('Escribe abajo su ciudad o su nombre'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'aeropuerto de malaga');
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 300)),
    );
    await tester.pumpAndSettle();
    expect(find.text('Málaga'), findsWidgets);
    await tester.tap(find.text('España · AGP'));
    await tester.pumpAndSettle();
    expect(asked, <String>['/v1/airports/AGP/spots']);
  });
}
