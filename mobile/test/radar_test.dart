// Radar local: lluvia real de MET Norway, timos que avisan los viajeros y
// "¿me cobran de más?" comparando con lo que pagaron otros.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:eclipta/core/router.dart';
import 'package:eclipta/features/map/geo.dart';
import 'package:eclipta/features/map/location.dart';
import 'package:eclipta/features/radar/radar_api.dart';

import 'helpers.dart';

class LisbonLocation extends FakeLocation {
  LisbonLocation() {
    access = LocationAccess.granted;
  }

  @override
  Stream<PositionFix> watch({TrackingNotice? background}) =>
      Stream<PositionFix>.value(
        PositionFix(
          point: const GeoPoint(38.7106, -9.1385),
          accuracyM: 10,
          recordedAt: DateTime.utc(2026, 10, 25),
        ),
      );
}

Map<String, Object?> rainJson() {
  final DateTime now = DateTime.now().toUtc();
  return <String, Object?>{
    'attribution': 'Data from MET Norway (CC BY 4.0)',
    'hours': <Object?>[
      for (int h = 0; h < 6; h++)
        <String, Object?>{
          'time': now.add(Duration(hours: h)).toIso8601String(),
          'rain_mm': h == 2 ? 1.4 : 0,
          'temp_c': 18,
        },
    ],
  };
}

const Map<String, Object?> radarJson = <String, Object?>{
  'city': 'LIS',
  'scams': <Object?>[
    <String, Object?>{'category': 'bracelet', 'reporters': 4},
  ],
  'prices': <Object?>[
    <String, Object?>{
      'item': 'coffee',
      'currency': 'EUR',
      'reporters': 7,
      'low': 0.9,
      'median': 1.1,
      'high': 1.4,
    },
  ],
  'my_scams': <String>[],
};

void main() {
  test('lluvia: la primera hora con ≥ 0,2 mm', () {
    final RainForecast r = RainForecast.parse(rainJson());
    expect(r.hours, hasLength(6));
    expect(r.firstRain!.rainMm, 1.4);
  });

  test('veredicto: comparado con lo que pagaron otros', () {
    const PriceRange coffee = PriceRange(
      item: PriceItem.coffee,
      currency: 'EUR',
      reporters: 7,
      low: 0.9,
      median: 1.1,
      high: 1.4,
    );
    expect(verdictFor(1.2, coffee), PriceVerdict.fine);
    expect(verdictFor(1.7, coffee), PriceVerdict.bitHigh);
    expect(verdictFor(4, coffee), PriceVerdict.overcharged);
  });

  test('datos raros del servidor se descartan', () {
    final CityRadar r = CityRadar.parse(<String, Object?>{
      'scams': <Object?>[
        <String, Object?>{'category': 'aliens', 'reporters': 9},
      ],
      'prices': <Object?>[
        <String, Object?>{'item': 'coffee', 'currency': 'EUR'},
      ],
      'my_scams': <String>['taxi', 'nope'],
    });
    expect(r.scams, isEmpty);
    expect(r.prices, isEmpty);
    expect(r.myScams, <ScamCategory>{ScamCategory.taxi});
  });

  testWidgets('lluvia, timo avisado, precio de más y avisar', (
    WidgetTester tester,
  ) async {
    final FakeGateway g = FakeGateway()..publicPrefixes.add('/v1/rain');
    final List<Uri> rainAsked = <Uri>[];
    final List<Map<String, Object?>> posts = <Map<String, Object?>>[];
    g.services['/v1/rain'] = (http.Request r) {
      rainAsked.add(r.url);
      return FakeGateway.json(rainJson());
    };
    g.services['/v1/radar/LIS'] = (_) => FakeGateway.json(radarJson);
    g.services['/v1/radar/LIS/scams'] = (http.Request r) {
      posts.add(jsonDecode(r.body) as Map<String, Object?>);
      return http.Response('', 204);
    };
    g.services['/v1/radar/LIS/prices'] = (http.Request r) {
      posts.add(jsonDecode(r.body) as Map<String, Object?>);
      return http.Response('', 204);
    };
    final session = await signedInSession(g);
    tester.view.physicalSize = const Size(1200, 5000);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await pumpApp(
      tester,
      locale: 'es',
      session: session,
      initialLocation: Routes.radar(iata: 'LIS'),
      services: fakeServices(session, gateway: g, location: LisbonLocation()),
    );
    await tester.pumpAndSettle();

    // Al servidor solo va una celda gruesa, no el punto exacto.
    expect(rainAsked.single.queryParameters['lat'], isNot('38.7106'));
    expect(find.textContaining('Lluvia desde las'), findsOneWidget);
    expect(find.textContaining('MET Norway'), findsOneWidget);

    expect(find.text('Pulsera o firma falsa'), findsWidgets);
    expect(find.textContaining('Avisado por 4 viajeros'), findsOneWidget);

    await tester.enterText(find.byType(TextField), '4');
    await tester.pumpAndSettle();
    expect(find.textContaining('de 0,90'), findsOneWidget);
    expect(find.text('Mucho más de lo que pagaron otros'), findsOneWidget);

    await tester.ensureVisible(find.text('Apuntar lo que pagué'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Apuntar lo que pagué'));
    await tester.pumpAndSettle();
    expect(posts.last, <String, Object?>{
      'item': 'coffee',
      'currency': 'EUR',
      'amount': '4.00',
    });

    final Finder taxi = find.widgetWithText(
      FilterChip,
      'Taxi que cobra de más',
    );
    await tester.ensureVisible(taxi);
    await tester.pumpAndSettle();
    await tester.tap(taxi);
    await tester.pumpAndSettle();
    expect(posts.last, <String, Object?>{'category': 'taxi'});
  });

  testWidgets('invitado: solo la lluvia, y pide entrar para lo demás', (
    WidgetTester tester,
  ) async {
    final FakeGateway g = FakeGateway()..publicPrefixes.add('/v1/rain');
    g.services['/v1/rain'] = (_) => FakeGateway.json(rainJson());
    g.services['/v1/radar/LIS'] = (_) => FakeGateway.json(radarJson);
    final session = newSession(g)..continueAsGuest();
    await pumpApp(
      tester,
      locale: 'es',
      session: session,
      initialLocation: Routes.radar(iata: 'LIS'),
      services: fakeServices(session, gateway: g, location: LisbonLocation()),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('Lluvia desde las'), findsOneWidget);
    expect(
      find.text(
        'Inicia sesión para ver y compartir lo que avisan otros viajeros.',
      ),
      findsWidgets,
    );
  });
}
