// "Copia este viaje": abrir con el código, adaptar al presupuesto, copiarlo
// al móvil y compartir uno propio.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:nomadiq/auth/session.dart';
import 'package:nomadiq/core/router.dart';
import 'package:nomadiq/core/settings.dart';
import 'package:nomadiq/features/copy_trip/copied_trips.dart';
import 'package:nomadiq/features/copy_trip/copy_trip_screen.dart';
import 'package:nomadiq/features/copy_trip/shared_trip_api.dart';

import 'helpers.dart';

Map<String, Object?> line(String kind, String title, int price) =>
    <String, Object?>{'kind': kind, 'title': title, 'price_minor': price};

final Map<String, Object?> japan = <String, Object?>{
  'code': '7K2M9QXD',
  'author': 'laura.viaja',
  'title': 'Japón en 10 días',
  'destination': 'Tokio y Kioto',
  'days': 10,
  'currency': 'EUR',
  'items': <Object?>[
    line('flight', 'Vuelo directo Madrid-Tokio', 98000),
    line('stay', 'Hotel en Shinjuku, 9 noches', 81000),
    line('transport', 'JR Pass de 7 días', 38000),
    line('food', 'Cena kaiseki en Kioto', 15000),
    line('activity', 'Excursión a Hakone con guía', 8000),
  ],
  'total_minor': 240000,
  'copies': 3200,
  'mine': false,
  'created_at': '2026-10-24T10:00:00Z',
};

Map<String, Object?> adapted(String title, int price, String was, int wasP) =>
    <String, Object?>{
      ...line('flight', title, price),
      'was_title': was,
      'was_price_minor': wasP,
    };

void main() {
  group('reglas', () {
    test('el código se escribe como sea', () {
      expect(normalizeTripCode('7k2m-9qxd'), '7K2M9QXD');
      expect(normalizeTripCode(' 7K2M 9QXD '), '7K2M9QXD');
      expect(normalizeTripCode('OIL23456'), '01123456');
      expect(normalizeTripCode('corto'), isNull);
      expect(normalizeTripCode('UUUUUUUU'), isNull); // la U no existe
    });

    test('presupuestos: original, 3/4 y la mitad en decenas', () {
      expect(budgetSteps(240000, 'EUR'), <int>[240000, 180000, 120000]);
      expect(budgetSteps(179300, 'EUR'), <int>[179300, 134000, 89000]);
      expect(budgetSteps(2000, 'EUR'), <int>[2000]);
      expect(budgetSteps(300000, 'JPY'), <int>[300000, 225000, 150000]);
    });

    test('se lee el viaje y la adaptación', () {
      final SharedTrip trip = SharedTrip.parse(japan);
      expect(trip.totalMinor, 240000);
      expect(trip.lines.first.kind, TripKind.flight);
      final TripAdaptation a = TripAdaptation.parse(<String, Object?>{
        'items': <Object?>[
          adapted('Con escala', 69000, 'Directo', 98000),
          adapted('Igual', 100, 'Igual', 100),
        ],
        'budget_minor': 70000,
        'fits': true,
        'remaining_today': null,
      });
      expect(a.changes, 1);
      expect(a.totalMinor, 69100);
      expect(a.remainingToday, isNull);
    });

    test('copiados: en el móvil, sin repetir y los nuevos primero', () async {
      final MemorySettingsStore store = MemorySettingsStore();
      final CopiedTrips trips = CopiedTrips(store);
      CopiedTrip c(String code, int price) => CopiedTrip(
        code: code,
        title: 'Viaje $code',
        destination: 'Roma',
        days: 3,
        currency: 'EUR',
        lines: <TripLine>[
          TripLine(kind: TripKind.stay, title: 'Hotel', priceMinor: price),
        ],
        copiedAt: DateTime.utc(2026, 10, 24),
      );
      await trips.add(c('A', 100));
      await trips.add(c('B', 200));
      await trips.add(c('A', 50));
      expect(trips.all().map((CopiedTrip t) => t.code), <String>['A', 'B']);
      expect(trips.all().first.totalMinor, 50);
      await trips.remove('A');
      expect(CopiedTrips(store).all().single.code, 'B');
      await store.writeData(LocalData.copiedTrips, 'basura');
      expect(trips.all(), isEmpty);
    });

    test('del bote de Gastos se adivina el tipo', () {
      expect(guessKind('Vuelo a Roma'), TripKind.flight);
      expect(guessKind('Hotel Trastevere'), TripKind.stay);
      expect(guessKind('Cena en La Latina'), TripKind.food);
      expect(guessKind('Helados'), TripKind.other);
    });
  });

  testWidgets('abrir con código, adaptar a 1.800 € y copiar', (
    WidgetTester tester,
  ) async {
    final FakeGateway g = FakeGateway();
    final SessionController session = await signedInSession(g);
    final MemorySettingsStore store = MemorySettingsStore();
    final List<Map<String, Object?>> asked = <Map<String, Object?>>[];
    g.services['/v1/shared-trips/mine'] = (_) =>
        FakeGateway.json(<String, Object?>{'items': <Object?>[]});
    g.services['/v1/shared-trips/7K2M9QXD'] = (_) => FakeGateway.json(japan);
    g.services['/v1/shared-trips/7K2M9QXD/copy'] = (_) =>
        FakeGateway.json(japan);
    g.services['/v1/shared-trips/7K2M9QXD/adapt'] = (http.Request r) {
      asked.add(jsonDecode(r.body) as Map<String, Object?>);
      return FakeGateway.json(<String, Object?>{
        'items': <Object?>[
          adapted(
            'Vuelo con escala en Estambul',
            69000,
            'Vuelo directo Madrid-Tokio',
            98000,
          ),
          <String, Object?>{
            ...line('stay', 'Hotel cápsula premium en Ueno', 45000),
            'was_title': 'Hotel en Shinjuku, 9 noches',
            'was_price_minor': 81000,
          },
          <String, Object?>{
            ...line('transport', 'JR Pass de 7 días', 38000),
            'was_title': 'JR Pass de 7 días',
            'was_price_minor': 38000,
          },
          <String, Object?>{
            ...line('food', 'Cena en izakaya local', 4000),
            'was_title': 'Cena kaiseki en Kioto',
            'was_price_minor': 15000,
          },
          <String, Object?>{
            ...line('activity', 'Hakone por tu cuenta', 4500),
            'was_title': 'Excursión a Hakone con guía',
            'was_price_minor': 8000,
          },
        ],
        'total_minor': 160500,
        'budget_minor': 180000,
        'fits': true,
        'remaining_today': 9,
      });
    };
    tester.view.physicalSize = const Size(1200, 4000);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await pumpApp(
      tester,
      locale: 'es',
      session: session,
      initialLocation: Routes.copyTrip(),
      services: fakeServices(session, gateway: g, prefs: store),
    );
    await tester.pumpAndSettle();
    expect(find.text('Copia este viaje'), findsOneWidget);
    expect(find.text('Aún no has compartido ningún viaje.'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'abc');
    await tester.tap(find.text('Ver el viaje'));
    await tester.pumpAndSettle();
    expect(find.textContaining('8 letras'), findsOneWidget);

    await tester.enterText(find.byType(TextField), '7k2m-9qxd');
    await tester.tap(find.text('Ver el viaje'));
    await tester.pumpAndSettle();
    expect(find.text('Japón en 10 días'), findsOneWidget);
    expect(find.text('Igual que el original'), findsNWidgets(5));

    await tester.tap(find.byType(ChoiceChip).at(1));
    await tester.pumpAndSettle();
    expect(asked.single, <String, Object?>{
      'budget_minor': 180000,
      'language': 'es',
    });
    expect(find.text('Vuelo con escala en Estambul'), findsOneWidget);
    expect(find.textContaining('4 cambios para que quepa en'), findsOneWidget);

    await tester.tap(find.text('Copiar a mis viajes'));
    await tester.pumpAndSettle();
    expect(find.text('Copiado en tus viajes'), findsOneWidget);
    expect(g.calls, contains('POST /v1/shared-trips/7K2M9QXD/copy'));
    final CopiedTrip saved = CopiedTrips(store).all().single;
    expect(saved.totalMinor, 160500);
    expect(saved.lines.first.title, 'Vuelo con escala en Estambul');
  });

  testWidgets('compartir mi viaje: líneas, código y vuelta', (
    WidgetTester tester,
  ) async {
    final FakeGateway g = FakeGateway();
    final SessionController session = await signedInSession(g);
    Map<String, Object?>? sent;
    g.services['/v1/shared-trips/mine'] = (_) =>
        FakeGateway.json(<String, Object?>{'items': <Object?>[]});
    g.services['/v1/shared-trips'] = (http.Request r) {
      sent = jsonDecode(r.body) as Map<String, Object?>;
      return FakeGateway.json(<String, Object?>{
        ...japan,
        'title': sent!['title'],
        'items': sent!['items'],
        'mine': true,
        'copies': 0,
      }, 201);
    };
    tester.view.physicalSize = const Size(1200, 4000);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await pumpApp(
      tester,
      locale: 'es',
      session: session,
      initialLocation: Routes.copyTrip(),
      services: fakeServices(session, gateway: g),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Compartir y obtener el código'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Rellena el título'), findsOneWidget);

    await tester.enterText(
      find.widgetWithText(TextField, 'Título (p. ej. Japón en 10 días)'),
      'Roma en 3 días',
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Nombre que verán los demás'),
      'dario',
    );
    await tester.enterText(find.widgetWithText(TextField, 'Destino'), 'Roma');
    await tester.tap(find.text('Añadir algo que pagaste'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ChoiceChip, 'Alojamiento'));
    await tester.enterText(
      find.widgetWithText(
        TextField,
        'Qué fue (p. ej. Vuelo con escala en Estambul)',
      ),
      'Hotel Trastevere',
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Precio (EUR)'),
      '240',
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Guardar'));
    await tester.pumpAndSettle();
    expect(find.text('Hotel Trastevere'), findsOneWidget);

    await tester.tap(find.text('Compartir y obtener el código'));
    await tester.pumpAndSettle();
    expect(sent!['items'], <Object?>[line('stay', 'Hotel Trastevere', 24000)]);
    expect(sent!['days'], 7);
    expect(find.text('7K2M-9QXD'), findsOneWidget);
    await tester.tap(find.text('Hecho'));
    await tester.pumpAndSettle();
    // De vuelta en Copia este viaje, se vuelven a pedir "los míos".
    expect(find.text('Copia este viaje'), findsOneWidget);
    expect(
      g.calls.where((String c) => c == 'GET /v1/shared-trips/mine'),
      hasLength(2),
    );
  });
}
