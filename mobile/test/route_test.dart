// Tests de la Ruta del vuelo: las matemáticas de la esfera, los datos que
// van dentro de la app (mapa y aeropuertos) y la pantalla completa: mundo →
// origen → vuelo → llegada.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:eclipta/core/api_client.dart';
import 'package:eclipta/core/router.dart';
import 'package:eclipta/core/theme.dart';
import 'package:eclipta/features/route/flight3d.dart';
import 'package:eclipta/features/route/flight_route_screen.dart';
import 'package:eclipta/features/flights/airport_names.dart';
import 'package:eclipta/features/flights/booking.dart';
import 'package:eclipta/features/route/geo.dart';
import 'package:eclipta/features/route/places_api.dart';
import 'package:eclipta/features/route/world_data.dart';
import 'package:eclipta/features/visa/visa_data.dart' show CountryNames;
import 'package:eclipta/l10n/generated/app_localizations.dart';

import 'helpers.dart';
import 'money_test.dart' as m;

const LatLon madrid = LatLon(40.472, -3.563);
const LatLon tokyo = LatLon(35.765, 140.386);
const LatLon losAngeles = LatLon(33.942, -118.408);

/// Abre la Ruta con la página de verdad (sin WebView: [spy] la recoge).
Future<m.PageSpy> pumpRoute(
  WidgetTester tester, {
  String from = 'MAD',
  String? to = 'NRT',
  PlaceLoader? places,
  OpenBooking? openLink,
}) async {
  tester.view.physicalSize = const Size(1170, 2532);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  final m.PageSpy spy = m.PageSpy();
  // Los países se cargan una vez para toda la app: aquí, fuera del reloj de
  // mentira (si no, la carga se quedaría colgada en la prueba siguiente).
  await tester.runAsync(() async {
    await CountryCodes.load();
    await CountryNames.load();
    // Los nombres de persona de los aeropuertos ("Tokio").
    await AirportNames.load();
  });
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
        scene3d: spy.build,
      ),
    ),
  );
  await spy.wait(tester, () => spy.pages.isNotEmpty);
  return spy;
}

/// Lo que sabe la página de la Ruta ahora.
Map<String, Object?> routeData(m.PageSpy spy) =>
    spy.data(FlightRouteScreen.lastBridge!, title: 'ECLIPTA · Ruta del vuelo');

Map<String, Object?> place(m.PageSpy spy, String key) =>
    routeData(spy)[key]! as Map<String, Object?>;

String fact(m.PageSpy spy, String key, String name) =>
    ((place(spy, key)['facts']! as List<Object?>).firstWhere(
              (Object? f) => (f! as Map<String, Object?>)['k'] == name,
            )!
            as Map<String, Object?>)['v']!
        as String;

List<String> regions(m.PageSpy spy) => <String>[
  for (final Object? r in routeData(spy)['regions']! as List<Object?>)
    (r! as Map<String, Object?>)['label']! as String,
];

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

  testWidgets('la ruta de verdad: camino, por dónde pasa y la hora', (
    WidgetTester tester,
  ) async {
    final m.PageSpy spy = await pumpRoute(tester);
    expect(spy.pages.first, contains('ECLIPTA · Ruta del vuelo'));
    await spy.wait(tester, () => routeData(spy)['title'] == 'Madrid → Tokio');
    final Map<String, Object?> d = routeData(spy);
    // La ciudad como la dice la gente (no "Tokyo") y el nombre del
    // aeropuerto con su bandera, no el código.
    expect(d['title'], 'Madrid → Tokio');
    final Map<String, Object?> dest = d['d']! as Map<String, Object?>;
    expect(dest['lbl'], 'Aeropuerto de Tokio');
    expect(dest['flag'], '🇯🇵');
    final Map<String, Object?> pass = d['pass']! as Map<String, Object?>;
    expect((pass['o']! as Map<String, Object?>)['country'], 'España');
    expect(pass['diff'], startsWith('Tokio: '));
    expect(d['sub'], contains('10.7')); // km con punto español
    expect(d['startTxt'], 'Empezar en Madrid');
    // El mapa de la maqueta: x = longitud + 180, y = 90 − latitud.
    expect((d['o']! as Map<String, Object?>)['x'], closeTo(176.4, 0.1));
    expect((d['path']! as List<Object?>).length, 48);
    expect((d['mins']! as int) ~/ 60, 13);

    await spy.wait(tester, () => regions(spy).contains('Sobrevolando Rusia'));
    expect(regions(spy).first, 'Despegando de Madrid');
    expect(regions(spy).last, 'Llegando a Tokyo');
    // El camino más corto pasa por Rusia (nombres en español).
    expect(regions(spy), contains('Sobrevolando Rusia'));

    expect(fact(spy, 'op', 'Hora'), matches(RegExp(r'^\d{1,2}:\d\d$')));
    // Tokio va 7 u 8 horas por delante de Madrid (según el horario de verano).
    expect(fact(spy, 'dp', 'Hora'), matches(RegExp(r'[78] h más que Madrid')));
    expect(place(spy, 'op')['flag'], '🇪🇸');
    expect(place(spy, 'dp')['sub'], 'Japón · has llegado');
    // Sin fichas configuradas: lo dice, sin inventar.
    expect(place(spy, 'op')['why'], contains('Aún no hay información'));
    expect(fact(spy, 'op', 'Capital'), 'Sin datos');
  });

  testWidgets('sobre el océano: "Sobrevolando el mar"', (
    WidgetTester tester,
  ) async {
    final m.PageSpy spy = await pumpRoute(tester, from: 'JFK', to: 'LHR');
    await spy.wait(tester, () => regions(spy).length > 2);
    expect(regions(spy), contains('Sobrevolando el mar'));
    expect(fact(spy, 'dp', 'Hora'), contains('h más que New York'));
  });

  testWidgets('sin destino: se pregunta por NOMBRE (no por código)', (
    WidgetTester tester,
  ) async {
    final m.PageSpy spy = await pumpRoute(tester, to: null);
    await tester.pumpAndSettle();
    expect(find.text('¿A dónde vuelas?'), findsOneWidget);
    expect(routeData(spy)['d'], isNull);
    // Como en el buscador de vuelos: "aeropuerto de malaga" es Málaga.
    await tester.enterText(find.byType(TextField), 'aeropuerto de malaga');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Málaga').first);
    await tester.pump(const Duration(milliseconds: 1500));
    expect(routeData(spy)['title'], 'Madrid → Málaga');
    // El camino de verdad para el mapa: [longitud, latitud].
    final List<Object?> rt = routeData(spy)['route']! as List<Object?>;
    expect((rt.first! as List<Object?>)[1], closeTo(40.47, 0.01));

    // "Cambiar destino" en la página vuelve a abrir la hoja.
    spy.to('ECLIPTA · Ruta del vuelo')('pick');
    await tester.pumpAndSettle();
    expect(find.text('¿A dónde vuelas?'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'lisboa');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Lisboa').first);
    await tester.pump(const Duration(milliseconds: 1500));
    expect(routeData(spy)['title'], 'Madrid → Lisboa');

    // "Cambiar origen" también, por nombre.
    spy.to('ECLIPTA · Ruta del vuelo')('pickO');
    await tester.pumpAndSettle();
    expect(find.text('¿Desde dónde vuelas?'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'malaga airport');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Málaga').first);
    await tester.pump(const Duration(milliseconds: 1500));
    expect(routeData(spy)['title'], 'Málaga → Lisboa');
  });

  test('la página lleva el mapa de verdad dentro (sin pedirlo a Internet)', () {
    final String lib = File('assets/route/maplibre-gl.js').readAsStringSync();
    // Si la librería llevara "</script", rompería la página.
    expect(lib, isNot(contains('</script')));
    final String page = File('assets/route/ruta.html').readAsStringSync();
    expect(page, contains('/*MAPLIBRE*/'));
    expect(page, contains('/*ROUTEMAP*/{}'));
    expect(page, isNot(contains('unpkg.com')));
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

    testWidgets(
      'la ficha de Madrid: datos, por qué es famosa y lo más visitado',
      (WidgetTester tester) async {
        final List<Uri> opened = <Uri>[];
        final List<String> asked = <String>[];
        final m.PageSpy spy = await pumpRoute(
          tester,
          places: (String iata, String lang) async {
            asked.add('$iata:$lang');
            return iata == 'MAD' ? PlaceCard.parse(madridJson) : null;
          },
          openLink: (Uri u) async {
            opened.add(u);
            return true;
          },
        );
        await spy.wait(
          tester,
          () => place(spy, 'op')['why'] == 'Madrid es la capital de España.',
        );
        expect(asked, <String>['MAD:es', 'NRT:es']);
        expect(fact(spy, 'op', 'Capital'), 'Madrid');
        expect(fact(spy, 'op', 'Moneda'), 'euro');
        expect(fact(spy, 'op', 'Idioma'), 'español');
        expect(place(spy, 'op')['sights'], <Object?>[
          <String, Object?>{'name': 'Museo del Prado', 'img': ''},
        ]);
        // Tokio no tiene ficha: lo dice tal cual.
        expect(place(spy, 'dp')['why'], contains('Aún no hay información'));
        // De dónde salen textos y fotos (lo piden sus licencias).
        expect(routeData(spy)['credits'], contains('Wikimedia Commons'));

        spy.to('ECLIPTA · Ruta del vuelo')('more:o');
        expect(
          opened.single.toString(),
          'https://es.wikipedia.org/wiki/Madrid',
        );
      },
    );

    testWidgets('si la ficha falla, se dice sin romper nada', (
      WidgetTester tester,
    ) async {
      final m.PageSpy spy = await pumpRoute(
        tester,
        places: (String iata, String lang) async =>
            throw const ApiException(ApiError.unavailable),
      );
      await spy.wait(
        tester,
        () => '${place(spy, 'op')['why']}'.contains('Aún no hay información'),
      );
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

    testWidgets('"Ver el vuelo en 3D" y al terminar se ve la llegada', (
      WidgetTester tester,
    ) async {
      final CountryCodes countries = (await tester.runAsync(
        CountryCodes.load,
      ))!;
      expect(countries['Spain'], 'ES');
      expect(countries['Japan'], 'JP');
      final m.PageSpy spy = await pumpRoute(tester);
      expect(routeData(spy)['has3d'], isTrue);
      spy.to('ECLIPTA · Ruta del vuelo')('fly3d');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      // La plantilla y los países se leen de los assets (de verdad).
      await spy.wait(
        tester,
        () => spy.pages.any((String h) => h.contains('window.NQ_FLIGHT = ')),
      );
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byType(Flight3dScreen), findsOneWidget);
      final String html = spy.pages.lastWhere(
        (String h) => h.contains('window.NQ_FLIGHT = '),
      );
      final Map<String, Object?> config = jsonDecode(
        RegExp(r'window\.NQ_FLIGHT = (.*);').firstMatch(html)!.group(1)!,
      ) as Map<String, Object?>;
      expect(config['lang'], 'es');
      expect(config['from'], <String, Object?>{
        'code': 'MAD',
        'city': 'Madrid',
        'cc': 'ES',
      });
      expect((config['to']! as Map<String, Object?>)['cc'], 'JP');
      final Map<String, Object?> t = config['t']! as Map<String, Object?>;
      expect(t['overflying'], 'Sobrevolando');
      expect(t['kmOf'], '{km} de {total} km');
      final Map<String, Object?> texts =
          config['texts']! as Map<String, Object?>;
      expect(
        (texts['alcala']! as Map<String, Object?>)['name'],
        'Puerta de Alcalá',
      );

      // La página avisa de que el pasajero pulsó "Continuar".
      spy.to('window.NQ_FLIGHT = ')('done');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump(const Duration(milliseconds: 1300));
      expect(find.byType(Flight3dScreen), findsNothing);
      // La página de la Ruta salta al destino.
      expect(routeData(spy)['arrive'], 1);
    });
  });
}
