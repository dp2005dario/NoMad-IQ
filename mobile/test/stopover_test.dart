// Escala de regalo: qué escalas pillan de camino y la pantalla (precio con
// la aerolínea de la escala y reservar en su página).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:nomadiq/core/router.dart';
import 'package:nomadiq/features/flights/fares_api.dart';
import 'package:nomadiq/features/route/world_data.dart';
import 'package:nomadiq/features/stopover/stopover.dart';

import 'helpers.dart';

final Airports airports = Airports.parse(
  'MAD|40.472|-3.563|Madrid|Spain|Europe/Madrid\n'
  'HND|35.552|139.780|Tokyo|Japan|Asia/Tokyo\n'
  'JFK|40.640|-73.779|New York|United States|America/New_York\n'
  'IST|41.275|28.752|Istanbul|Turkey|Europe/Istanbul\n'
  'DOH|25.273|51.608|Doha|Qatar|Asia/Qatar\n'
  'HEL|60.317|24.963|Helsinki|Finland|Europe/Helsinki\n'
  'KEF|63.985|-22.606|Keflavik|Iceland|Atlantic/Reykjavik\n'
  'LIS|38.781|-9.136|Lisbon|Portugal|Europe/Lisbon\n'
  'DXB|25.253|55.364|Dubai|United Arab Emirates|Asia/Dubai\n'
  'SIN|1.350|103.994|Singapore|Singapore|Asia/Singapore\n'
  'PTY|9.071|-79.383|Panama City|Panama|America/Panama\n'
  'BCN|41.297|2.078|Barcelona|Spain|Europe/Madrid',
);

List<String> hubs(String from, String to) => <String>[
  for (final StopoverOption o in stopoversFor(
    airports[from]!,
    airports[to]!,
    airports,
  ))
    o.hub.iata,
];

void main() {
  test('Madrid → Tokio: Estambul, Doha... pero no Reikiavik', () {
    final List<String> h = hubs('MAD', 'HND');
    expect(h, containsAll(<String>['IST', 'DOH', 'DXB']));
    expect(h, isNot(contains('KEF')));
    expect(h, isNot(contains('PTY')));
  });

  test('Madrid → Nueva York: Lisboa y Reikiavik de camino', () {
    final List<String> h = hubs('MAD', 'JFK');
    expect(h.first, 'LIS');
    expect(h, contains('KEF'));
    expect(h, isNot(contains('DOH')));
  });

  test('un vuelo muy corto no tiene escala de regalo', () {
    expect(hubs('MAD', 'BCN'), isEmpty);
  });

  test('las noches que se pueden elegir', () {
    final StopoverProgram etihad = stopoverPrograms.firstWhere(
      (StopoverProgram p) => p.hub == 'AUH',
    );
    // Su web no dice el máximo: hasta 3, como en la maqueta.
    expect(etihad.maxNights, isNull);
    expect(nightChoices(etihad), <int>[0, 1, 2, 3]);
    const StopoverProgram short = StopoverProgram(
      hub: 'XXX',
      airline: 'XX',
      airlineName: 'X',
      url: 'https://x.example',
      maxNights: 2,
      rule: StopoverRule.sameFare,
    );
    expect(nightChoices(short), <int>[0, 1, 2]);
  });

  testWidgets('escala en Estambul: precio con Turkish y reservar en su web', (
    WidgetTester tester,
  ) async {
    final FakeGateway g = FakeGateway()..publicPrefixes.add('/v1/fares/search');
    final List<Uri> opened = <Uri>[];
    g.services['/v1/fares/search'] = (http.Request r) {
      final Map<String, String> q = r.url.queryParameters;
      final String key = FareRoute.keyFor(
        q['origin']!,
        q['destination']!,
        DateTime.parse(q['departure']!),
      );
      final FareRoute route = FareRoute.fromKey(key)!;
      Map<String, Object?> offer(
        int price,
        String carrier,
        int stops,
      ) => <String, Object?>{
        'price_per_adult': <String, Object?>{
          'amount_minor': price,
          'currency': 'EUR',
        },
        'total': <String, Object?>{'amount_minor': price, 'currency': 'EUR'},
        'carrier': carrier,
        'departure_at': '${q['departure']}T15:05:00+01:00',
        'transfers': stops,
        'booking_url': 'https://www.aviasales.com/search/$carrier',
      };
      return FakeGateway.json(<String, Object?>{
        'route': <String, Object?>{
          'route_key': key,
          'origin': route.origin,
          'destination': route.destination,
          'departure_date': q['departure'],
          'return_date': null,
          'cabin': 'ECONOMY',
        },
        'adults': 1,
        'offers': <Object?>[offer(61000, 'IB', 0), offer(64000, 'TK', 1)],
      });
    };
    final session = newSession()..continueAsGuest();
    tester.view.physicalSize = const Size(1200, 5000);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await pumpApp(
      tester,
      locale: 'es',
      session: session,
      initialLocation: Routes.stopover(from: 'MAD', to: 'HND'),
      services: fakeServices(
        session,
        gateway: g,
        openLink: (Uri u) async {
          opened.add(u);
          return true;
        },
      ),
    );
    await tester.pumpAndSettle();
    // testAirports (helpers) solo tiene MAD, HND y LIS: Lisboa no pilla de
    // camino a Tokio, así que no hay escala.
    expect(
      find.text(
        'Ningún programa de escala pilla de camino en este viaje sin dar un '
        'buen rodeo.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('con los hubs: elegir Estambul, ver precio y reservar', (
    WidgetTester tester,
  ) async {
    final FakeGateway g = FakeGateway()..publicPrefixes.add('/v1/fares/search');
    final List<Uri> opened = <Uri>[];
    g.services['/v1/fares/search'] = (http.Request r) {
      final Map<String, String> q = r.url.queryParameters;
      final String key = FareRoute.keyFor(
        q['origin']!,
        q['destination']!,
        DateTime.parse(q['departure']!),
      );
      Map<String, Object?> offer(
        int price,
        String carrier,
        int stops,
      ) => <String, Object?>{
        'price_per_adult': <String, Object?>{
          'amount_minor': price,
          'currency': 'EUR',
        },
        'total': <String, Object?>{'amount_minor': price, 'currency': 'EUR'},
        'carrier': carrier,
        'departure_at': '${q['departure']}T15:05:00+01:00',
        'transfers': stops,
        'booking_url': 'https://www.aviasales.com/search/$carrier',
      };
      return FakeGateway.json(<String, Object?>{
        'route': <String, Object?>{
          'route_key': key,
          'origin': 'MAD',
          'destination': 'HND',
          'departure_date': q['departure'],
          'return_date': null,
          'cabin': 'ECONOMY',
        },
        'adults': 1,
        'offers': <Object?>[offer(61000, 'IB', 0), offer(64000, 'TK', 1)],
      });
    };
    final session = newSession()..continueAsGuest();
    tester.view.physicalSize = const Size(1200, 5000);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await pumpApp(
      tester,
      locale: 'es',
      session: session,
      initialLocation: Routes.stopover(from: 'MAD', to: 'HND'),
      services: fakeServices(
        session,
        gateway: g,
        loadAirports: () async => airports,
        openLink: (Uri u) async {
          opened.add(u);
          return true;
        },
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(ChoiceChip, 'Istanbul'));
    await tester.pumpAndSettle();
    expect(find.text('Turkish Airlines'), findsOneWidget);
    expect(find.text('Istanbul · 2 noches'), findsOneWidget);

    await tester.tap(find.text('Ver precio'));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('Con Turkish Airlines, con escala corta'),
      findsOneWidget,
    );
    expect(
      // Turkish no promete el mismo precio en su web: se pide mirarlo allí.
      find.text('Con 2 noches en Istanbul: mira el precio exacto en su web'),
      findsOneWidget,
    );

    await tester.tap(find.text('Reservar con 2 noches en Istanbul'));
    await tester.pumpAndSettle();
    expect(opened.single.host, 'www.turkishairlines.com');
  });
}
