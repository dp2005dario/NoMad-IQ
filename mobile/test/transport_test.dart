// Moverte: salidas del aeropuerto (OpenStreetMap), ruta en Google Maps,
// ¿me compensa el bono? y mis billetes (solo en el móvil).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:eclipta/core/router.dart';
import 'package:eclipta/core/settings.dart';
import 'package:eclipta/features/easy/easy_mode.dart';
import 'package:eclipta/features/transport/my_tickets.dart';
import 'package:eclipta/features/transport/transport_data.dart';

import 'helpers.dart';

const Map<String, Object?> hanedaJson = <String, Object?>{
  'iata': 'HND',
  'lat': 35.5494,
  'lon': 139.7798,
  'attribution': '© OpenStreetMap contributors (ODbL)',
  'spots': <Object?>[
    <String, Object?>{
      'id': 'n1',
      'kind': 'train',
      'lat': 35.545,
      'lon': 139.768,
      'name': 'Haneda Airport Terminal 3',
    },
    // La misma estación dibujada dos veces: el nombre sale una vez.
    <String, Object?>{
      'id': 'w2',
      'kind': 'train',
      'lat': 35.5451,
      'lon': 139.7681,
      'name': 'Haneda Airport Terminal 3',
    },
    <String, Object?>{
      'id': 'n3',
      'kind': 'taxi',
      'lat': 35.546,
      'lon': 139.769,
    },
    <String, Object?>{'id': 'n4', 'kind': 'toilets', 'lat': 35.5, 'lon': 139.7},
  ],
};

void main() {
  test('la cuenta con los precios que apunta la persona', () {
    // 5 días con un bono de 72 h = dos bonos.
    final PassMath m = passPaysOff(
      days: 5,
      ridesPerDay: 4,
      single: 2,
      passPrice: 15,
      passHours: 72,
    );
    expect(m.singles, 40);
    expect(m.passes, 30);
    expect(m.passPaysOff, isTrue);
    expect(cityForAirport('nrt')!.id, 'tokyo');
    expect(cityForAirport('XXX'), isNull);
    // Ningún precio escrito a mano en la tabla: solo nombres y webs oficiales.
    for (final CityTransit c in cityTransit) {
      expect(c.url, startsWith('https://'));
      for (final TransitPass p in c.passes) {
        expect(p.url, startsWith('https://'));
      }
    }
  });

  test('un bono cuenta las horas y se guarda', () {
    final DateTime start = DateTime(2026, 10, 25, 10);
    final TransitTicket t = TransitTicket(
      id: '1',
      name: 'Tokyo Subway Ticket',
      hours: 72,
      activatedAt: start,
      url: 'javascript:alert(1)',
    );
    expect(t.leftAt(start.add(const Duration(hours: 21)))!.inHours, 51);
    expect(t.leftAt(start.add(const Duration(days: 4))), Duration.zero);
    final List<TransitTicket> back = decodeTickets(
      encodeTickets(<TransitTicket>[t]),
    );
    expect(back.single.hours, 72);
    expect(back.single.activatedAt, start);
    expect(back.single.url, isNull);
    expect(decodeTickets('roto'), isEmpty);
  });

  testWidgets('llegas a Haneda: salidas, ruta, bono y billete', (
    WidgetTester tester,
  ) async {
    final FakeGateway g = FakeGateway()..publicPrefixes.add('/v1/airports/');
    g.services['/v1/airports/HND/spots'] = (http.Request r) =>
        FakeGateway.json(hanedaJson);
    final MemorySettingsStore store = MemorySettingsStore('es');
    await saveEasyTrip(
      store,
      const EasyTrip(to: 'HND', hotelAddress: 'Shinjuku 3-1, Tokyo'),
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
      initialLocation: Routes.transport(),
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

    expect(find.text('Aeropuerto HND'), findsOneWidget);
    expect(find.text('Haneda Airport Terminal 3'), findsOneWidget);
    expect(find.text('Taxi'), findsOneWidget);
    await tester.tap(find.byTooltip('Ver ruta').first);
    expect(opened.single.queryParameters['travelmode'], 'transit');
    expect(opened.single.queryParameters['origin'], '35.54940,139.77980');
    expect(opened.single.queryParameters['destination'], 'Shinjuku 3-1, Tokyo');

    await tester.tap(find.text('Bonos'));
    await tester.pumpAndSettle();
    expect(find.text('Suica / PASMO'), findsOneWidget);
    expect(find.text('Tokyo Subway Ticket'), findsOneWidget);
    // Sin precios apuntados, Flyra pide mirarlos en la web oficial.
    expect(find.textContaining('Mira los precios en la web oficial'), findsOne);
    await tester.enterText(
      find.widgetWithText(TextField, 'Precio de un viaje suelto'),
      '180',
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Precio del bono'),
      '1500',
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Duración del bono (horas)'),
      '72',
    );
    await tester.pumpAndSettle();
    // 3 días × 4 viajes × 180 = 2160 frente a un bono de 1500.
    expect(find.textContaining('El bono te compensa'), findsOneWidget);
    expect(find.textContaining(RegExp(r'2\D?160')), findsOneWidget);

    await tester.tap(find.text('Web oficial').at(1));
    expect(opened.last.host, 'www.tokyometro.jp');
    // El segundo "Ya lo tengo" es el del bono (el primero, la tarjeta).
    await tester.tap(find.text('Ya lo tengo').at(1));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, '72');
    await tester.tap(find.text('Guardar'));
    await tester.pumpAndSettle();

    expect(find.text('● ACTIVO'), findsOneWidget);
    expect(find.text('Bono de 72 h'), findsOneWidget);
    expect(find.textContaining(RegExp(r'^Quedan 7[12] h$')), findsOneWidget);
    expect(
      decodeTickets(store.readData(LocalData.transitTickets)).single.name,
      'Tokyo Subway Ticket',
    );
  });
}
