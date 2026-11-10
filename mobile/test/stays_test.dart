// Hoteles / Dormir barato: la página de la maqueta con las zonas reales para
// dormir (junto al sitio y estaciones con alojamientos), los precios que
// apuntas tú y "Ver precios" en Booking con tus noches.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:eclipta/core/router.dart';
import 'package:eclipta/features/map/geo.dart';
import 'package:eclipta/features/stays/stays_api.dart';
import 'package:eclipta/features/stays/stays_math.dart';
import 'package:eclipta/features/stays/stays_page.dart';
import 'package:eclipta/l10n/generated/app_localizations.dart';

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
  // El servidor los ordena desde el centro de su casilla; la app, desde ti.
  'hotels': <Object?>[
    <String, Object?>{
      'id': 'n7',
      'name': 'Hôtel Lejano',
      'kind': 'hotel',
      'lat': 48.8650,
      'lon': 2.2945,
      'km': 0.4,
    },
    <String, Object?>{
      'id': 'w8',
      'name': 'Pension Tour',
      'kind': 'guest_house',
      'stars': 3,
      'lat': 48.8590,
      'lon': 2.2945,
      'km': 0.9,
    },
    // Sin id de OpenStreetMap válido: fuera.
    <String, Object?>{'id': 'x1', 'name': 'Raro', 'kind': 'hotel'},
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

  test(
    'la página: chips, zonas en su sitio, precios tuyos y nada inventado',
    () {
      final AppLocalizations t = lookupAppLocalizations(const Locale('es'));
      final List<StayChip> chips = landmarkChips(t);
      expect(chips.first.name, 'Torre Eiffel');
      expect(chips[1].year, 'desde 1882');
      final StayArea area = StayArea.parse(staysJson);
      final Map<String, Object?> data = staysPageData(
        t: t,
        language: 'es',
        chips: chips,
        current: 0,
        nights: 3,
        center: chips.first.point,
        area: area,
        prices: <String, StayPrices>{'n100': StayPrices()..night = 90},
      );
      final List<Map<String, Object?>> zones = (data['zones']! as List<Object?>)
          .cast<Map<String, Object?>>();
      expect(zones, hasLength(3));
      expect(zones.first['by'], 'walk');
      expect(zones.first['night'], isNull); // sin precio: no se inventa
      // Saint-Denis está al norte (y negativo) y algo al este.
      expect(zones[1]['y']! as int, lessThan(-8000));
      expect(zones[1]['x']! as int, greaterThan(4000));
      expect(zones[1]['night'], 90);
      final Map<String, Object?> tx = data['t']! as Map<String, Object?>;
      expect(
        tx['lodgings'],
        '{n} alojamientos · {budget} económicos (albergues, pensiones)',
      );
      expect(data['attr'], '© OpenStreetMap contributors (ODbL)');

      final String page = File(staysPage).readAsStringSync();
      expect(page, isNot(contains('Datos de ejemplo')));
      expect(page, isNot(contains('Maison')));
      expect(page, contains(staysMarker));
      final String html = staysPageWith(page, <String, Object?>{
        ...data,
        'msg': '</script>',
      });
      expect(html, isNot(contains('"</script>"')));
    },
  );

  testWidgets('abre la maqueta en tu destino; apuntar precio y Booking', (
    WidgetTester tester,
  ) async {
    final FakeGateway g = FakeGateway()..publicPrefixes.add('/v1/stays');
    final List<Uri> sent = <Uri>[];
    g.services['/v1/stays'] = (http.Request r) {
      sent.add(r.url);
      return FakeGateway.json(staysJson);
    };
    final List<Uri> opened = <Uri>[];
    final List<String> pages = <String>[];
    void Function(String)? send;
    final session = newSession()..continueAsGuest();
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
        webScene: (String html, void Function(String) onMessage) {
          pages.add(html);
          send = onMessage;
          return const SizedBox.expand();
        },
      ),
    );
    Future<Map<String, Object?>> settled([int after = 0]) async {
      bool done() =>
          pages.length > after &&
          (pageData(pages.last)['zones']! as List<Object?>).isNotEmpty;
      for (int i = 0; i < 50 && !done(); i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)),
        );
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(done(), isTrue);
      return pageData(pages.last);
    }

    final Map<String, Object?> data = await settled();
    // Solo la casilla de ~2 km sale del móvil.
    expect(sent.last.queryParameters, <String, String>{
      'lat': '48.86',
      'lon': '2.3',
    });
    final List<Object?> chips = data['chips']! as List<Object?>;
    expect((chips.first! as Map<String, Object?>)['name'], 'Torre');
    expect(chips, hasLength(9)); // destino, cerca de ti, 6 monumentos, mapa
    expect(data['cur'], 0);

    send!('night:1:9000');
    send!('fare:1:300');
    send!('nights:4');
    send!('book:1');
    expect(opened.single.queryParameters['latitude'], '48.93560');
    final DateTime inDay = DateTime.parse(
      opened.single.queryParameters['checkin']!,
    );
    expect(
      DateTime.parse(opened.single.queryParameters['checkout']!)
          .difference(inDay)
          .inDays,
      4,
    );
    send!('book:99'); // una zona que no existe: nada
    expect(opened, hasLength(1));

    // Los alojamientos más cerca, como en Google Maps: el más cercano a TI
    // primero, con su tipo, estrellas y metros.
    final List<Object?> hotels = data['hotels']! as List<Object?>;
    expect(hotels, hasLength(2));
    final Map<String, Object?> first = hotels.first! as Map<String, Object?>;
    expect(first['name'], 'Pension Tour');
    expect(first['kind'], 'guest_house');
    expect(first['stars'], 3);
    expect(first['m'], 70);
    // Tocar la tarjeta abre ESE hotel en Google Maps; "Precios", Booking
    // alrededor del hotel.
    send!('hotel:0');
    expect(opened.last.host, 'www.google.com');
    expect(opened.last.pathSegments, <String>[
      'maps',
      'search',
      'Pension Tour',
      '@48.85900,2.29450,17z',
    ]);
    send!('hprice:0');
    expect(opened.last.queryParameters['latitude'], '48.85900');
    send!('hotel:9'); // no existe: nada
    expect(opened, hasLength(3));

    // Otro chip (la Torre Eiffel): se pide su zona y lo apuntado se guarda.
    final int before = pages.length;
    send!('chip:2');
    final Map<String, Object?> again = await settled(before);
    expect(again['cur'], 2);
    expect(again['nights'], 4);
    final Map<String, Object?> sd =
        (again['zones']! as List<Object?>)[1]! as Map<String, Object?>;
    expect((sd['night'], sd['fare']), (90.0, 3.0));
  });
}

/// Los datos que la app metió en la página.
Map<String, Object?> pageData(String html) => jsonDecode(
  html.substring(html.indexOf('var ECL=') + 8, html.indexOf(';\nvar T=ECL.t')),
) as Map<String, Object?>;
