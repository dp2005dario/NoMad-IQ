// Sin colas: esperas que avisan los viajeros (con mínimos), "recuérdamelo"
// (un aviso del móvil, no un turno) y restaurantes con reserva de OSM.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:eclipta/core/router.dart';
import 'package:eclipta/features/map/geo.dart';
import 'package:eclipta/features/map/location.dart';
import 'package:eclipta/features/nearby/nearby_api.dart';
import 'package:eclipta/features/queues/queues_api.dart';
import 'package:eclipta/features/queues/reminders.dart';

import 'helpers.dart';

class BelemLocation extends FakeLocation {
  BelemLocation() {
    access = LocationAccess.granted;
  }

  @override
  Stream<PositionFix> watch({TrackingNotice? background}) =>
      Stream<PositionFix>.value(
        PositionFix(
          point: const GeoPoint(38.6916, -9.2160),
          accuracyM: 10,
          recordedAt: DateTime.utc(2026, 10, 25),
        ),
      );
}

Map<String, Object?> queueJson() => <String, Object?>{
  'place': 'Q193208',
  'now': <String, Object?>{'wait': 3, 'reporters': 4, 'minutes_ago': 12},
  'hours': <Object?>[
    // Las 22 es la hora tranquila; las demás, de 15 a 30 min.
    for (int h = 0; h < 24; h++)
      <String, Object?>{'hour': h, 'wait': h == 22 ? 0 : 2, 'reporters': 3},
  ],
  'reported_this_hour': false,
};

const Map<String, Object?> nearbyJson = <String, Object?>{
  'lat': 38.69,
  'lon': -9.22,
  'attribution': '© OpenStreetMap contributors (ODbL)',
  'spots': <Object?>[
    <String, Object?>{
      'id': 'n1',
      'kind': 'table',
      'lat': 38.6975,
      'lon': -9.2065,
      'name': 'Pastéis e Mesa',
      'website': 'https://mesa.example.pt',
      'phone': '+351 21 000 0000',
      'cuisine': 'portuguese',
      'reservation': 'required',
    },
    <String, Object?>{
      'id': 'n2',
      'kind': 'table',
      'lat': 38.69,
      'lon': -9.21,
      'name': 'Sin enlace raro',
      'website': 'javascript:alert(1)',
    },
    <String, Object?>{'id': 'n3', 'kind': 'water', 'lat': 38.69, 'lon': -9.21},
  ],
};

void main() {
  test('la mejor hora solo entre las que tienen avisos', () {
    final PlaceQueue q = PlaceQueue.parse(queueJson());
    expect(q.now!.wait, WaitLevel.long);
    expect(q.bestFrom(10)!.hour, 22);
    expect(
      PlaceQueue.parse(<String, Object?>{'hours': <Object?>[]}).bestFrom(0),
      isNull,
    );
    // Niveles imposibles: fuera.
    expect(
      PlaceQueue.parse(<String, Object?>{
        'now': <String, Object?>{'wait': 9, 'reporters': 2, 'minutes_ago': 1},
      }).now,
      isNull,
    );
  });

  test('restaurantes: solo https y teléfonos de verdad', () {
    final NearbyList list = NearbyList.parse(nearbyJson);
    final List<NearbySpot> tables = list.of(
      NearbyKind.table,
      const GeoPoint(38.69, -9.21),
    );
    expect(tables, hasLength(2));
    expect(tables.first.website, isNull);
    expect(tables.last.website!.host, 'mesa.example.pt');
    expect(tables.last.reservationRequired, isTrue);
  });

  testWidgets('cola ahora, por horas, avisar y restaurantes', (
    WidgetTester tester,
  ) async {
    final FakeGateway g = FakeGateway()
      ..publicPrefixes.addAll(<String>['/v1/places/', '/v1/nearby']);
    final List<Map<String, Object?>> posts = <Map<String, Object?>>[];
    g.services['/v1/places/LIS'] = (_) => FakeGateway.json(<String, Object?>{
      'iata': 'LIS',
      'language': 'es',
      'wikidata_id': 'Q597',
      'city': 'Lisboa',
      'attractions': <Object?>[
        <String, Object?>{'name': 'Torre de Belém', 'wikidata_id': 'Q193208'},
        <String, Object?>{'name': 'Sin Wikidata'},
      ],
      'attribution': 'Wikidata',
    });
    g.services['/v1/queues/Q193208'] = (http.Request r) {
      if (r.method == 'POST') {
        posts.add(jsonDecode(r.body) as Map<String, Object?>);
        return http.Response('', 204);
      }
      return FakeGateway.json(queueJson());
    };
    g.services['/v1/nearby'] = (_) => FakeGateway.json(nearbyJson);
    final List<Uri> opened = <Uri>[];
    final MemoryReminders reminders = MemoryReminders();
    final session = await signedInSession(g);
    tester.view.physicalSize = const Size(1200, 6000);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await pumpApp(
      tester,
      locale: 'es',
      session: session,
      initialLocation: Routes.queues(city: 'LIS'),
      services: fakeServices(
        session,
        gateway: g,
        location: BelemLocation(),
        reminders: reminders,
        openBooking: (Uri u) async {
          opened.add(u);
          return true;
        },
      ),
    );
    await tester.pumpAndSettle();

    // Solo los sitios con Wikidata (así se cuentan bien los avisos).
    expect(find.text('Torre de Belém'), findsOneWidget);
    expect(find.text('Sin Wikidata'), findsNothing);
    expect(find.text('De 30 a 60 min'), findsWidgets);
    expect(find.textContaining('Avisado por 4 viajeros'), findsOneWidget);

    if (DateTime.now().hour < 21) {
      expect(
        find.textContaining('Hora más tranquila hoy: 22:00'),
        findsOneWidget,
      );
      await tester.tap(find.text('Recuérdamelo antes de las 22:00'));
      await tester.pumpAndSettle();
      expect(reminders.scheduled.values.single.$1.hour, 21);
      expect(
        find.text('Es un aviso de tu móvil, no un turno en la cola.'),
        findsOneWidget,
      );
    }

    final Finder none = find.widgetWithText(ActionChip, 'Sin cola');
    await tester.ensureVisible(none);
    await tester.pumpAndSettle();
    await tester.tap(none);
    await tester.pumpAndSettle();
    expect(posts.single, <String, Object?>{
      'wait': 0,
      'local_hour': DateTime.now().hour,
    });

    expect(find.text('Pastéis e Mesa'), findsOneWidget);
    expect(find.textContaining('reserva obligatoria'), findsOneWidget);
    await tester.tap(find.byTooltip('Reservar en su web'));
    expect(opened.last.host, 'mesa.example.pt');
  });

  testWidgets('invitado: pide entrar para ver las colas', (
    WidgetTester tester,
  ) async {
    final FakeGateway g = FakeGateway()
      ..publicPrefixes.addAll(<String>['/v1/places/', '/v1/nearby']);
    g.services['/v1/places/LIS'] = (_) => FakeGateway.json(<String, Object?>{
      'iata': 'LIS',
      'language': 'es',
      'wikidata_id': 'Q597',
      'city': 'Lisboa',
      'attractions': <Object?>[
        <String, Object?>{'name': 'Torre de Belém', 'wikidata_id': 'Q193208'},
      ],
      'attribution': 'Wikidata',
    });
    g.services['/v1/queues/Q193208'] = (_) => FakeGateway.json(queueJson());
    g.services['/v1/nearby'] = (_) => FakeGateway.json(nearbyJson);
    final session = newSession(g)..continueAsGuest();
    await pumpApp(
      tester,
      locale: 'es',
      session: session,
      initialLocation: Routes.queues(city: 'LIS'),
      services: fakeServices(session, gateway: g, location: BelemLocation()),
    );
    await tester.pumpAndSettle();
    expect(
      find.text('Inicia sesión para ver y avisar de cuánta cola hay.'),
      findsOneWidget,
    );
  });
}
