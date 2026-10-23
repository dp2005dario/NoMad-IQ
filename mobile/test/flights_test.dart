// Tests de Vuelos: el cazador (chollos + mis alertas), vigilar una ruta con
// precio objetivo, el detalle con su gráfica y la lista de avisos. El
// servidor es falso (ver helpers.dart).
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:nomadiq/auth/session.dart';
import 'package:nomadiq/core/router.dart';
import 'package:nomadiq/core/settings.dart';
import 'package:nomadiq/features/flights/fares_api.dart';
import 'package:nomadiq/features/flights/flight_format.dart';
import 'package:nomadiq/features/flights/price_chart.dart';

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
    g.publicPrefixes.addAll(<String>['/v1/fares/deals', '/v1/fares/history/']);
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
  int limit = 50;
}

Future<FaresBackend> pumpFlights(
  WidgetTester tester, {
  String initialLocation = Routes.flights,
  List<Uri>? opened,
  MemorySettingsStore? prefs,
  bool guest = false,
}) async {
  // Pantalla alta: la lista entera cabe sin desplazarse.
  tester.view.physicalSize = const Size(1200, 6000);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  final FaresBackend b = FaresBackend();
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
    ),
  );
  return b;
}

void main() {
  testWidgets('el cazador: el mejor chollo arriba, reservar y mis alertas', (
    WidgetTester tester,
  ) async {
    final List<Uri> opened = <Uri>[];
    final FaresBackend b = await pumpFlights(tester, opened: opened);

    expect(find.text('Cazador de vuelos'), findsOneWidget);
    expect(b.origins, <String>['MAD']);
    // Tokio (−59 %, parece tarifa error) va primero aunque el servidor lo
    // mandara segundo.
    expect(find.text('¡VUELO CAZADO! · ERROR DE TARIFA'), findsOneWidget);
    expect(find.text('MAD → HND'), findsOneWidget);
    expect(find.textContaining('389'), findsWidgets);
    expect(find.textContaining('48 h'), findsOneWidget);
    // Lisboa, en la lista y en "Mis alertas" (con su objetivo).
    expect(find.text('MAD → LIS'), findsNWidgets(2));
    expect(find.textContaining('si baja de 300'), findsOneWidget);

    await tester.tap(find.text('Reservar ya'));
    await tester.pumpAndSettle();
    expect(opened.single.host, 'www.aviasales.com');
  });

  testWidgets('invitado: ve los chollos reales, pero vigilar pide cuenta', (
    WidgetTester tester,
  ) async {
    final FaresBackend b = await pumpFlights(tester, guest: true);
    expect(b.origins, <String>['MAD']);
    expect(find.text('¡VUELO CAZADO! · ERROR DE TARIFA'), findsOneWidget);
    expect(find.text('MAD → HND'), findsOneWidget);
    // "Mis alertas" invita a crear cuenta en lugar de fallar.
    expect(find.textContaining('crea una cuenta gratis'), findsOneWidget);
    expect(b.g.calls, isNot(contains('PUT /v1/fares/watches/${enc(tokyo)}')));

    await tester.tap(find.text('Avisar si baja'));
    await tester.pumpAndSettle();
    expect(find.text('Guardar alerta'), findsNothing);
    expect(b.watched.containsKey(tokyo), isFalse);
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

  testWidgets('avisar si baja: con precio objetivo', (
    WidgetTester tester,
  ) async {
    final FaresBackend b = await pumpFlights(tester);
    await tester.tap(find.text('Avisar si baja'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'abc');
    await tester.tap(find.text('Guardar alerta'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Escribe un precio'), findsOneWidget);

    await tester.enterText(find.byType(TextField), '299,99');
    await tester.tap(find.text('Guardar alerta'));
    await tester.pumpAndSettle();
    expect(b.watched[tokyo], 29999);
    expect(find.textContaining('Flyra te avisará'), findsOneWidget);
  });

  testWidgets('avisar si baja: al llegar al máximo se explica', (
    WidgetTester tester,
  ) async {
    final FaresBackend b = await pumpFlights(tester)
      ..limit = 1;
    await tester.tap(find.text('Avisar si baja'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Guardar alerta'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Ya vigilas 50 vuelos'), findsOneWidget);
    expect(b.watched.containsKey(tokyo), isFalse);
  });

  testWidgets('cambiar de aeropuerto recarga y se recuerda', (
    WidgetTester tester,
  ) async {
    final MemorySettingsStore prefs = MemorySettingsStore('es');
    final FaresBackend b = await pumpFlights(tester, prefs: prefs);
    await tester.tap(find.text('Desde MAD'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'B1');
    await tester.tap(find.text('Guardar'));
    await tester.pumpAndSettle();
    expect(find.textContaining('código de 3 letras'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'bcn');
    await tester.tap(find.text('Guardar'));
    await tester.pumpAndSettle();
    expect(b.origins.last, 'BCN');
    expect(prefs.flightOrigin, 'BCN');
    expect(find.text('Desde BCN'), findsOneWidget);
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

  testWidgets('Vuelos en árabe cabe en pantalla', (WidgetTester tester) async {
    final FaresBackend b = FaresBackend();
    final SessionController s = await signedInSession(b.g);
    await pumpApp(
      tester,
      locale: 'ar',
      session: s,
      initialLocation: Routes.flights,
      services: fakeServices(s, gateway: b.g),
    );
    expect(tester.takeException(), isNull);
    expect(find.text('صائد الرحلات'), findsOneWidget);
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
