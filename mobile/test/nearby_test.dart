// Cerca de ti: lo gratis de alrededor y el paseo de "tengo tiempo".
// GPS de mentira en la Puerta del Sol.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:eclipta/core/router.dart';
import 'package:eclipta/features/map/geo.dart';
import 'package:eclipta/features/map/location.dart';
import 'package:eclipta/features/nearby/nearby_api.dart';
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

  testWidgets('agua cerca, baños de pago y el paseo de 2 horas', (
    WidgetTester tester,
  ) async {
    final FakeGateway g = FakeGateway()..publicPrefixes.add('/v1/nearby');
    final List<Uri> sent = <Uri>[];
    g.services['/v1/nearby'] = (http.Request r) {
      sent.add(r.url);
      return FakeGateway.json(nearbyJson);
    };
    final List<Uri> opened = <Uri>[];
    final session = newSession()..continueAsGuest();
    tester.view.physicalSize = const Size(1200, 4000);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
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
      ),
    );
    await tester.pumpAndSettle();

    // El servidor solo recibe la casilla (dos decimales).
    expect(sent.single.queryParameters, <String, String>{
      'lat': '40.42',
      'lon': '-3.70',
    });
    expect(find.text('Fuente de Sol'), findsOneWidget);
    expect(find.text('111 m'), findsOneWidget);
    await tester.tap(find.byTooltip('Ir').first);
    expect(opened.single.queryParameters['travelmode'], 'walking');

    await tester.tap(find.widgetWithText(ChoiceChip, 'Baños'));
    await tester.pumpAndSettle();
    expect(find.textContaining('de pago'), findsOneWidget);

    await tester.tap(find.text('Tengo tiempo'));
    await tester.pumpAndSettle();
    expect(find.text('Plaza Mayor'), findsOneWidget);
    expect(find.text('SALIDA Y LLEGADA'), findsNWidgets(2));
    await tester.tap(find.text('Abrir el paseo en el mapa'));
    expect(opened.last.queryParameters['waypoints'], '40.41550,-3.70740');
  });

  // Abre "Cerca de ti" con el GPS dado y espera a que termine de buscar.
  Future<void> openNearby(WidgetTester tester, FakeLocation gps) async {
    final session = newSession()..continueAsGuest();
    await pumpApp(
      tester,
      locale: 'es',
      session: session,
      initialLocation: Routes.nearby,
      services: fakeServices(session, gateway: FakeGateway(), location: gps),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('con permiso pero sin señal avisa de que reintente', (
    WidgetTester tester,
  ) async {
    final FakeLocation gps = FakeLocation()
      ..access = LocationAccess.granted
      ..currentFix = null;
    await openNearby(tester, gps);
    expect(
      find.textContaining('Todavía no consigo tu posición'),
      findsOneWidget,
    );
    expect(find.textContaining('Necesito tu ubicación'), findsNothing);
    expect(find.text('Reintentar'), findsOneWidget);
  });

  testWidgets('un error del GPS no rompe la pantalla', (
    WidgetTester tester,
  ) async {
    final FakeLocation gps = FakeLocation()
      ..access = LocationAccess.granted
      ..currentError = Exception('fallo del GPS');
    await openNearby(tester, gps);
    expect(
      find.textContaining('Todavía no consigo tu posición'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('sin permiso sigue pidiendo activar la ubicación', (
    WidgetTester tester,
  ) async {
    final FakeLocation gps = FakeLocation()
      ..access = LocationAccess.serviceOff;
    await openNearby(tester, gps);
    expect(find.textContaining('Necesito tu ubicación'), findsOneWidget);
    expect(gps.currents, 0);
  });
}
