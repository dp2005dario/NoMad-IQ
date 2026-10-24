// Explorar: precio por meses + clima medio, y el veredicto.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:nomadiq/auth/session.dart';
import 'package:nomadiq/core/router.dart';
import 'package:nomadiq/features/flights/climate_api.dart';
import 'package:nomadiq/features/flights/explore_screen.dart';
import 'package:nomadiq/features/flights/fares_api.dart';

import 'helpers.dart';

Map<String, Object?> month(
  String m,
  int price, {
  String link = 'https://www.aviasales.com/search/x',
}) => <String, Object?>{
  'month': m,
  'price_per_adult': <String, Object?>{
    'amount_minor': price,
    'currency': 'EUR',
  },
  'carrier': 'IB',
  'departure_at': '${m}-11',
  'return_at': '${m}-20',
  'transfers': 0,
  'booking_url': link,
};

Map<String, Object?> climateMonth(int m, double temp, double rain) =>
    <String, Object?>{
      'month': m,
      'temp_c': temp,
      'temp_max_c': temp + 6,
      'rain_mm': rain,
    };

void serveExplore(FakeGateway g) {
  g.publicPrefixes.addAll(<String>['/v1/fares/months', '/v1/climate']);
  g.services['/v1/fares/months'] = (http.Request r) => FakeGateway.json(
    <String, Object?>{
      'origin': r.url.queryParameters['origin'],
      'destination': r.url.queryParameters['destination'],
      'months': <Object?>[
        month('2026-11', 64000),
        month('2027-03', 41200),
        // Enlace que no es https: no se enseña.
        month('2027-04', 9900, link: 'http://insecure.example'),
        // Mes imposible: tampoco.
        <String, Object?>{'month': '2027-13', 'booking_url': 'https://x.test'},
      ],
    },
  );
  g.services['/v1/climate'] = (_) => FakeGateway.json(<String, Object?>{
    'lat': 35.5,
    'lon': 140.0,
    'months': <Object?>[climateMonth(3, 12.0, 40), climateMonth(11, 14.0, 300)],
  });
}

void main() {
  test('el mes más barato y el buen tiempo', () {
    final List<MonthFare> months = <MonthFare>[
      MonthFare.parse(month('2026-11', 64000))!,
      MonthFare.parse(month('2027-03', 41200))!,
    ];
    expect(cheapestMonth(months)!.month, 3);
    expect(cheapestMonth(<MonthFare>[]), isNull);
    expect(niceWeather(MonthClimate.parse(climateMonth(3, 18, 30))!), isTrue);
    // Demasiada lluvia.
    expect(niceWeather(MonthClimate.parse(climateMonth(7, 22, 300))!), isFalse);
    // Demasiado frío.
    expect(niceWeather(MonthClimate.parse(climateMonth(1, 2, 10))!), isFalse);
  });

  test('un mes raro o con enlace no https se descarta', () {
    expect(MonthFare.parse(month('2027-13', 1)), isNull);
    expect(MonthFare.parse(month('2027-03', 1, link: 'http://x.test')), isNull);
    expect(MonthFare.parse('nada'), isNull);
    final MonthFare? ok = MonthFare.parse(month('2027-03', 41200));
    expect(ok!.year, 2027);
    expect(ok.month, 3);
  });

  test('los días de lluvia salen del total de mm', () {
    expect(MonthClimate.parse(climateMonth(3, 12, 40))!.rainyDays, 8);
    expect(MonthClimate.parse(climateMonth(3, 12, 0))!.rainyDays, 0);
    expect(MonthClimate.parse(climateMonth(13, 12, 0)), isNull);
  });

  testWidgets('se eligen dos aeropuertos y sale el año con su veredicto', (
    WidgetTester tester,
  ) async {
    final FakeGateway g = FakeGateway();
    serveExplore(g);
    final SessionController session = await signedInSession(g);
    tester.view.physicalSize = const Size(1200, 2600);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await pumpApp(
      tester,
      locale: 'es',
      session: session,
      initialLocation: Routes.explore(origin: 'MAD'),
      services: fakeServices(session, gateway: g),
    );
    // Los aeropuertos de verdad (para el clima del destino) tardan un poco.
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(seconds: 2)),
    );
    await tester.pumpAndSettle();
    expect(find.text('Explorar'), findsOneWidget);

    await tester.enterText(find.widgetWithText(TextField, 'Destino'), 'nrt');
    await tester.tap(find.text('Ver el año'));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(seconds: 1)),
    );
    await tester.pumpAndSettle();

    // Solo los dos meses buenos, y marzo (el más barato) sale elegido.
    expect(find.text('El más barato: marzo'), findsOneWidget);
    expect(find.textContaining('412'), findsWidgets);
    // Marzo: 12°, 8 días de lluvia → buen tiempo.
    expect(find.text('8 días'), findsOneWidget);
    expect(
      find.text('marzo es el punto justo: barato y con buen tiempo.'),
      findsOneWidget,
    );

    // Noviembre llueve mucho: cambia el veredicto.
    await tester.tap(find.text('nov'));
    await tester.pumpAndSettle();
    expect(find.textContaining('el tiempo es peor'), findsOneWidget);

    // Y de ahí al buscador, ya con la ruta y las fechas de ese mes puestas.
    await tester.tap(find.textContaining('Ver vuelos a'));
    await tester.pumpAndSettle();
    expect(find.text('NRT'), findsWidgets);
    expect(find.textContaining('11 nov'), findsWidgets);
  });

  testWidgets('sin precios del mes lo dice, y 429 avisa de que esperes', (
    WidgetTester tester,
  ) async {
    final FakeGateway g = FakeGateway();
    serveExplore(g);
    g.services['/v1/fares/months'] = (_) =>
        FakeGateway.json(<String, Object?>{'months': <Object?>[]});
    final SessionController session = await signedInSession(g);
    tester.view.physicalSize = const Size(1200, 2600);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await pumpApp(
      tester,
      locale: 'es',
      session: session,
      initialLocation: Routes.explore(origin: 'MAD'),
      services: fakeServices(session, gateway: g),
    );
    await tester.enterText(find.widgetWithText(TextField, 'Destino'), 'NRT');
    await tester.tap(find.text('Ver el año'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Nadie ha buscado esta ruta'), findsOneWidget);

    g.services['/v1/fares/months'] = (_) => http.Response('{}', 429);
    await tester.tap(find.text('Ver el año'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Mucha gente buscando'), findsOneWidget);
  });
}
