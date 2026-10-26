// Qué pasa en tus fechas: festivos y eventos reales (con su fuente), días
// del viaje, filtro por día y guardados (solo en el móvil).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:nomadiq/core/router.dart';
import 'package:nomadiq/core/settings.dart';
import 'package:nomadiq/features/easy/easy_mode.dart';
import 'package:nomadiq/features/events/events_api.dart';

import 'helpers.dart';

String day(DateTime d) =>
    '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

void main() {
  final DateTime start = DateUtils.dateOnly(DateTime.now())
      .add(const Duration(days: 20));

  Map<String, Object?> json() => <String, Object?>{
    'iata': 'LIS',
    'city': 'Lisbon',
    'country': 'PT',
    'start': day(start),
    'end': day(start.add(const Duration(days: 4))),
    'sources': <String>['Nager.Date', 'Ticketmaster'],
    'events': <Object?>[
      <String, Object?>{
        'id': 'h-1',
        'kind': 'holiday',
        'name': 'Dia de Portugal',
        'date': day(start),
        'regional': false,
      },
      <String, Object?>{
        'id': 't-a',
        'kind': 'music',
        'name': 'Concierto en el estadio',
        'date': day(start.add(const Duration(days: 1))),
        'time': '21:00',
        'venue': 'Altice Arena',
        'url': 'https://www.ticketmaster.pt/event/a',
        'price_min': 45,
        'currency': 'EUR',
      },
      <String, Object?>{
        'id': 't-b',
        'kind': 'sports',
        'name': 'Benfica - Porto',
        'date': day(start.add(const Duration(days: 2))),
        'url': 'javascript:alert(1)',
      },
    ],
  };

  test('solo enlaces https y precios con moneda', () {
    final CityEvents e = CityEvents.parse(json());
    expect(e.events[1].priceMin, 45);
    expect(e.events[2].url, isNull);
    expect(e.events[2].priceMin, isNull);
  });

  testWidgets('festivo, concierto con precio del organizador y guardar', (
    WidgetTester tester,
  ) async {
    final FakeGateway g = FakeGateway()..publicPrefixes.add('/v1/events');
    final List<Uri> sent = <Uri>[];
    g.services['/v1/events'] = (http.Request r) {
      sent.add(r.url);
      return FakeGateway.json(json());
    };
    final MemorySettingsStore store = MemorySettingsStore('es');
    await saveEasyTrip(
      store,
      EasyTrip(
        departure: start.add(const Duration(hours: 9)),
        from: 'MAD',
        to: 'LIS',
      ),
    );
    final List<Uri> opened = <Uri>[];
    final session = newSession()..continueAsGuest();
    tester.view.physicalSize = const Size(1200, 4000);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await pumpApp(
      tester,
      locale: 'es',
      session: session,
      initialLocation: Routes.events(),
      services: fakeServices(
        session,
        gateway: g,
        prefs: store,
        openBooking: (Uri u) async {
          opened.add(u);
          return true;
        },
      ),
    );
    await tester.pumpAndSettle();

    // Tus fechas del Modo fácil: 5 días desde la salida.
    expect(sent.single.queryParameters, <String, String>{
      'iata': 'LIS',
      'from': day(start),
      'to': day(start.add(const Duration(days: 4))),
    });
    expect(find.text('Lisbon · LIS'), findsOneWidget);
    expect(
      find.textContaining('En tus fechas: 1 festivo y 2 eventos'),
      findsOneWidget,
    );
    expect(
      find.text('Festivo: algunas tiendas y museos pueden cerrar'),
      findsOneWidget,
    );
    expect(find.textContaining('(precio del organizador)'), findsOneWidget);
    expect(find.text('Fuentes: Nager.Date, Ticketmaster'), findsOneWidget);

    await tester.tap(find.text('Entradas'));
    expect(opened.single.host, 'www.ticketmaster.pt');

    // Solo el día del partido.
    await tester.tap(find.text('${start.add(const Duration(days: 2)).day}'));
    await tester.pumpAndSettle();
    expect(find.text('Benfica - Porto'), findsOneWidget);
    expect(find.text('Dia de Portugal'), findsNothing);

    await tester.tap(find.byTooltip('Guardar'));
    await tester.pumpAndSettle();
    expect(store.readData(LocalData.savedEvents), '["t-b"]');
    expect(find.text('Guardados (1)'), findsOneWidget);
  });
}
