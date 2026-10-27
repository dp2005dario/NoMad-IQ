// Tests de Dinero → Tu dinero fuera: cajeros (con un GPS y un servidor
// falsos), tarjetas (guardadas solo en el móvil) y el presupuesto.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:eclipta/core/router.dart';
import 'package:eclipta/core/settings.dart';
import 'package:eclipta/features/map/geo.dart';
import 'package:eclipta/features/map/location.dart';
import 'package:eclipta/features/money/atms_api.dart';
import 'package:eclipta/features/money/expenses_api.dart';
import 'package:eclipta/features/money/insurance_panel.dart';
import 'package:eclipta/features/money/money_screen.dart';
import 'package:eclipta/features/money/travel_cards.dart';
import 'package:eclipta/features/money/trip_budget.dart';

import 'helpers.dart';
import 'money_test.dart' show MoneyBackend, groupId, groupJson, pumpMoney;

/// Un GPS con permiso que da el cruce de Shibuya.
class ShibuyaLocation extends FakeLocation {
  ShibuyaLocation() {
    access = LocationAccess.granted;
  }

  @override
  Stream<PositionFix> watch({TrackingNotice? background}) =>
      Stream<PositionFix>.value(
        PositionFix(
          point: const GeoPoint(35.65949, 139.70051),
          accuracyM: 10,
          recordedAt: DateTime.utc(2026, 10, 23),
        ),
      );
}

const Map<String, Object?> atmsJson = <String, Object?>{
  'lat': 35.66,
  'lon': 139.7,
  'attribution': '© OpenStreetMap contributors (ODbL)',
  'license_url': 'https://www.openstreetmap.org/copyright',
  'atms': <Object?>[
    <String, Object?>{
      'id': 'w7',
      'lat': 35.662,
      'lon': 139.703,
      'name': null,
      'operator': 'Japan Post Bank',
      'opening_hours': 'Mo-Fr 08:00-21:00',
      'open_24h': false,
      'fee': true,
      'in_bank': true,
      'currencies': <Object?>[],
    },
    <String, Object?>{
      'id': 'n1',
      'lat': 35.6596,
      'lon': 139.7006,
      'name': 'Seven Bank',
      'operator': null,
      'opening_hours': '24/7',
      'open_24h': true,
      'fee': false,
      'in_bank': false,
      'currencies': <Object?>['JPY'],
    },
  ],
};

Map<String, Object?> sentCards(MemorySettingsStore prefs) =>
    jsonDecode(prefs.readData(LocalData.travelCards)!) as Map<String, Object?>;

void main() {
  group('cálculos', () {
    test('coste de una tarjeta: pagar 3 %, sacar 2,5 % + 3 €', () {
      const TravelCard debit = TravelCard(
        name: 'Débito',
        payPct: 3,
        atmPct: 2.5,
        atmFixedMinor: 300,
      );
      const SpendPlan plan = SpendPlan(
        currency: 'EUR',
        spendMinor: 140000,
        cashPct: 20,
      );
      // 1.120 € pagando (33,60) + 280 € sacando (7,00) + 2 veces 3 €.
      expect(tripCost(debit, plan, 2), 4660);
      const TravelCard free = TravelCard(
        name: 'Viaje',
        payPct: 0,
        atmPct: 0,
        atmFixedMinor: 0,
      );
      expect(
        const Wallet(cards: <TravelCard>[debit, free], plan: plan).best(2),
        1,
      );
    });

    test('las tarjetas raras no se cargan', () {
      expect(
        TravelCard.parse(<String, Object?>{
          'name': 'X',
          'last4': '12345',
          'pay_pct': 1,
          'atm_pct': 1,
          'atm_fixed_minor': 0,
        }),
        isNull,
      );
      expect(
        TravelCard.parse(<String, Object?>{
          'name': 'X',
          'pay_pct': 50,
          'atm_pct': 1,
          'atm_fixed_minor': 0,
        }),
        isNull,
      );
    });

    test('previsión: día 4 de 9 con 790 € gastados', () {
      final TripBudget b = TripBudget(
        potId: groupId,
        limitMinor: 140000,
        start: DateTime(2026, 10, 20),
        end: DateTime(2026, 10, 28),
      );
      Map<String, Object?> spend(String day, int mine) => <String, Object?>{
        ...(groupJson()['expenses']! as List<Object?>).single!
            as Map<String, Object?>,
        'spent_on': day,
        'shares': <Object?>[
          <String, Object?>{'seat': 1, 'amount_minor': mine},
          <String, Object?>{'seat': 2, 'amount_minor': 100},
        ],
      };
      final ExpenseGroup pot = ExpenseGroup.parse(
        groupJson()
          ..['expenses'] = <Object?>[
            spend('2026-10-15', 19000), // antes del viaje: cuenta el día 1
            spend('2026-10-21', 19000),
            spend('2026-10-22', 22000),
            spend('2026-10-23', 19000),
          ],
      );
      final BudgetForecast f = forecast(b, pot, DateTime(2026, 10, 23, 18));
      expect(f.day, 4);
      expect(f.days, 9);
      expect(f.cumulative, <int>[19000, 38000, 60000, 79000]);
      expect(f.perDayMinor, 19750);
      // Seguir igual: 790 + 5 días × 197,50 = 1.777,50 €.
      expect(f.endings.first, 79000 + 19750 * 5);
      expect(f.endings.last, 79000 + 9875 * 5);
    });

    test('los cajeros se ordenan por distancia', () {
      final AtmList list = AtmList.parse(atmsJson);
      expect(
        list.sortedFrom(const GeoPoint(35.65949, 139.70051)).first.name,
        'Seven Bank',
      );
      expect(
        list.atms.first.mapUrl.toString(),
        'https://www.openstreetmap.org/?mlat=35.66200&mlon=139.70300#map=18/35.66200/139.70300',
      );
    });
  });

  group('pantallas', () {
    testWidgets('buscar cajeros: zona redondeada y el más cercano arriba', (
      WidgetTester tester,
    ) async {
      final MoneyBackend b = MoneyBackend();
      final List<Uri> sent = <Uri>[];
      final List<Uri> opened = <Uri>[];
      b.g.publicPrefixes.add('/v1/atms');
      b.g.services['/v1/atms'] = (http.Request r) {
        sent.add(r.url);
        return FakeGateway.json(atmsJson);
      };
      await pumpMoney(
        tester,
        backend: b,
        location: ShibuyaLocation(),
        openBooking: (Uri u) async {
          opened.add(u);
          return true;
        },
        initialLocation: Routes.money(tab: MoneyTab.abroad),
      );
      expect(find.textContaining('di que no'), findsOneWidget);
      await tester.tap(find.text('Buscar cajeros cerca'));
      await tester.pumpAndSettle();
      expect(sent.single.queryParameters, <String, String>{
        'lat': '35.66',
        'lon': '139.70',
      });
      final Offset seven = tester.getTopLeft(find.text('Seven Bank'));
      final Offset post = tester.getTopLeft(find.text('Japan Post Bank'));
      expect(seven.dy, lessThan(post.dy));
      expect(find.text('Sin comisión'), findsOneWidget);
      expect(find.text('Cobra comisión'), findsOneWidget);
      expect(find.textContaining('Abierto 24 h'), findsOneWidget);
      await tester.tap(find.text('Seven Bank'));
      await tester.pumpAndSettle();
      expect(opened.single.host, 'www.openstreetmap.org');
    });

    testWidgets('dos tarjetas: la más barata sale "MEJOR AQUÍ"', (
      WidgetTester tester,
    ) async {
      final MemorySettingsStore prefs = MemorySettingsStore();
      await pumpMoney(
        tester,
        prefs: prefs,
        initialLocation: Routes.money(tab: MoneyTab.abroad),
      );
      await tester.tap(find.text('Tarjetas'));
      await tester.pumpAndSettle();
      Future<void> add(String name, String last4, String pay) async {
        await tester.tap(find.text('Añadir tarjeta'));
        await tester.pumpAndSettle();
        final Finder fields = find.descendant(
          of: find.byType(AlertDialog),
          matching: find.byType(TextField),
        );
        await tester.enterText(fields.at(0), name);
        await tester.enterText(fields.at(1), last4);
        await tester.enterText(fields.at(2), pay);
        await tester.enterText(fields.at(3), pay);
        await tester.tap(find.text('Guardar'));
        await tester.pumpAndSettle();
      }

      await add('Débito', '4821', '3');
      await add('Crédito viaje', '0937', '0');
      expect(find.text('MEJOR AQUÍ'), findsOneWidget);
      expect(find.text('•••• 4821'), findsOneWidget);
      expect(find.textContaining('«Crédito viaje»'), findsOneWidget);
      final Map<String, Object?> saved = sentCards(prefs);
      expect((saved['cards']! as List<Object?>).length, 2);
      expect(
        ((saved['cards']! as List<Object?>).first!
            as Map<String, Object?>)['last4'],
        '4821',
      );
    });

    testWidgets('presupuesto: elegir bote, límite y ver la previsión', (
      WidgetTester tester,
    ) async {
      final MemorySettingsStore prefs = MemorySettingsStore();
      final MoneyBackend b = MoneyBackend()..current = groupJson();
      await pumpMoney(
        tester,
        backend: b,
        prefs: prefs,
        initialLocation: Routes.money(tab: MoneyTab.abroad),
      );
      await tester.tap(find.text('Presupuesto'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '100');
      await tester.tap(find.text('Guardar'));
      await tester.pumpAndSettle();
      expect(TripBudget.load(prefs)!.limitMinor, 10000);
      // Tu parte de la cena (43 €) ya está gastada.
      expect(find.textContaining('PRESUPUESTO 100,00'), findsOneWidget);
      expect(find.text('Sigo igual'), findsOneWidget);
      expect(find.text('Cambiar presupuesto'), findsOneWidget);
    });

    testWidgets('seguro: explica que vive en la Bóveda', (
      WidgetTester tester,
    ) async {
      await pumpMoney(
        tester,
        initialLocation: Routes.money(tab: MoneyTab.abroad),
      );
      await tester.tap(find.text('Seguro'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Bóveda'), findsWidgets);
      expect(find.byType(InsurancePanel), findsOneWidget);
    });
  });
}
