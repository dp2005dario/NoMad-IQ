// Radar local: lluvia real de MET Norway, timos que avisan los viajeros y
// "¿me cobran de más?" comparando con lo que pagaron otros.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:intl/date_symbol_data_local.dart';
import 'package:eclipta/core/router.dart';
import 'package:eclipta/features/map/geo.dart';
import 'package:eclipta/features/map/location.dart';
import 'package:eclipta/features/radar/radar_api.dart';
import 'package:eclipta/features/radar/radar_page.dart';
import 'package:eclipta/features/radar/radar_screen.dart';

import 'helpers.dart';
import 'money_test.dart' as m;

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

  test('rótulo de la lluvia: ahora, en minutos o a qué hora', () async {
    await initializeDateFormatting('es');
    final DateTime now = DateTime(2026, 11, 9, 14, 20);
    String at(int h, int m) =>
        rainLabel(RainHour(DateTime(2026, 11, 9, h, m), 1, null), now, 'es');
    expect(at(14, 0), 'LLUEVE AHORA');
    expect(at(15, 0), 'LLUEVE EN 40 MIN');
    expect(at(17, 0), 'LLUEVE A LAS 17:00');
  });

  test('ningún dato puede cerrar el script de la página', () {
    final String html = radarPageWith('<script>window.ECL=$radarMarker;', {
      'x': '</script><b>',
    });
    expect(html, isNot(contains('</script><b>')));
    expect(radarPushScript({'x': '<b>'}), isNot(contains('<b>')));
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
    final List<Uri> safetyAsked = <Uri>[];
    g.services['/v1/radar/LIS/safety'] = (http.Request r) {
      safetyAsked.add(r.url);
      return FakeGateway.json(<String, Object?>{
        'city': 'Lisbon',
        'tips': <Object?>[
          <String, Object?>{
            'kind': 'theft',
            'text': 'Carteristas en el tranvía 28.',
          },
          <String, Object?>{'kind': 'raro', 'text': 'Cuesta mucho subir.'},
        ],
        'source_url': 'https://es.wikivoyage.org/wiki/Lisboa',
      });
    };
    g.services['/v1/radar/LIS/scams'] = (http.Request r) {
      posts.add(jsonDecode(r.body) as Map<String, Object?>);
      return http.Response('', 204);
    };
    g.services['/v1/radar/LIS/prices'] = (http.Request r) {
      posts.add(jsonDecode(r.body) as Map<String, Object?>);
      return http.Response('', 204);
    };
    final List<Uri> opened = <Uri>[];
    final m.PageSpy spy = m.PageSpy();
    final session = await signedInSession(g);
    await pumpApp(
      tester,
      locale: 'es',
      session: session,
      initialLocation: Routes.radar(iata: 'LIS'),
      services: fakeServices(
        session,
        gateway: g,
        location: LisbonLocation(),
        webScene: spy.build,
        openBooking: (Uri u) async {
          opened.add(u);
          return true;
        },
      ),
    );
    Map<String, Object?> data() => spy.data(RadarScreen.lastBridge!);
    await spy.wait(
      tester,
      () =>
          spy.pages.isNotEmpty &&
          data()['rainy'] == true &&
          data()['showPrice'] == true,
    );
    expect(spy.pages.first, contains('ECLIPTA · Radar local'));

    // Al servidor solo va una celda gruesa, no el punto exacto.
    expect(rainAsked.single.queryParameters['lat'], isNot('38.7106'));
    expect(data()['rainTxt'], contains('Lluvia desde las'));
    expect(data()['attr'], contains('MET Norway'));
    expect(data()['flyOn'], isFalse);
    spy.send!('go');
    await tester.pump();
    expect(opened.single.path, startsWith('/maps/search/cafe/'));

    await spy.wait(
      tester,
      () => (data()['scams']! as List<Object?>).length == 3,
    );
    final List<Map<String, Object?>> scams = (data()['scams']! as List<Object?>)
        .cast<Map<String, Object?>>();
    expect(scams.first['title'], 'Pulsera o firma falsa');
    expect(scams.first['by'], contains('Avisado por 4 viajeros'));
    expect(scams.first['kind'], 'scam');
    // Después, lo que dice la guía de la ciudad, en tu idioma.
    expect(safetyAsked.single.queryParameters['lang'], 'es');
    expect(scams[1]['title'], 'Robos y carteristas');
    expect(scams[1]['kind'], 'theft');
    expect(scams[1]['why'], 'Carteristas en el tranvía 28.');
    expect(scams[1]['by'], 'Según la guía Wikivoyage');
    expect(scams[2]['kind'], 'other');
    expect(scams[2]['title'], 'Ten en cuenta');

    // El café: lo que pagaron otros (de 0,90 a 1,40) y la moneda.
    expect(data()['curTxt'], 'EUR');
    expect(data()['rangeTxt'], contains('0,90'));
    expect(data()['range'], <String, Object?>{'low': 0.9, 'high': 1.4});

    spy.send!('paid:4.00');
    await spy.wait(tester, () => posts.isNotEmpty);
    expect(posts.last, <String, Object?>{
      'item': 'coffee',
      'currency': 'EUR',
      'amount': '4.00',
    });
    await spy.wait(tester, () => data()['sentKey'] == 'coffee:EUR:4.00');

    // La cerveza aún no tiene precios: lo dice tal cual.
    spy.send!('item:beer');
    await tester.pump();
    expect(data()['range'], isNull);

    spy.send!('scam:taxi');
    await spy.wait(tester, () => posts.length == 2);
    expect(posts.last, <String, Object?>{'category': 'taxi'});
  });

  testWidgets('invitado: solo la lluvia, y pide entrar para lo demás', (
    WidgetTester tester,
  ) async {
    final FakeGateway g = FakeGateway()..publicPrefixes.add('/v1/rain');
    g.services['/v1/rain'] = (_) => FakeGateway.json(rainJson());
    g.services['/v1/radar/LIS'] = (_) => FakeGateway.json(radarJson);
    final m.PageSpy spy = m.PageSpy();
    final session = newSession(g)..continueAsGuest();
    await pumpApp(
      tester,
      locale: 'es',
      session: session,
      initialLocation: Routes.radar(iata: 'LIS'),
      services: fakeServices(
        session,
        gateway: g,
        location: LisbonLocation(),
        webScene: spy.build,
      ),
    );
    Map<String, Object?> data() => spy.data(RadarScreen.lastBridge!);
    String why() =>
        ((data()['scams']! as List<Object?>).single!
                as Map<String, Object?>)['why']!
            as String;
    await spy.wait(
      tester,
      () =>
          spy.pages.isNotEmpty &&
          data()['rainy'] == true &&
          why().startsWith('Inicia sesión'),
    );
    expect(
      why(),
      'Inicia sesión para ver y compartir lo que avisan otros viajeros.',
    );
    expect(data()['showPrice'], isFalse);
  });

  testWidgets('sin previsión de lluvia: Flyra lo dice en su bocadillo', (
    WidgetTester tester,
  ) async {
    final FakeGateway g = FakeGateway()..publicPrefixes.add('/v1/rain');
    g.services['/v1/rain'] = (_) => http.Response('', 503);
    g.services['/v1/radar/LIS'] = (_) => FakeGateway.json(radarJson);
    final m.PageSpy spy = m.PageSpy();
    final session = newSession(g)..continueAsGuest();
    await pumpApp(
      tester,
      locale: 'es',
      session: session,
      initialLocation: Routes.radar(iata: 'LIS'),
      services: fakeServices(
        session,
        gateway: g,
        location: LisbonLocation(),
        webScene: spy.build,
      ),
    );
    Map<String, Object?> data() => spy.data(RadarScreen.lastBridge!);
    await spy.wait(
      tester,
      () => spy.pages.isNotEmpty && data()['flyOn'] == true,
    );
    expect(data()['flyText'], data()['rainTxt']);
    expect(data()['rainy'], isFalse);
  });
}
