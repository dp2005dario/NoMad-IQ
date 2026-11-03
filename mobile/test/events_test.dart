// Qué pasa en tus fechas: festivos y eventos reales (con su fuente), días
// del viaje, filtro por día y guardados (solo en el móvil).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:eclipta/core/router.dart';
import 'package:eclipta/core/settings.dart';
import 'package:eclipta/features/easy/easy_mode.dart';
import 'package:eclipta/features/events/event_reminders.dart';
import 'package:eclipta/features/events/events_api.dart';
import 'package:eclipta/features/map/geo.dart';

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
    final MemoryEventReminders reminders = MemoryEventReminders();
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
        eventReminders: reminders,
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
    expect(find.text('Lisbon'), findsOneWidget);
    // 1 festivo + 2 eventos = 3 cosas en tus fechas.
    expect(find.text('3'), findsOneWidget);
    expect(find.text('cosas pasan en tus fechas'), findsOneWidget);
    expect(find.text('TICKETMASTER'), findsOneWidget);
    expect(
      find.text('Festivo: algunas tiendas y museos pueden cerrar'),
      findsOneWidget,
    );
    expect(find.textContaining('(precio del organizador)'), findsOneWidget);
    expect(find.text('Fuentes: Nager.Date, Ticketmaster'), findsOneWidget);

    await tester.tap(find.text('Entradas'));
    expect(opened.single.host, 'www.ticketmaster.pt');

    // Solo el día del partido.
    // El primero es el botón del día (arriba); el otro, la fecha de la tarjeta.
    await tester.tap(
      find.text('${start.add(const Duration(days: 2)).day}').first,
    );
    await tester.pumpAndSettle();
    expect(find.text('Benfica - Porto'), findsOneWidget);
    expect(find.text('Dia de Portugal'), findsNothing);

    await tester.tap(find.byTooltip('Guardar'));
    await tester.pumpAndSettle();
    expect(store.readData(LocalData.savedEvents), '["t-b"]');
    // El partido no tiene hora: solo el aviso de la víspera.
    expect(reminders.scheduled['t-b'], hasLength(1));
    expect(
      find.text('Guardado. Flyra te avisa la víspera y 2 horas antes.'),
      findsOneWidget,
    );
  });

  testWidgets('mapa de verdad con los puntos y lo lejos que está tu hotel', (
    WidgetTester tester,
  ) async {
    final Map<String, Object?> data = json();
    final List<Object?> events = data['events']! as List<Object?>;
    (events[1]! as Map<String, Object?>).addAll(<String, Object?>{
      'lat': 38.768,
      'lon': -9.094,
    });
    (events[2]! as Map<String, Object?>).addAll(<String, Object?>{
      'lat': 38.7527,
      'lon': -9.1847,
    });
    final FakeGateway g = FakeGateway()..publicPrefixes.add('/v1/events');
    g.services['/v1/events'] = (http.Request r) => FakeGateway.json(data);
    final MemorySettingsStore store = MemorySettingsStore('es');
    // El hotel ya marcado en Lisboa.
    const GeoPoint hotel = GeoPoint(38.76, -9.10);
    await store.writeData(
      LocalData.eventsHotel,
      '{"iata":"LIS","lat":38.76,"lon":-9.1}',
    );
    final FakeMap map = FakeMap();
    final session = newSession()..continueAsGuest();
    tester.view.physicalSize = const Size(1200, 4000);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await pumpApp(
      tester,
      locale: 'es',
      session: session,
      initialLocation: Routes.events(iata: 'LIS'),
      services: fakeServices(session, gateway: g, prefs: store, map: map),
    );
    await tester.pumpAndSettle();

    final int walk = (hotel.distanceTo(const GeoPoint(38.768, -9.094)) / 80)
        .round();
    expect(find.text('🏨 A $walk min andando de tu hotel'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('Cambiar dónde está tu hotel'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    // Dos eventos y el hotel (en blanco).
    final List<Object?> pins = map.pins!['features']! as List<Object?>;
    expect(pins, hasLength(3));
    expect((pins.last! as Map<String, Object?>)['id'], 'hotel');

    // Tocar el mapa junto al estadio: solo ese evento.
    map.spec!.onTap(const GeoPoint(38.7530, -9.1850));
    await tester.pumpAndSettle();
    expect(find.text('Benfica - Porto'), findsOneWidget);
    expect(find.text('Concierto en el estadio'), findsNothing);
  });
}
