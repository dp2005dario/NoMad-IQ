// Dormir barato: zonas para dormir (junto al sitio y estaciones con
// alojamientos), "Ver precios" en Booking con las fechas, y la calculadora
// del total real (alojamiento + trenes) frente a dormir al lado.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:nomadiq/core/router.dart';
import 'package:nomadiq/features/map/geo.dart';
import 'package:nomadiq/features/stays/stays_api.dart';
import 'package:nomadiq/features/stays/stays_math.dart';

import 'helpers.dart';

const Map<String, Object?> staysJson = <String, Object?>{
  'attribution': '© OpenStreetMap contributors (ODbL)',
  'zones': <Object?>[
    <String, Object?>{
      'id': 'near',
      'lat': 48.8584,
      'lon': 2.2945,
      'km': 0,
      'minutes': 10,
      'by': 'walk',
      'lodgings': 12,
      'budget': 1,
      'examples': <String>['Hôtel Eiffel'],
    },
    <String, Object?>{
      'id': 'n100',
      'name': 'Saint-Denis',
      'lat': 48.9356,
      'lon': 2.3539,
      'km': 9.6,
      'minutes': 21,
      'by': 'train',
      'lodgings': 30,
      'budget': 6,
      'examples': <String>['Ibis Budget', 'Hostel SD'],
    },
    // Fuera del radio de 15 km: solo sale con "Hasta 35 km".
    <String, Object?>{
      'id': 'n101',
      'name': 'Versailles',
      'lat': 48.8,
      'lon': 2.13,
      'km': 20.4,
      'minutes': 39,
      'by': 'train',
      'lodgings': 25,
      'budget': 2,
      'examples': <String>[],
    },
    // Mal formada: se ignora.
    <String, Object?>{'id': 'x', 'by': 'boat'},
  ],
};

void main() {
  test('casilla, coste y enlace a Booking', () {
    expect(stayCellOf(const GeoPoint(48.8584, 2.2945)), (48.86, 2.3));
    const StayCost c = StayCost(nights: 3, people: 2, nightPrice: 90, fare: 3);
    // 4 días con ida y vuelta, dos personas: 16 trayectos.
    expect(c.trips, 16);
    expect(c.total, 270 + 48);
    final Uri u = bookingSearch(
      at: const GeoPoint(48.9356, 2.3539),
      checkIn: DateTime(2026, 11, 3),
      checkOut: DateTime(2026, 11, 6),
      adults: 2,
      language: 'es',
    );
    expect(u.host, 'www.booking.com');
    expect(u.queryParameters['checkin'], '2026-11-03');
    expect(u.queryParameters['dest_type'], 'latlong');
    expect(u.queryParameters.containsKey('aid'), isFalse);
  });

  testWidgets('zonas, radios, Booking y total real', (
    WidgetTester tester,
  ) async {
    final FakeGateway g = FakeGateway()..publicPrefixes.add('/v1/stays');
    final List<Uri> sent = <Uri>[];
    g.services['/v1/stays'] = (http.Request r) {
      sent.add(r.url);
      return FakeGateway.json(staysJson);
    };
    final List<Uri> opened = <Uri>[];
    final session = newSession()..continueAsGuest();
    tester.view.physicalSize = const Size(1200, 5000);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await pumpApp(
      tester,
      locale: 'es',
      session: session,
      initialLocation: Routes.stays(lat: 48.8584, lon: 2.2945, name: 'Torre'),
      services: fakeServices(
        session,
        gateway: g,
        openBooking: (Uri u) async {
          opened.add(u);
          return true;
        },
      ),
    );
    await tester.pumpAndSettle();

    // Solo la casilla de ~2 km sale del móvil.
    expect(sent.single.queryParameters, <String, String>{
      'lat': '48.86',
      'lon': '2.3',
    });
    expect(find.text('Torre'), findsOneWidget);
    expect(find.text('Junto al sitio'), findsOneWidget);
    expect(find.text('Saint-Denis'), findsOneWidget);
    expect(find.text('Versailles'), findsNothing);
    expect(find.textContaining('Saint-Denis, con 30 alojamientos'), findsOne);

    await tester.tap(find.text('Hasta 35 km'));
    await tester.pumpAndSettle();
    expect(find.text('Versailles'), findsOneWidget);
    await tester.tap(find.text('Hasta 15 km'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Ver precios').at(1));
    expect(opened.single.queryParameters['latitude'], '48.93560');
    expect(opened.single.queryParameters['group_adults'], '2');

    // Total real: al lado 150 €/noche; en Saint-Denis 90 €/noche + 3 € tren.
    await tester.tap(find.text('Calcular el total real').first);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, 'Precio por noche'),
      '150',
    );
    await tester.pump();
    await tester.tap(find.text('Calcular el total real').at(1));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, 'Precio por noche').at(1),
      '90',
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Billete por trayecto'),
      '3',
    );
    await tester.pumpAndSettle();
    expect(find.text('Total real: 450'), findsOneWidget);
    expect(find.text('Total real: 318'), findsOneWidget);
    expect(find.text('Te ahorras 132 frente a dormir al lado'), findsOne);
  });
}
