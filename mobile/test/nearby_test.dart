// Cerca de ti: la página de la maqueta con los sitios reales de alrededor,
// el horario de OSM y los planes de 2 horas. GPS de mentira en Sol.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:eclipta/core/router.dart';
import 'package:eclipta/features/map/geo.dart';
import 'package:eclipta/features/map/location.dart';
import 'package:eclipta/features/nearby/nearby_api.dart';
import 'package:eclipta/features/nearby/nearby_page.dart';
import 'package:eclipta/features/nearby/opening_hours.dart';
import 'package:eclipta/l10n/generated/app_localizations.dart';
import 'package:eclipta/features/nearby/walk.dart';

import 'helpers.dart';

const GeoPoint sol = GeoPoint(40.4169, -3.7035);

class SolLocation extends FakeLocation {
  SolLocation() {
    access = LocationAccess.granted;
  }

  // Cerca de ti pide una posición con current(), no con watch().
  @override
  Future<PositionFix?> current() async => PositionFix(
    point: sol,
    accuracyM: 10,
    recordedAt: DateTime.utc(2026, 10, 25),
  );
}

NearbySpot sight(String id, double lat, double lon, String name) => NearbySpot(
  id: id,
  kind: NearbyKind.sight,
  point: GeoPoint(lat, lon),
  name: name,
);

const Map<String, Object?> nearbyJson = <String, Object?>{
  'lat': 40.42,
  'lon': -3.7,
  'attribution': '© OpenStreetMap contributors (ODbL)',
  'spots': <Object?>[
    // ~110 m al norte.
    <String, Object?>{
      'id': 'n1',
      'kind': 'water',
      'lat': 40.4179,
      'lon': -3.7035,
      'name': 'Fuente de Sol',
      'opening_hours': '24/7',
    },
    // Más lejos: sale segunda.
    <String, Object?>{
      'id': 'n2',
      'kind': 'water',
      'lat': 40.4200,
      'lon': -3.7035,
    },
    <String, Object?>{
      'id': 'n3',
      'kind': 'toilets',
      'lat': 40.4170,
      'lon': -3.7040,
      'fee': true,
    },
    <String, Object?>{
      'id': 'n4',
      'kind': 'sight',
      'lat': 40.4155,
      'lon': -3.7074,
      'name': 'Plaza Mayor',
      'wikidata_id': 'Q622574',
    },
    // ~300 m al oeste, gratis y abierto hasta las 20:00.
    <String, Object?>{
      'id': 'n5',
      'kind': 'sight',
      'sub': 'viewpoint',
      'lat': 40.4169,
      'lon': -3.7070,
      'name': 'Mirador <de> Sol',
      'opening_hours': 'Mo-Su 10:00-20:00',
    },
    // Un museo sin "gratis" en OSM: no sale en Gratis, sí en los planes.
    <String, Object?>{
      'id': 'n6',
      'kind': 'sight',
      'sub': 'museum',
      'lat': 40.4138,
      'lon': -3.6921,
      'name': 'Museo del Prado',
    },
    <String, Object?>{
      'id': 'r5326',
      'kind': 'place',
      'sub': '8',
      'lat': 40.42,
      'lon': -3.7,
      'name': 'Madrid',
    },
    <String, Object?>{
      'id': 'r1',
      'kind': 'place',
      'sub': '10',
      'lat': 40.42,
      'lon': -3.7,
      'name': 'Sol',
    },
    <String, Object?>{'id': 'bad', 'kind': 'water', 'lat': 1, 'lon': 1},
  ],
};

void main() {
  test('el paseo vuelve a tiempo y no se aleja de más', () {
    final List<NearbySpot> sights = <NearbySpot>[
      sight('a', 40.4155, -3.7074, 'Plaza Mayor'), // ~370 m
      sight('b', 40.4180, -3.7143, 'Palacio Real'), // ~900 m
      sight('c', 40.4530, -3.6883, 'Bernabéu'), // ~4 km: no da tiempo
    ];
    final WalkPlan short = planWalk(sol, sights, 60);
    expect(short.stops.map((WalkStop s) => s.spot.name), <String>[
      'Plaza Mayor',
    ]);
    expect(short.totalMinutes, lessThanOrEqualTo(60));

    final WalkPlan long = planWalk(sol, sights, 120);
    expect(long.stops.map((WalkStop s) => s.spot.name), <String>[
      'Plaza Mayor',
      'Palacio Real',
    ]);
    expect(long.totalMinutes, lessThanOrEqualTo(120));
    // Google Maps: sale y vuelve a Sol, pasando por las paradas.
    expect(long.mapsUrl.queryParameters['origin'], '40.41690,-3.70350');
    expect(long.mapsUrl.queryParameters['destination'], '40.41690,-3.70350');
    expect(long.mapsUrl.queryParameters['waypoints'], contains('|'));

    expect(planWalk(sol, const <NearbySpot>[], 120).stops, isEmpty);
  });

  test('el horario de OSM: abierto, cuánto le queda, 24/7 y lo raro', () {
    // Miércoles 4-11-2026 a las 18:20.
    final DateTime wed = DateTime(2026, 11, 4, 18, 20);
    OpenNow at(String h, [DateTime? when]) => openNow(h, when ?? wed);
    expect(at('24/7').state, OpenState.always);
    expect(at('Mo-Su 00:00-24:00').state, OpenState.always);
    final OpenNow o = at('Mo-Fr 09:00-20:00; Sa 10:00-14:00');
    expect((o.state, o.left, o.total), (OpenState.open, 100, 660));
    expect(at('Mo-Fr 09:00-14:00,17:00-19:00').left, 40);
    expect(at('Sa,Su 10:00-20:00').state, OpenState.closed);
    expect(at('Mo-Su 10:00-20:00; We off').state, OpenState.closed);
    // Un bar que cierra a las 2: el jueves a la 1:00 aún está abierto.
    final OpenNow late = at('We 20:00-02:00', DateTime(2026, 11, 5, 1));
    expect((late.state, late.left), (OpenState.open, 60));
    expect(at('Apr-Oct Mo-Su 10:00-20:00').state, OpenState.unknown);
    expect(at('sunrise-sunset').state, OpenState.unknown);
    expect(openNow(null, wed).state, OpenState.unknown);
  });

  test(
    'la página: gratis, planes de 2 h y barrio (sin tiendas en la zona)',
    () {
      final AppLocalizations t = lookupAppLocalizations(const Locale('es'));
      final NearbyList found = NearbyList.parse(nearbyJson);
      final NearbyPageData data = nearbyPageData(
        t: t,
        language: 'es',
        now: DateTime(2026, 11, 4, 18, 20),
        me: sol,
        found: found,
      );
      final Map<String, Object?> j = data.json;
      expect(j['offers'], isEmpty);
      expect(j['place'], 'Madrid · Sol');
      expect(j['attr'], '© OpenStreetMap contributors (ODbL)');
      final List<Map<String, Object?>> free = (j['free']! as List<Object?>)
          .cast<Map<String, Object?>>();
      // El baño de pago y el museo sin "gratis" no salen; el mirador sí.
      expect(free.map((Map<String, Object?> f) => f['t']), <String>[
        'Fuente de Sol',
        'Mirador <de> Sol',
        'Agua potable',
      ]);
      expect(free.first['d'], 110);
      expect(free.first['k'], 'water');
      expect(free.first['cp'], <String>['Gratis', 'AGUA POTABLE', '#9fd8ff']);
      expect(free.first['hrs'], 'Abierto 24 h');
      // El mirador está al oeste: ángulo ~180°.
      expect((free[1]['a']! as double).abs(), closeTo(3.14, 0.2));
      expect(free[1]['end'], 100);
      expect(
        data.routes[100]!.queryParameters['destination'],
        '40.41790,-3.70350',
      );
      final List<Map<String, Object?>> plans = (j['plans']! as List<Object?>)
          .cast<Map<String, Object?>>();
      expect(
        plans.first['t'],
        'Mirador <de> Sol, Plaza Mayor y Museo del Prado',
      );
      expect(plans.first['v'], '3 paradas');
      expect(plans.first['pr'], isNull); // el museo: precio sin datos
      expect(
        (plans.first['walk']! as int) + (plans.first['dur']! as int),
        lessThanOrEqualTo(planMinutes),
      );
      expect(data.routes[200]!.queryParameters['waypoints'], contains('|'));
      expect(initials('Museo del Prado'), 'MP');
      expect(initials('Wc'), 'WC');

      // Al meterlo en la página, nada puede cerrar el <script>.
      final String page = File(nearbyPage).readAsStringSync();
      expect(page, isNot(contains('Datos de ejemplo')));
      expect(page, isNot(contains('Farolillo')));
      expect(page, contains(nearbyMarker));
      final String html = nearbyPageWith(page, data);
      expect(html, isNot(contains('Mirador <de>')));
      expect(html, contains(r'Mirador \u003cde> Sol'));
    },
  );

  test('Tiendas y sitios: lo cercano primero, abierto o cerrado y su ruta', () {
    final AppLocalizations t = lookupAppLocalizations(const Locale('es'));
    NearbySpot shop(String id, double lat, String? sub, String? hours) =>
        NearbySpot(
          id: id,
          kind: NearbyKind.shop,
          point: GeoPoint(lat, -3.7035),
          name: 'Sitio $id',
          sub: sub,
          openingHours: hours,
        );
    final NearbyPageData data = nearbyPageData(
      t: t,
      language: 'es',
      // Miércoles 18:20.
      now: DateTime(2026, 11, 4, 18, 20),
      me: sol,
      found: NearbyList(
        spots: <NearbySpot>[
          shop('n1', 40.4171, 'cafe', 'Mo-Su 08:00-23:00'),
          shop('n2', 40.4172, 'supermarket', 'Mo-Su 09:00-12:00'),
          shop('n3', 40.4175, 'pharmacy', '24/7'),
          shop('n4', 40.4180, 'atm', null),
          shop('n5', 40.4185, 'Ropa rara', null),
        ],
        attribution: '© OpenStreetMap contributors (ODbL)',
      ),
    );
    final List<Map<String, Object?>> shops =
        (data.json['offers']! as List<Object?>).cast<Map<String, Object?>>();
    expect(data.json['tab'], 0);
    // El súper cerrado se va al final aunque esté más cerca.
    expect(shops.map((Map<String, Object?> s) => s['t']), <String>[
      'Sitio n1',
      'Sitio n3',
      'Sitio n4',
      'Sitio n5',
      'Sitio n2',
    ]);
    expect(shops[0]['k'], 'cafe');
    expect(shops[0]['v'], 'Cafetería');
    expect(shops[0]['cp'], <String>['Abierto', '→ 23:00', '#e8c7a3']);
    expect(shops[0]['end'], 280);
    expect(shops[1]['cp'], <String>['24 H', 'ABIERTO 24 H', '#9ff0b0']);
    expect(shops[2]['v'], 'Cajero');
    expect(shops[3]['k'], 'shop'); // lo que no conocemos: "Tienda"
    expect((shops[4]['cp']! as List<String>).first, 'Cerrado');
    expect(data.routes[0]!.queryParameters['destination'], '40.41710,-3.70350');
  });

  testWidgets('abre la maqueta con los sitios reales; Ruta y Volver', (
    WidgetTester tester,
  ) async {
    final FakeGateway g = FakeGateway()..publicPrefixes.add('/v1/nearby');
    final List<Uri> sent = <Uri>[];
    g.services['/v1/nearby'] = (http.Request r) {
      sent.add(r.url);
      return FakeGateway.json(nearbyJson);
    };
    final List<Uri> opened = <Uri>[];
    final List<String> pages = <String>[];
    void Function(String)? send;
    final session = newSession()..continueAsGuest();
    await pumpApp(
      tester,
      locale: 'es',
      session: session,
      initialLocation: Routes.nearby,
      services: fakeServices(
        session,
        gateway: g,
        location: SolLocation(),
        openBooking: (Uri u) async {
          opened.add(u);
          return true;
        },
        webScene: (String html, void Function(String) onMessage) {
          pages.add(html);
          send = onMessage;
          return const SizedBox.expand();
        },
      ),
    );
    await waitPages(tester, pages);
    // El servidor solo recibe la casilla (dos decimales).
    expect(sent.single.queryParameters, <String, String>{
      'lat': '40.42',
      'lon': '-3.70',
    });
    final Map<String, Object?> data = pageData(pages.last);
    expect(data['place'], 'Madrid · Sol');
    expect((data['free']! as List<Object?>).length, 3);
    send!('route:100');
    expect(opened.single.queryParameters['travelmode'], 'walking');
    send!('route:999'); // un número que no existe: nada
    send!('nada');
    expect(opened, hasLength(1));
  });

  // Abre "Cerca de ti" con el GPS dado y devuelve lo que enseña la página.
  Future<Map<String, Object?>> openNearby(
    WidgetTester tester,
    FakeLocation gps,
  ) async {
    final session = newSession()..continueAsGuest();
    final List<String> pages = <String>[];
    await pumpApp(
      tester,
      locale: 'es',
      session: session,
      initialLocation: Routes.nearby,
      services: fakeServices(
        session,
        gateway: FakeGateway(),
        location: gps,
        webScene: (String html, void Function(String) _) {
          pages.add(html);
          return const SizedBox.expand();
        },
      ),
    );
    await waitPages(tester, pages);
    return pageData(pages.last);
  }

  testWidgets('con permiso pero sin señal avisa de que reintente', (
    WidgetTester tester,
  ) async {
    final FakeLocation gps = FakeLocation()
      ..access = LocationAccess.granted
      ..currentFix = null;
    final Map<String, Object?> data = await openNearby(tester, gps);
    expect(data['msg'], contains('Todavía no consigo tu posición'));
    expect(data['retry'], isTrue);
    expect(data['free'], isEmpty);
  });

  testWidgets('un error del GPS no rompe la pantalla', (
    WidgetTester tester,
  ) async {
    final FakeLocation gps = FakeLocation()
      ..access = LocationAccess.granted
      ..currentError = Exception('fallo del GPS');
    final Map<String, Object?> data = await openNearby(tester, gps);
    expect(data['msg'], contains('Todavía no consigo tu posición'));
    expect(tester.takeException(), isNull);
  });

  testWidgets('sin permiso sigue pidiendo activar la ubicación', (
    WidgetTester tester,
  ) async {
    final FakeLocation gps = FakeLocation()..access = LocationAccess.serviceOff;
    final Map<String, Object?> data = await openNearby(tester, gps);
    expect(data['msg'], contains('Necesito tu ubicación'));
    expect(gps.currents, 0);
  });
}

/// Espera (de verdad: la página se lee de los assets) a que la página ya
/// no diga "Buscando qué hay cerca…".
Future<void> waitPages(WidgetTester tester, List<String> pages) async {
  bool done() =>
      pages.isNotEmpty &&
      pageData(pages.last)['msg'] != 'Buscando qué hay cerca…';
  for (int i = 0; i < 50 && !done(); i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pump(const Duration(milliseconds: 100));
  }
  expect(done(), isTrue);
}

/// Los datos que la app metió en la página.
Map<String, Object?> pageData(String html) => jsonDecode(
  html.substring(html.indexOf('var ECL=') + 8, html.indexOf(';\nvar T=ECL.t')),
) as Map<String, Object?>;
