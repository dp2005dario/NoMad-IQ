// Tests de la Ruta del vuelo: las matemáticas de la esfera, los datos que
// van dentro de la app (mapa y aeropuertos) y la pantalla completa: mundo →
// origen → vuelo → llegada.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nomadiq/core/api_client.dart';
import 'package:nomadiq/core/router.dart';
import 'package:nomadiq/core/theme.dart';
import 'package:nomadiq/features/route/city_sheet.dart';
import 'package:nomadiq/features/route/flight3d.dart';
import 'package:nomadiq/features/route/flight_route_screen.dart';
import 'package:nomadiq/features/flights/booking.dart';
import 'package:nomadiq/features/route/geo.dart';
import 'package:nomadiq/features/route/places_api.dart';
import 'package:nomadiq/features/route/world_data.dart';
import 'package:nomadiq/l10n/generated/app_localizations.dart';

import 'helpers.dart';

const LatLon madrid = LatLon(40.472, -3.563);
const LatLon tokyo = LatLon(35.765, 140.386);
const LatLon losAngeles = LatLon(33.942, -118.408);

Future<void> pumpRoute(
  WidgetTester tester, {
  String from = 'MAD',
  String? to = 'NRT',
  PlaceLoader? places,
  OpenBooking? openLink,
  WebSceneBuilder? scene3d,
}) async {
  tester.view.physicalSize = const Size(1170, 2532);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  // Los datos reales de la app (assets/geo), cargados una vez.
  final WorldData world = (await tester.runAsync(WorldData.load))!;
  await tester.pumpWidget(
    MaterialApp(
      theme: buildNomadTheme(),
      locale: const Locale('es'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: FlightRouteScreen(
        from: from,
        to: to,
        loadWorld: () async => world,
        places: places,
        openLink: openLink ?? (Uri _) async => true,
        scene3d: scene3d,
      ),
    ),
  );
  // El "latido" de los puntos no para nunca: se avanza el reloj a mano.
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 1500));
}

void main() {
  group('geo', () {
    test('Madrid → Tokio son unos 10.770 km y ~13 h', () {
      final double km = distanceKm(madrid, tokyo);
      expect(km, closeTo(10770, 60));
      expect(estimatedFlightTime(km).inHours, 13);
    });

    test('el camino más corto pasa por el norte (Rusia)', () {
      final LatLon mid = intermediate(madrid, tokyo, 0.5);
      expect(mid.lat, greaterThan(55));
      expect(intermediate(madrid, tokyo, 0).lat, closeTo(madrid.lat, 1e-6));
      expect(intermediate(madrid, tokyo, 1).lon, closeTo(tokyo.lon, 1e-6));
    });

    test('cruzar el meridiano 180 no hace saltar la línea', () {
      final List<LatLon> path = greatCircle(tokyo, losAngeles);
      for (int i = 1; i < path.length; i++) {
        expect((path[i].lon - path[i - 1].lon).abs(), lessThan(10));
      }
      expect(path.last.lon, closeTo(losAngeles.lon + 360, 1e-6));
    });
  });

  group('datos', () {
    test('aeropuertos: formato y líneas raras', () {
      final Airports a = Airports.parse(
        'MAD|40.472|-3.563|Madrid|Spain|Europe/Madrid\n'
        'roto\n'
        'XXX|no|1|A|B|C\n',
      );
      expect(a.length, 1);
      expect(a['mad']!.timeZone, 'Europe/Madrid');
    });

    test('mapa binario: firma y contenido', () {
      final ByteData ok = ByteData(4 + 4 + 4 + 8)
        ..setUint8(0, 0x4E)
        ..setUint8(1, 0x51)
        ..setUint8(2, 0x57)
        ..setUint8(3, 0x31)
        ..setUint32(4, 1, Endian.little)
        ..setUint32(8, 2, Endian.little)
        ..setInt16(12, -36, Endian.little)
        ..setInt16(14, 404, Endian.little)
        ..setInt16(16, 1403, Endian.little)
        ..setInt16(18, 357, Endian.little);
      final WorldShapes w = WorldShapes.parse(ok);
      final List<double> want = <double>[-3.6, 40.4, 140.3, 35.7];
      for (int i = 0; i < want.length; i++) {
        expect(w.rings.single[i], closeTo(want[i], 1e-4));
      }
      expect(() => WorldShapes.parse(ByteData(8)), throwsFormatException);
    });

    testWidgets('los datos de la app se cargan', (WidgetTester tester) async {
      final WorldData world = (await tester.runAsync(WorldData.load))!;
      expect(world.shapes.rings.length, greaterThan(1000));
      expect(world.airports.length, greaterThan(5000));
      expect(world.airports['NRT']!.city, 'Tokyo');
      expect(world.airports['JFK']!.timeZone, 'America/New_York');
    });
  });

  testWidgets('mundo → origen → vuelo → llegada', (WidgetTester tester) async {
    await pumpRoute(tester);
    expect(find.text('MAD → NRT'), findsOneWidget);
    expect(find.text('Madrid → Tokyo'), findsOneWidget);
    expect(find.textContaining('10.7'), findsOneWidget); // km con punto español
    expect(find.text('Mundo'), findsOneWidget);

    await tester.tap(find.text('Empezar en Madrid'));
    await tester.pump(const Duration(milliseconds: 1300));
    expect(find.text('ORIGEN'), findsOneWidget);
    expect(find.textContaining('Hora local'), findsOneWidget);

    await tester.tap(find.text('Despegar hacia Tokyo'));
    // En los tests cada animación arranca un fotograma después: la cámara se
    // coloca y, en el siguiente, despega el avión.
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 1300));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(seconds: 5));
    expect(find.text('Siguiendo el avión'), findsOneWidget);
    expect(find.textContaining('Recorrido'), findsOneWidget);
    expect(find.textContaining('Quedan'), findsOneWidget);
    // A mitad de camino ya no está en 0 km.
    expect(find.textContaining('Recorrido: 0 km'), findsNothing);

    // El vuelo simulado dura 14 s: se avanza en varios pasos.
    for (int i = 0; i < 4; i++) {
      await tester.pump(const Duration(seconds: 4));
    }
    await tester.pump(const Duration(milliseconds: 1300));
    expect(find.text('¡Has llegado a Tokyo!'), findsOneWidget);
    // Tokio va 7 u 8 horas por delante de Madrid (según el horario de verano).
    expect(
      find.textContaining(RegExp(r'[78] h más que Madrid')),
      findsOneWidget,
    );

    await tester.tap(find.text('Volver al origen'));
    await tester.pump(const Duration(milliseconds: 1300));
    expect(find.text('ORIGEN'), findsOneWidget);
  });

  testWidgets('aterrizar ya', (WidgetTester tester) async {
    await pumpRoute(tester, from: 'JFK', to: 'LHR');
    await tester.tap(find.text('Empezar en New York'));
    await tester.pump(const Duration(milliseconds: 1300));
    await tester.tap(find.text('Despegar hacia London'));
    await tester.pump(const Duration(milliseconds: 1500));
    await tester.tap(find.text('Aterrizar ya'));
    await tester.pump(const Duration(milliseconds: 1300));
    expect(find.text('¡Has llegado a London!'), findsOneWidget);
    expect(find.textContaining('h más que New York'), findsOneWidget);
  });

  testWidgets('sin destino: se pregunta y se valida', (
    WidgetTester tester,
  ) async {
    await pumpRoute(tester, to: null);
    await tester.pump(const Duration(milliseconds: 500));
    expect(
      find.text('Código del aeropuerto de destino (p. ej. NRT)'),
      findsOneWidget,
    );
    await tester.enterText(find.byType(TextField), 'zzz');
    await tester.tap(find.text('Ver ruta'));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.textContaining('No conocemos ese aeropuerto'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'lis');
    await tester.tap(find.text('Ver ruta'));
    await tester.pump(const Duration(milliseconds: 1500));
    expect(find.text('MAD → LIS'), findsOneWidget);
  });

  group('fichas de ciudad', () {
    final Map<String, Object?> madridJson = <String, Object?>{
      'iata': 'MAD',
      'language': 'es',
      'wikidata_id': 'Q2807',
      'city': 'Madrid',
      'summary': 'Madrid es la capital de España.',
      'summary_language': 'es',
      'article_url': 'https://es.wikipedia.org/wiki/Madrid',
      'photo': <String, Object?>{
        'url': 'https://upload.wikimedia.org/x/960px-Madrid.jpg',
        'page_url': 'https://commons.wikimedia.org/wiki/File:Madrid.jpg',
      },
      'population': 3280782,
      'country': <String, Object?>{
        'name': 'España',
        'capital': 'Madrid',
        'currency': 'euro',
        'languages': <String>['español'],
      },
      'attractions': <Object?>[
        <String, Object?>{
          'name': 'Museo del Prado',
          'description': 'museo de arte',
          'article_url': 'javascript:alert(1)', // se descarta
        },
        <String, Object?>{'name': ''}, // sin nombre: fuera
      ],
      'attribution': 'Wikipedia · Wikidata · Wikimedia Commons',
    };

    test('se lee y se valida lo que manda el servidor', () {
      final PlaceCard card = PlaceCard.parse(madridJson);
      expect(card.population, 3280782);
      expect(card.country!.languages, <String>['español']);
      expect(card.attractions.map((Attraction a) => a.name), <String>[
        'Museo del Prado',
      ]);
      expect(card.attractions.single.articleUrl, isNull);
      expect(card.photo!.pageUrl.host, 'commons.wikimedia.org');
      expect(
        () => PlaceCard.parse(<String, Object?>{'city': 'X'}),
        throwsA(isA<ApiException>()),
      );
    });

    test('es pública (invitados), se recuerda y 404 = sin ficha', () async {
      final FakeGateway gateway = FakeGateway()
        ..publicPrefixes.add('/v1/places/');
      int calls = 0;
      gateway.services['/v1/places/MAD'] = (_) {
        calls++;
        return FakeGateway.json(madridJson);
      };
      final ApiClient api = ApiClient(
        baseUrl: Uri.parse('http://gateway.test'),
        session: newSession(gateway)..continueAsGuest(),
        client: gateway.client,
      );
      final PlacesApi places = PlacesApi(api);
      expect((await places.get('mad', 'es'))!.city, 'Madrid');
      await places.get('MAD', 'es');
      expect(calls, 1);
      expect(await places.get('XXX', 'es'), isNull);
    });

    testWidgets('"Sobre Madrid" abre la ficha con lo más visitado', (
      WidgetTester tester,
    ) async {
      final List<Uri> opened = <Uri>[];
      final List<String> asked = <String>[];
      await pumpRoute(
        tester,
        places: (String iata, String lang) async {
          asked.add('$iata:$lang');
          return PlaceCard.parse(madridJson);
        },
        openLink: (Uri u) async {
          opened.add(u);
          return true;
        },
      );
      await tester.tap(find.text('Empezar en Madrid'));
      await tester.pump(const Duration(milliseconds: 1300));
      await tester.tap(find.text('Sobre Madrid'));
      // Un fotograma abre la hoja y pide la ficha; el siguiente la pinta.
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump(const Duration(milliseconds: 100));
      expect(asked, <String>['MAD:es']);
      expect(find.text('Por qué es famosa'), findsOneWidget);
      expect(find.text('Madrid es la capital de España.'), findsOneWidget);
      expect(find.text('3.280.782'), findsOneWidget);
      expect(find.text('euro'), findsOneWidget);
      expect(find.text('Lo más visitado'), findsOneWidget);
      expect(find.text('Museo del Prado'), findsOneWidget);
      await tester.tap(find.text('Leer más en Wikipedia'));
      expect(opened.single.toString(), 'https://es.wikipedia.org/wiki/Madrid');
      // Abajo del todo, de dónde salen textos y fotos (lo piden sus licencias).
      await tester.scrollUntilVisible(
        find.textContaining('Wikimedia Commons'),
        200,
        scrollable: find
            .descendant(
              of: find.byType(CitySheet),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      expect(find.textContaining('Wikimedia Commons'), findsOneWidget);
    });

    testWidgets('si no hay ficha, se dice sin romper nada', (
      WidgetTester tester,
    ) async {
      await pumpRoute(
        tester,
        places: (String iata, String lang) async =>
            throw const ApiException(ApiError.unavailable),
      );
      await tester.tap(find.text('Empezar en Madrid'));
      await tester.pump(const Duration(milliseconds: 1300));
      await tester.tap(find.text('Sobre Madrid'));
      // Un fotograma abre la hoja y pide la ficha; el siguiente la pinta.
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.textContaining('Aún no hay información'), findsOneWidget);
    });

    testWidgets('sin fichas configuradas no sale el botón', (
      WidgetTester tester,
    ) async {
      await pumpRoute(tester);
      await tester.tap(find.text('Empezar en Madrid'));
      await tester.pump(const Duration(milliseconds: 1300));
      expect(find.text('Sobre Madrid'), findsNothing);
    });
  });

  test('dirección de la pantalla', () {
    expect(
      Routes.flightRoute(from: 'MAD', to: 'NRT'),
      '/fares/map?from=MAD&to=NRT',
    );
    expect(Routes.flightRoute(from: 'MAD'), '/fares/map?from=MAD');
  });

  group('vuelo 3D', () {
    test('salen los monumentos cerca de la ruta, en orden', () {
      final List<String> mt = monumentsAlong(madrid, tokyo);
      expect(mt.first, 'alcala');
      expect(<String>['fuji', 'tokio'], contains(mt.last));
      expect(mt, containsAll(<String>['eiffel', 'brandeburgo'])); // por Europa
      expect(mt, isNot(contains('taj'))); // la India queda muy al sur
      expect(mt.length, lessThanOrEqualTo(8));
      // Madrid → Nueva York: solo la Puerta de Alcalá.
      expect(monumentsAlong(madrid, const LatLon(40.64, -73.78)), <String>[
        'alcala',
      ]);
      // Sídney → Santiago de Chile: ninguno (y la escena vuela igual).
      expect(
        monumentsAlong(
          const LatLon(-33.95, 151.18),
          const LatLon(-33.39, -70.79),
        ),
        isEmpty,
      );
    });

    test('los datos van dentro de la página sin poder romperla', () {
      final String html = flight3dHtml(
        '<script>/*NQ_CONFIG*/</script>',
        <String, Object?>{'x': '</script><b>'},
      );
      expect(html, contains('window.NQ_FLIGHT = {"x":"<\\/script><b>"};'));
      expect('</script>'.allMatches(html), hasLength(1));
    });

    test('la página empaquetada lleva three.js y el hueco de los datos', () {
      final String html = File('assets/flight3d/vuelo.html').readAsStringSync();
      expect(html, contains('/*NQ_CONFIG*/'));
      expect(html, isNot(contains('/*NQ_BUNDLE*/')));
      expect(html, isNot(contains('cdn.jsdelivr')));
      expect(html, isNot(contains('fonts.googleapis')));
    });

    testWidgets('"Despegar" abre el vuelo 3D y al terminar se ve la llegada', (
      WidgetTester tester,
    ) async {
      final CountryCodes countries = (await tester.runAsync(
        CountryCodes.load,
      ))!;
      expect(countries['Spain'], 'ES');
      expect(countries['Japan'], 'JP');
      Map<String, Object?>? config;
      void Function(String)? send;
      await pumpRoute(
        tester,
        scene3d: (String html, void Function(String) onMessage) {
          final String json = RegExp(r'window\.NQ_FLIGHT = (.*);')
              .firstMatch(html)!
              .group(1)!;
          config = jsonDecode(json) as Map<String, Object?>;
          send = onMessage;
          return const ColoredBox(color: Color(0xFF000000));
        },
      );
      await tester.tap(find.text('Empezar en Madrid'));
      await tester.pump(const Duration(milliseconds: 1300));
      await tester.tap(find.text('Despegar hacia Tokyo'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      // La plantilla y los países se leen de los assets (de verdad).
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 200)),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byType(Flight3dScreen), findsOneWidget);
      expect(config!['lang'], 'es');
      expect(config!['from'], <String, Object?>{
        'code': 'MAD',
        'city': 'Madrid',
        'cc': 'ES',
      });
      expect((config!['to']! as Map<String, Object?>)['cc'], 'JP');
      final Map<String, Object?> t = config!['t']! as Map<String, Object?>;
      expect(t['overflying'], 'Sobrevolando');
      expect(t['kmOf'], '{km} de {total} km');
      final Map<String, Object?> texts =
          config!['texts']! as Map<String, Object?>;
      expect(
        (texts['alcala']! as Map<String, Object?>)['name'],
        'Puerta de Alcalá',
      );

      // La página avisa de que el pasajero pulsó "Continuar".
      send!('done');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump(const Duration(milliseconds: 1300));
      expect(find.byType(Flight3dScreen), findsNothing);
      expect(find.text('¡Has llegado a Tokyo!'), findsOneWidget);
    });
  });
}
