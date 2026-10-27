// Aeropuerto: la flecha a tu puerta y al baño, con distancia y "te da
// tiempo". GPS y brújula de mentira.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:eclipta/core/router.dart';
import 'package:eclipta/core/settings.dart';
import 'package:eclipta/features/airport/airport_guide.dart';
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

void main() {
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
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('MAD'), findsOneWidget);
    expect(find.text('Sigue recto 111 m'), findsOneWidget);
    expect(find.text('Puerta K42'), findsOneWidget);
    expect(find.text('Planta 1'), findsOneWidget);
    expect(find.text('Te da tiempo'), findsOneWidget);

    await tester.tap(find.widgetWithText(ChoiceChip, 'Baño'));
    await tester.pumpAndSettle();
    expect(find.text('Gira a la derecha'), findsOneWidget);
    expect(find.text('1 min · 59 m'), findsOneWidget);
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
}
