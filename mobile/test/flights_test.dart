// Tests de Vuelos: el cazador (chollos + mis alertas), vigilar una ruta con
// precio objetivo, el detalle con su gráfica y la lista de avisos. El
// servidor es falso (ver helpers.dart).
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:eclipta/auth/session.dart';
import 'package:eclipta/core/router.dart';
import 'package:eclipta/core/settings.dart';
import 'package:eclipta/features/flights/fares_api.dart';
import 'package:eclipta/features/flights/flight_format.dart';
import 'package:eclipta/features/flights/flights_screen.dart';
import 'package:eclipta/features/flights/price_chart.dart';
import 'package:eclipta/features/flights/flights_page.dart';
import 'package:eclipta/features/route/web_scene.dart';

import 'helpers.dart';

const String tokyo = 'MAD-HND:2026-12-15:ECONOMY';
const String lisbon = 'MAD-LIS:2026-12-02:ECONOMY';

Map<String, Object?> fare(
  String key,
  int price, {
  String booking = 'https://www.aviasales.com/search/x?marker=1',
}) {
  final FareRoute r = FareRoute.fromKey(key)!;
  return <String, Object?>{
    'route_key': key,
    'origin': r.origin,
    'destination': r.destination,
    'departure_date': key.split(':')[1],
    'cabin': 'ECONOMY',
    'price': <String, Object?>{'amount_minor': price, 'currency': 'EUR'},
    'carrier': 'IB',
    'booking_url': booking,
    'observed_at': '2026-10-23T10:00:00Z',
  };
}

String enc(String key) => Uri.encodeComponent(key);

/// Un price-consumer falso: dos chollos desde MAD, una ruta vigilada, su
/// historial y un aviso. Apunta lo que la app le pide.
class FaresBackend {
  FaresBackend() {
    g.publicPrefixes.addAll(<String>[
      '/v1/fares/deals',
      '/v1/fares/history/',
      '/v1/fares/search',
    ]);
    g.services['/v1/fares/search'] = (http.Request r) {
      searches.add(r.url.queryParameters);
      if (searchBusy) return http.Response('{}', 429);
      final Map<String, String> q = r.url.queryParameters;
      final int adults = int.parse(q['adults']!);
      final String key = FareRoute.keyFor(
        q['origin']!,
        q['destination']!,
        DateTime.parse(q['departure']!),
        returnDate: q['return'] == null ? null : DateTime.parse(q['return']!),
      );
      final FareRoute route = FareRoute.fromKey(key)!;
      Map<String, Object?> offer(
        int price,
        int stops,
        String link,
      ) => <String, Object?>{
        'price_per_adult': <String, Object?>{
          'amount_minor': price,
          'currency': 'EUR',
        },
        'total': <String, Object?>{
          'amount_minor': price * adults,
          'currency': 'EUR',
        },
        'carrier': 'IB',
        'departure_at': '${q['departure']}T22:40:00+01:00',
        if (q['return'] != null) 'return_at': '${q['return']}T09:05:00+09:00',
        'transfers': stops,
        'return_transfers': stops,
        'duration_minutes': 1505,
        'booking_url': link,
      };
      return FakeGateway.json(<String, Object?>{
        'route': <String, Object?>{
          'route_key': key,
          'origin': route.origin,
          'destination': route.destination,
          'departure_date': q['departure'],
          'return_date': q['return'],
          'cabin': 'ECONOMY',
        },
        'adults': adults,
        'provider': 'travelpayouts',
        'observed_at': '2026-10-23T10:00:00Z',
        'offers': <Object?>[
          offer(31550, 0, 'https://www.aviasales.com/search/MAD1512NRT22122'),
          offer(42000, 1, 'https://www.aviasales.com/search/x'),
          offer(100, 0, 'javascript:alert(1)'), // nunca se enseña
        ],
      });
    };
    g.services['/v1/fares/deals'] = (http.Request r) {
      origins.add(r.url.queryParameters['origin']!);
      return FakeGateway.json(<String, Object?>{
        'origin': r.url.queryParameters['origin'],
        'deals': <Object?>[
          <String, Object?>{
            ...fare(lisbon, 3900),
            'usual_minor': 6000,
            'drop_bp': 3500,
          },
          <String, Object?>{
            ...fare(tokyo, 38900),
            'usual_minor': 95000,
            'drop_bp': 5900,
          },
        ],
      });
    };
    g.services['/v1/fares/watches'] = (_) => FakeGateway.json(<String, Object?>{
      'max': 50,
      'watches': <Object?>[
        for (final MapEntry<String, int?> w in watched.entries)
          <String, Object?>{
            ...fare(w.key, 0)..remove('price'),
            'target': w.value == null
                ? null
                : <String, Object?>{'amount_minor': w.value, 'currency': 'EUR'},
            'created_at': '2026-10-23T09:00:00Z',
            'latest': fare(w.key, 41200),
          },
      ],
    });
    for (final String key in <String>[tokyo, lisbon]) {
      g.services['/v1/fares/watches/${enc(key)}'] = (http.Request r) {
        if (r.method == 'DELETE') {
          watched.remove(key);
          return http.Response('', 204);
        }
        if (watched.length >= limit) return http.Response('{}', 409);
        final Map<String, Object?> body =
            jsonDecode(r.body) as Map<String, Object?>;
        final Map<String, Object?>? target =
            body['target'] as Map<String, Object?>?;
        watched[key] = target?['amount_minor'] as int?;
        return FakeGateway.json(<String, Object?>{}, 201);
      };
      g.services['/v1/fares/history/${enc(key)}'] = (_) =>
          FakeGateway.json(<String, Object?>{
            'currency': 'EUR',
            'points': <Object?>[
              <String, Object?>{'date': '2026-10-20', 'min_minor': 52000},
              <String, Object?>{'date': '2026-10-21', 'min_minor': 47000},
              <String, Object?>{'date': '2026-10-22', 'min_minor': 38900},
            ],
          });
    }
    g.services['/v1/fares/alerts'] = (_) => FakeGateway.json(<String, Object?>{
      'alerts': <Object?>[
        <String, Object?>{
          'alert_id': '5a4b3c2d-1e0f-4a9b-8c7d-6e5f4a3b2c1d',
          'type': 'ERROR_FARE',
          ...fare(tokyo, 0)..remove('price'),
          'reference': <String, Object?>{
            'amount_minor': 95000,
            'currency': 'EUR',
          },
          'current': <String, Object?>{
            'amount_minor': 38900,
            'currency': 'EUR',
          },
          'drop_bp': 5900,
        },
      ],
    });
  }

  final FakeGateway g = FakeGateway();
  final List<String> origins = <String>[];
  final Map<String, int?> watched = <String, int?>{lisbon: 30000};
  final List<Map<String, String>> searches = <Map<String, String>>[];
  bool searchBusy = false;
  int limit = 50;
}

/// La página de Vuelos sin WebView: apunta cada página y deja mandarle
/// avisos como si se tocara un botón.
class PageSpy {
  final List<String> pages = <String>[];
  void Function(String message)? send;

  Widget build(String html, void Function(String message) onMessage) {
    pages.add(html);
    send = onMessage;
    return const SizedBox.expand();
  }

  /// Espera (dejando correr las llamadas de verdad) hasta que [done].
  Future<void> wait(WidgetTester tester, bool Function() done) async {
    for (int i = 0; i < 100 && !done(); i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(done(), isTrue);
  }
}

/// Lo que la app le puso a la página (window.ECL).
Map<String, Object?> flightsData(String html) {
  final int a = html.indexOf('window.ECL=') + 'window.ECL='.length;
  final int b = html.indexOf(';</script>', a);
  return jsonDecode(html.substring(a, b)) as Map<String, Object?>;
}

/// Como pack() de la página: JSON en base64url sin "=".
String pack(Object? v) =>
    base64Url.encode(utf8.encode(jsonEncode(v))).replaceAll('=', '');

Future<FaresBackend> pumpFlights(
  WidgetTester tester, {
  String initialLocation = Routes.flights,
  List<Uri>? opened,
  MemorySettingsStore? prefs,
  bool guest = false,
  FaresBackend? backend,
  PageSpy? page,
  List<Uri>? links,
}) async {
  // Pantalla alta: la lista entera cabe sin desplazarse.
  tester.view.physicalSize = const Size(1200, 6000);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  final FaresBackend b = backend ?? FaresBackend();
  final SessionController s = guest
      ? (newSession(b.g)..continueAsGuest())
      : await signedInSession(b.g);
  await pumpApp(
    tester,
    locale: 'es',
    session: s,
    initialLocation: initialLocation,
    services: fakeServices(
      s,
      gateway: b.g,
      prefs: prefs,
      openBooking: (Uri url) async {
        opened?.add(url);
        return true;
      },
      openLink: (Uri url) async {
        links?.add(url);
        return true;
      },
      // Sin WebView en los tests: se apunta la página y sus avisos.
      webScene: (page ?? PageSpy()).build,
    ),
  );
  return b;
}

void main() {
  testWidgets('la página: tu mejor chollo arriba, su ruta y tus alertas', (
    WidgetTester tester,
  ) async {
    final PageSpy page = PageSpy();
    final FaresBackend b = await pumpFlights(tester, page: page);
    await page.wait(tester, () => page.pages.isNotEmpty);
    expect(b.origins, <String>['MAD']);
    final Map<String, Object?> e = flightsData(page.pages.last);
    final List<Object?> deals = e['deals']! as List<Object?>;
    // Tokio (−59 %, parece tarifa error) va primero aunque el servidor lo
    // mandara segundo.
    final Map<String, Object?> top = deals.first! as Map<String, Object?>;
    expect(top['d'], 'HND');
    expect(top['kind'], '¡VUELO CAZADO! · ERROR DE TARIFA');
    expect(top['pm'], 38900);
    expect(top['usualMinor'], 95000);
    expect(top['trip'], 'Solo ida');
    // La ruta de verdad: Madrid → Tokio, con sus monumentos y los países.
    final Map<String, Object?> route = top['route']! as Map<String, Object?>;
    expect((route['o']! as Map<String, Object?>)['iata'], 'MAD');
    expect((route['d']! as Map<String, Object?>)['cc'], 'JP');
    expect(route['km'], inInclusiveRange(10500, 11000));
    final Map<String, Object?> mons = route['mons']! as Map<String, Object?>;
    expect(mons.keys, containsAll(<String>['palacio', 'alcala', 'ttower']));
    final List<Object?> regions = route['regions']! as List<Object?>;
    expect((regions.first! as List<Object?>).last, '^');
    expect((regions.last! as List<Object?>).last, r'$');
    // Lisboa vigilada con objetivo 300 € y ahora a 412 €: aún lejos.
    final List<Object?> alerts = e['alerts']! as List<Object?>;
    final Map<String, Object?> a = alerts.single! as Map<String, Object?>;
    expect(a['route'], 'MAD → LIS');
    expect(a['target'], contains('300'));
    expect(a['price'], contains('412'));
    expect(a['hit'], isFalse);
    expect(e['guest'], isFalse);
    expect(e['fly'], isFalse);
    // Sin datos de ejemplo ni notas para DARIO.
    expect(page.pages.last, isNot(contains('Datos de ejemplo')));
    expect(page.pages.last, isNot(contains('PROBAR AVISO')));
    expect(page.pages.last, isNot(contains('Inicio.dc.html')));
  });

  testWidgets('reservar el día elegido y abrir tus alertas', (
    WidgetTester tester,
  ) async {
    final List<Uri> opened = <Uri>[];
    final PageSpy page = PageSpy();
    await pumpFlights(tester, page: page, opened: opened);
    await page.wait(tester, () => page.pages.isNotEmpty);
    page.send!('book:0:15');
    await tester.pumpAndSettle();
    expect(opened.single.host, 'www.aviasales.com');
    page.send!('alert:0');
    await tester.pumpAndSettle();
    expect(find.text('El precio en los últimos días'), findsOneWidget);
  });

  testWidgets('calendario y fichas: la página los pide sin recargarse', (
    WidgetTester tester,
  ) async {
    final List<Uri> links = <Uri>[];
    final PageSpy page = PageSpy();
    final FaresBackend b = FaresBackend();
    b.g.publicPrefixes.addAll(<String>['/v1/fares/days', '/v1/places/']);
    b.g.services['/v1/fares/days'] = (http.Request r) {
      expect(r.url.queryParameters['month'], '2026-12');
      expect(r.url.queryParameters['one_way'], 'true');
      return FakeGateway.json(<String, Object?>{
        'days': <Object?>[
          <String, Object?>{
            'date': '2026-12-14',
            'price_per_adult': <String, Object?>{
              'amount_minor': 41000,
              'currency': 'EUR',
            },
            'booking_url': 'https://www.aviasales.com/search/day14',
          },
          <String, Object?>{'date': 'mal'}, // se salta
        ],
      });
    };
    b.g.services['/v1/places/HND'] = (_) => FakeGateway.json(<String, Object?>{
      'iata': 'HND',
      'city': 'Tokio',
      'language': 'es',
      'attribution': 'Wikipedia',
      'summary': 'Capital de Japón.',
      'country': <String, Object?>{
        'name': 'Japón',
        'capital': 'Tokio',
        'currency': 'Yen (JPY)',
        'languages': <String>['Japonés'],
      },
      'attractions': <Object?>[
        <String, Object?>{
          'name': 'Templo Sensō-ji',
          'description': 'El templo más antiguo de Tokio.',
          'photo': <String, Object?>{
            'url': 'https://upload.wikimedia.org/senso.jpg',
            'page_url': 'https://commons.wikimedia.org/wiki/File:Senso.jpg',
          },
        },
      ],
    });
    final List<Uri> opened = <Uri>[];
    await pumpFlights(
      tester,
      page: page,
      backend: b,
      opened: opened,
      links: links,
    );
    await page.wait(tester, () => page.pages.isNotEmpty);
    page.send!(
      'cal:0:${pack(<String, Object?>{'k': 'MAD-HND-ow-2026-12', 'o': 'MAD', 'd': 'HND', 'ow': true, 'y': 2026, 'm': 12})}',
    );
    final WebSceneBridge bridge = FlightsScreen.lastBridge!;
    await page.wait(tester, () => bridge.sent.isNotEmpty);
    expect(bridge.sent.last, contains('"k":"MAD-HND-ow-2026-12"'));
    expect(bridge.sent.last, contains('"14":41000'));
    // "Reservar ya" el día 14: el enlace de ese día.
    page.send!('book:0:14');
    await tester.pumpAndSettle();
    expect(opened.single.path, '/search/day14');

    page.send!('ficha:1');
    await page.wait(tester, () => bridge.sent.length == 2);
    expect(bridge.sent.last, contains('"side":"d"'));
    expect(bridge.sent.last, contains('Templo Sensō-ji'));
    expect(bridge.sent.last, contains('"culture":null'));
    expect(bridge.sent.last, isNot(contains('<')));
    page.send!('photo:1:0');
    await tester.pumpAndSettle();
    expect(links.single.host, 'commons.wikimedia.org');
  });

  testWidgets('Buscar vuelos: el buscador de la app con todo puesto', (
    WidgetTester tester,
  ) async {
    final PageSpy page = PageSpy();
    final FaresBackend b = await pumpFlights(tester, page: page);
    await page.wait(tester, () => page.pages.isNotEmpty);
    final String dep = isoDay(DateTime.now().add(const Duration(days: 40)));
    final String ret = isoDay(DateTime.now().add(const Duration(days: 47)));
    page.send!(
      'go:0:${pack(<String, Object?>{'o': 'MAD', 'd': 'NRT', 'dep': dep, 'ret': ret, 'ad': 1, 'ki': 1})}',
    );
    await tester.pumpAndSettle();
    final Map<String, String> q = b.searches.single;
    expect(q['origin'], 'MAD');
    expect(q['destination'], 'NRT');
    expect(q['departure'], dep);
    expect(q['return'], ret);
    // Los niños cuentan como viajeros.
    expect(q['adults'], '2');
    expect(find.text('2 vuelos'), findsOneWidget);
  });

  testWidgets('invitado: ve los chollos reales, pero vigilar pide cuenta', (
    WidgetTester tester,
  ) async {
    final PageSpy page = PageSpy();
    final FaresBackend b = await pumpFlights(tester, guest: true, page: page);
    await page.wait(tester, () => page.pages.isNotEmpty);
    final Map<String, Object?> e = flightsData(page.pages.last);
    expect(e['guest'], isTrue);
    expect((e['deals']! as List<Object?>).length, 2);
    expect(e['alertsNote'], contains('Entra con tu cuenta'));
    page.send!('watch:0');
    await tester.pumpAndSettle();
    expect(find.text('Guardar alerta'), findsNothing);
    expect(b.watched.containsKey(tokyo), isFalse);
  });

  testWidgets('si no llegan los precios, avisa Flyra y se reintenta', (
    WidgetTester tester,
  ) async {
    final PageSpy page = PageSpy();
    final FaresBackend b = FaresBackend();
    b.g.services['/v1/fares/deals'] = (http.Request r) {
      b.origins.add(r.url.queryParameters['origin']!);
      return http.Response('{}', 503);
    };
    await pumpFlights(tester, page: page, backend: b);
    await page.wait(tester, () => page.pages.isNotEmpty);
    final Map<String, Object?> e = flightsData(page.pages.last);
    expect(e['fly'], isTrue);
    expect(e['deals'], isEmpty);
    page.send!('retry');
    await page.wait(tester, () => b.origins.length == 2);
  });

  testWidgets('avisar si baja: con precio objetivo', (
    WidgetTester tester,
  ) async {
    final PageSpy page = PageSpy();
    final FaresBackend b = await pumpFlights(tester, page: page);
    await page.wait(tester, () => page.pages.isNotEmpty);
    page.send!('watch:0');
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'abc');
    await tester.tap(find.text('Guardar alerta'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Escribe un precio'), findsOneWidget);

    await tester.enterText(find.byType(TextField), '299,99');
    await tester.tap(find.text('Guardar alerta'));
    await tester.pumpAndSettle();
    expect(b.watched[tokyo], 29999);
  });

  testWidgets('avisar si baja: al llegar al máximo se explica', (
    WidgetTester tester,
  ) async {
    final PageSpy page = PageSpy();
    final FaresBackend b = await pumpFlights(tester, page: page)
      ..limit = 1;
    await page.wait(tester, () => page.pages.isNotEmpty);
    page.send!('watch:0');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Guardar alerta'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Ya vigilas 50 vuelos'), findsOneWidget);
    expect(b.watched.containsKey(tokyo), isFalse);
  });

  test('la página: avisos, horas y alertas', () {
    expect(webSceneMessage.hasMatch('go:0:eyJvIjoiTUFEIn0'), isTrue);
    expect(webSceneMessage.hasMatch('cal:0:eyJrIjoiYSJ9'), isTrue);
    expect(webSceneMessage.hasMatch('go:0:<script>'), isFalse);
    expect(unpackJson(pack(<String, Object?>{'o': 'MAD'})), <String, Object?>{
      'o': 'MAD',
    });
    expect(unpackJson('%%%'), isNull);
    final DateTime now = DateTime.utc(2026, 10, 23, 12);
    expect(
      agoText(now.subtract(const Duration(minutes: 14)), now),
      'Hace 14 min',
    );
    expect(agoText(now.subtract(const Duration(hours: 3)), now), 'Hace 3 h');
    final Watch hit = Watch.parse(<String, Object?>{
      ...fare(lisbon, 0)..remove('price'),
      'target': <String, Object?>{'amount_minor': 6000, 'currency': 'EUR'},
      'latest': fare(lisbon, 5400),
    });
    final Map<String, Object?> a = alertJson(
      hit,
      (Money m) => '${m.amountMinor ~/ 100} €',
    );
    expect(a['hit'], isTrue);
    expect(a['pct'], 100);
    expect(a['price'], '54 €');
    expect(
      flightsPageWith('x /*ECLIPTA*/{} y', <String, Object?>{'a': '</script>'}),
      allOf(contains(r'\u003c/script>'), isNot(contains('</script>'))),
    );
  });

  testWidgets('invitado: el detalle enseña la gráfica', (
    WidgetTester tester,
  ) async {
    await pumpFlights(
      tester,
      guest: true,
      initialLocation: Routes.fareRoute(tokyo),
    );
    expect(find.byType(PriceChart), findsOneWidget);
    expect(find.textContaining('crea una cuenta gratis'), findsOneWidget);
  });

  group('buscador', () {
    final DateTime dep = DateTime.now().add(const Duration(days: 40));
    final DateTime ret = dep.add(const Duration(days: 7));
    final String searchUrl = Routes.fareSearch(
      origin: 'MAD',
      destination: 'NRT',
      departure: isoDay(dep),
      returnDate: isoDay(ret),
    );

    testWidgets('invitado: busca ida y vuelta para 2 y reserva', (
      WidgetTester tester,
    ) async {
      final List<Uri> opened = <Uri>[];
      final FaresBackend b = await pumpFlights(
        tester,
        guest: true,
        opened: opened,
        initialLocation: searchUrl,
      );
      await tester.tap(find.byTooltip('Añadir viajero'));
      await tester.pump();
      expect(find.text('2 adultos'), findsOneWidget);
      await tester.tap(find.text('Buscar'));
      await tester.pumpAndSettle();

      final Map<String, String> q = b.searches.single;
      expect(q['origin'], 'MAD');
      expect(q['destination'], 'NRT');
      expect(q['departure'], isoDay(dep));
      expect(q['return'], isoDay(ret));
      expect(q['adults'], '2');
      // Dos ofertas (la del enlace "javascript:" no sale), la barata primero.
      expect(find.text('2 vuelos'), findsOneWidget);
      expect(find.textContaining('por persona'), findsNWidgets(2));
      expect(find.textContaining('Total para 2 adultos'), findsNWidgets(2));
      expect(find.textContaining('22:40 · Directo'), findsOneWidget);
      expect(find.textContaining('1 escala'), findsWidgets);
      expect(find.text('Duración: 25 h 5 min'), findsNWidgets(2));

      await tester.tap(find.text('Reservar ya').first);
      await tester.pumpAndSettle();
      expect(opened.single.host, 'www.aviasales.com');

      // Vigilar pide cuenta al invitado.
      await tester.tap(find.text('Avisar si baja').first);
      await tester.pumpAndSettle();
      expect(find.text('Guardar alerta'), findsNothing);
    });

    testWidgets('solo ida, datos que faltan y mucha gente buscando', (
      WidgetTester tester,
    ) async {
      final FaresBackend b = await pumpFlights(
        tester,
        initialLocation: Routes.fareSearch(origin: 'MAD'),
      );
      await tester.tap(find.text('Buscar'));
      await tester.pumpAndSettle();
      expect(find.textContaining('código de 3 letras'), findsOneWidget);

      await tester.enterText(find.byType(TextField).last, 'mad');
      await tester.tap(find.text('Buscar'));
      await tester.pumpAndSettle();
      expect(find.textContaining('no pueden ser el mismo'), findsOneWidget);

      await tester.enterText(find.byType(TextField).last, 'lis');
      await tester.tap(find.text('Solo ida'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Buscar'));
      await tester.pumpAndSettle();
      expect(find.text('Elige las fechas del viaje.'), findsOneWidget);
      expect(b.searches, isEmpty);
    });

    testWidgets('si el servidor pide frenar, se explica', (
      WidgetTester tester,
    ) async {
      final FaresBackend b = FaresBackend()..searchBusy = true;
      await pumpFlights(tester, backend: b, initialLocation: searchUrl);
      await tester.tap(find.text('Buscar'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Mucha gente buscando'), findsOneWidget);
    });
  });

  testWidgets('detalle: gráfica, mínimo y dejar de vigilar', (
    WidgetTester tester,
  ) async {
    final FaresBackend b = await pumpFlights(
      tester,
      initialLocation: Routes.fareRoute(lisbon),
    );
    expect(find.text('MAD → LIS'), findsOneWidget);
    expect(find.byType(PriceChart), findsOneWidget);
    expect(find.textContaining('Mínimo: 389'), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp('3 días')), findsOneWidget);

    await tester.tap(find.text('Dejar de vigilar'));
    await tester.pumpAndSettle();
    expect(b.watched.containsKey(lisbon), isFalse);
    expect(find.text('Avisar si baja'), findsOneWidget);
  });

  testWidgets('alertas: lista y tocar abre la ruta', (
    WidgetTester tester,
  ) async {
    await pumpFlights(tester, initialLocation: Routes.fareAlerts);
    expect(find.text('Posible tarifa error'), findsOneWidget);
    expect(find.textContaining('→ 389'), findsOneWidget);
    await tester.tap(find.text('Posible tarifa error'));
    await tester.pumpAndSettle();
    expect(find.text('El precio en los últimos días'), findsOneWidget);
    expect(find.text('Reservar ya'), findsOneWidget);
  });

  test('importes y claves de ruta', () {
    expect(parseAmount('299,99', 'EUR', 'es'), 29999);
    expect(parseAmount('300', 'JPY', 'ja'), 300);
    expect(parseAmount('-5', 'EUR', 'es'), isNull);
    expect(
      FareRoute.fromKey('MAD-NRT:2026-12-15:2026-12-22:BUSINESS')?.cabin,
      'BUSINESS',
    );
    expect(FareRoute.fromKey('../signin'), isNull);
    expect(
      FareRoute.keyFor('MAD', 'NRT', DateTime(2026, 12, 5)),
      'MAD-NRT:2026-12-05:ECONOMY',
    );
    expect(safeBookingUrl('http://evil.example'), isNull);
    expect(safeBookingUrl('javascript:alert(1)'), isNull);
  });
}
