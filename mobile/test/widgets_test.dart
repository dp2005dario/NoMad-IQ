// Widgets del escritorio: las fotos fijas del vuelo, el chollo y el
// presupuesto, el aviso "en directo" y la pantalla Widgets.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:intl/date_symbol_data_local.dart';
import 'package:nomadiq/core/router.dart';
import 'package:nomadiq/core/settings.dart';
import 'package:nomadiq/features/easy/easy_mode.dart';
import 'package:nomadiq/features/flights/fares_api.dart';
import 'package:nomadiq/features/money/trip_budget.dart';
import 'package:nomadiq/features/widgets/home_widgets.dart';
import 'package:nomadiq/features/widgets/widget_snapshots.dart';
import 'package:nomadiq/features/widgets/widget_sync.dart';
import 'package:nomadiq/l10n/generated/app_localizations.dart';

import 'flights_test.dart' show fare;
import 'helpers.dart';
import 'money_test.dart' show groupId, groupJson;

final AppLocalizations es = lookupAppLocalizations(const Locale('es'));

/// MAD → HND el 22 de octubre a las 15:05 (unas 14 h de vuelo calculadas).
final DateTime dep = DateTime(2026, 10, 22, 15, 5);

FlightPlan tokyo({String? gate}) => flightPlanOf(
  EasyTrip(departure: dep, from: 'MAD', to: 'HND', gate: gate),
  testAirports,
)!;

void main() {
  setUpAll(() => initializeDateFormatting());

  test(
    'el widget del vuelo cambia solo: antes, embarque, en vuelo y llegada',
    () {
      final FlightPlan p = tokyo(gate: 'K42');
      final List<WidgetSnapshot> s = flightSnapshots(p, es, 'es');

      expect(pickSnapshot(s, DateTime(2026, 10, 10))!.tag, 'PRÓXIMO VUELO');
      expect(
        pickSnapshot(s, dep.subtract(const Duration(hours: 5)))!.tag,
        'SALES EN 5 H',
      );
      final WidgetSnapshot go = pickSnapshot(
        s,
        dep.subtract(const Duration(hours: 2)),
      )!;
      expect(go.tag, 'EMBARQUE EN 80 MIN');
      expect(go.big, 'K42');
      expect(
        pickSnapshot(s, dep.subtract(const Duration(minutes: 30)))!.tag,
        'EMBARCANDO',
      );

      final DateTime mid = dep.add(p.arrival.difference(dep) ~/ 2);
      final WidgetSnapshot flying = pickSnapshot(s, mid)!;
      expect(flying.tag, startsWith('EN VUELO ·'));
      expect(flying.pct, inInclusiveRange(45, 50));
      expect(flying.small, contains('Tokio'));

      final WidgetSnapshot landed = pickSnapshot(
        s,
        p.arrival.add(const Duration(hours: 1)),
      )!;
      expect(landed.tag, 'HAS LLEGADO A TOKIO');
      // A las 6 h de llegar el widget se queda vacío.
      expect(pickSnapshot(s, p.arrival.add(const Duration(hours: 7))), isNull);
    },
  );

  test('un aeropuerto que no se conoce no da plan', () {
    expect(
      flightPlanOf(
        EasyTrip(departure: dep, from: 'MAD', to: 'XXX'),
        testAirports,
      ),
      isNull,
    );
  });

  test('presupuesto: lo que queda entre los días que faltan', () {
    final TripBudget b = TripBudget(
      potId: groupId,
      limitMinor: 90000,
      start: DateTime(2026, 10, 21),
      end: DateTime(2026, 10, 29),
    );
    final DateTime now = DateTime(2026, 10, 22, 9);
    final List<WidgetSnapshot> s = budgetSnapshots(
      b,
      40000,
      'EUR',
      es,
      'es',
      now,
    );
    final WidgetSnapshot today = pickSnapshot(s, now)!;
    expect(today.title, 'Día 2 de 9');
    // 500 € ÷ 8 días = 62,50 €.
    expect(today.big, contains('62,50'));
    expect(today.small, 'te quedan hoy');
    // Mañana, sin gastar más, toca un poco más al día.
    expect(pickSnapshot(s, DateTime(2026, 10, 23, 9))!.big, contains('71,42'));
    expect(pickSnapshot(s, DateTime(2026, 10, 30, 9)), isNull);

    final WidgetSnapshot over = pickSnapshot(
      budgetSnapshots(b, 95000, 'EUR', es, 'es', now),
      now,
    )!;
    expect(over.small, contains('por encima del presupuesto'));
    expect(over.color, widgetRed);
  });

  test('el chollo caduca a día y medio (un precio viejo engaña)', () {
    final Deal d = Deal.parse(<String, Object?>{
      ...fare('MAD-LIS:2026-12-02:ECONOMY', 3900),
      'usual_minor': 6000,
      'drop_bp': 3500,
    });
    final DateTime now = DateTime(2026, 10, 22, 9);
    final List<WidgetSnapshot> s = dealSnapshots(
      d,
      testAirports,
      es,
      'es',
      now,
    );
    final WidgetSnapshot shown = pickSnapshot(s, now)!;
    expect(shown.title, 'Madrid → Lisboa');
    expect(shown.small, startsWith('-35 %'));
    expect(pickSnapshot(s, now.add(const Duration(hours: 37))), isNull);
  });

  test('poner al día: publica los 3 widgets y programa el aviso', () async {
    final FakeGateway g = FakeGateway();
    g.services['/v1/fares/deals'] = (http.Request r) =>
        FakeGateway.json(<String, Object?>{
          'origin': 'MAD',
          'deals': <Object?>[
            <String, Object?>{
              ...fare('MAD-LIS:2026-12-02:ECONOMY', 3900),
              'usual_minor': 6000,
              'drop_bp': 3500,
            },
          ],
        });
    g.services['/v1/expense-groups/$groupId'] = (_) =>
        FakeGateway.json(groupJson());
    final MemorySettingsStore store = MemorySettingsStore();
    final DateTime future = DateTime.now().add(const Duration(days: 3));
    await saveEasyTrip(
      store,
      EasyTrip(departure: future, from: 'MAD', to: 'HND'),
    );
    final DateTime today = DateTime.now();
    await TripBudget(
      potId: groupId,
      limitMinor: 90000,
      start: DateTime(today.year, today.month, today.day),
      end: DateTime(today.year, today.month, today.day + 8),
    ).save(store);
    final MemoryHomeWidgets widgets = MemoryHomeWidgets();
    final MemoryLiveFlight live = MemoryLiveFlight();
    final session = await signedInSession(g);
    final services = fakeServices(
      session,
      gateway: g,
      prefs: store,
      homeWidgets: widgets,
      liveFlight: live,
    );

    await syncWidgets(services, es, 'es');
    expect(widgets.data[HomeWidgetKind.flight], isNotEmpty);
    expect(
      pickSnapshot(widgets.data[HomeWidgetKind.deal]!, DateTime.now())!.big,
      contains('39'),
    );
    expect(
      pickSnapshot(widgets.data[HomeWidgetKind.budget]!, DateTime.now())!.title,
      'Día 1 de 9',
    );
    expect(
      live.steps.map((LiveStep s) => s.title).first,
      startsWith('Hora de ir'),
    );
    expect(live.steps.last.title, '¡Bienvenido a Tokio!');
    expect(live.steps[2].quiet, isTrue);

    // Sin aviso en directo: se quita lo programado.
    await setLiveFlight(store, false);
    await syncWidgets(services, es, 'es');
    expect(live.steps, isEmpty);
  });

  testWidgets(
    'pantalla Widgets: vista previa por momentos y añadir al escritorio',
    (WidgetTester tester) async {
      final MemorySettingsStore store = MemorySettingsStore('es');
      await saveEasyTrip(
        store,
        EasyTrip(
          departure: DateTime.now().add(const Duration(days: 2)),
          from: 'MAD',
          to: 'HND',
          gate: 'K42',
        ),
      );
      final MemoryHomeWidgets widgets = MemoryHomeWidgets();
      final session = newSession()..continueAsGuest();
      tester.view.physicalSize = const Size(1200, 5000);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      await pumpApp(
        tester,
        locale: 'es',
        session: session,
        initialLocation: Routes.widgets,
        services: fakeServices(session, prefs: store, homeWidgets: widgets),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('Madrid → Tokio ·'), findsOneWidget);
      expect(find.text('EMBARQUE EN 80 MIN'), findsOneWidget);
      expect(find.text('Embarcando · puerta K42'), findsNothing);

      await tester.tap(find.text('En vuelo'));
      await tester.pumpAndSettle();
      expect(find.textContaining('EN VUELO ·'), findsOneWidget);
      expect(find.text('En vuelo · Madrid → Tokio'), findsOneWidget);

      await tester.tap(find.text('Aterrizado'));
      await tester.pumpAndSettle();
      expect(find.text('HAS LLEGADO A TOKIO'), findsOneWidget);

      await tester.tap(find.text('Añadir al escritorio').first);
      await tester.pumpAndSettle();
      expect(widgets.pinned, <HomeWidgetKind>[HomeWidgetKind.flight]);
    },
  );
}
