// Tests de Dinero → Tu dinero fuera (la maqueta "Dinero"): cajeros (con
// un GPS y un servidor falsos), los cálculos de tarjetas y los gastos del
// viaje.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:eclipta/core/router.dart';
import 'package:eclipta/core/settings.dart';
import 'package:eclipta/features/map/geo.dart';
import 'package:eclipta/features/map/location.dart';
import 'package:eclipta/features/money/atms_api.dart';
import 'package:eclipta/features/money/atms_panel.dart';
import 'package:eclipta/features/money/expenses_api.dart';
import 'package:eclipta/features/money/abroad_view.dart';
import 'package:eclipta/features/money/money_screen.dart';
import 'package:eclipta/features/money/travel_cards.dart';
import 'package:eclipta/features/money/trip_budget.dart';

import 'helpers.dart';
import 'money_test.dart'
    show MoneyBackend, PageSpy, groupId, groupJson, pumpMoney;

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

    test('los cajeros guardados solo valen para la misma zona', () async {
      final MemorySettingsStore prefs = MemorySettingsStore();
      const GeoPoint shibuya = GeoPoint(35.66, 139.7);
      await saveAtmCache(prefs, shibuya, AtmList.parse(atmsJson));
      final (AtmList, DateTime)? back = readAtmCache(
        prefs,
        const GeoPoint(35.67, 139.7),
      );
      expect(back, isNotNull);
      expect(back!.$1.atms.length, 2);
      expect(back.$1.atms.last.name, 'Seven Bank');
      // Osaka está a cientos de km: no sirven.
      expect(readAtmCache(prefs, const GeoPoint(34.69, 135.5)), isNull);
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
    testWidgets('cajeros: con permiso se buscan solos, el más cercano arriba', (
      WidgetTester tester,
    ) async {
      final MoneyBackend b = MoneyBackend();
      final List<Uri> sent = <Uri>[];
      b.g.publicPrefixes.add('/v1/atms');
      b.g.services['/v1/atms'] = (http.Request r) {
        sent.add(r.url);
        return FakeGateway.json(atmsJson);
      };
      final PageSpy spy = PageSpy();
      await pumpMoney(
        tester,
        backend: b,
        location: ShibuyaLocation(),
        webScene: spy.build,
        initialLocation: Routes.money(tab: MoneyTab.abroad),
      );
      await spy.wait(
        tester,
        () =>
            spy.pages.isNotEmpty &&
            (spy.data(AbroadView.lastBridge!)['atms']! as List<Object?>)
                .isNotEmpty,
      );
      // La zona va redondeada (no se manda dónde estás exactamente).
      expect(sent.single.queryParameters, <String, String>{
        'lat': '35.66',
        'lon': '139.70',
      });
      final Map<String, Object?> d = spy.data(AbroadView.lastBridge!);
      final List<Object?> atms = d['atms']! as List<Object?>;
      final Map<String, Object?> first = atms.first! as Map<String, Object?>;
      expect(first['name'], 'Cajero Seven Bank');
      expect(first['fee'], '0 €');
      expect(first['meta'], contains('abierto 24 h'));
      final Map<String, Object?> second = atms.last! as Map<String, Object?>;
      expect(second['name'], 'Cajero Japan Post Bank');
      expect(second['fee'], 'Con comisión');
      expect(second['short'], 'JAP');
      expect(d['atmCount'], 2);
      expect(d['atmNote'], '');
      // "Abrir mapa 3D": el mapa de cajeros de la app.
      spy.send!('map3d');
      await tester.pumpAndSettle();
      expect(find.byType(AtmsPanel), findsOneWidget);
    });

    testWidgets('cajeros: sin permiso lo dice y lo pide al tocar', (
      WidgetTester tester,
    ) async {
      final FakeLocation gps = FakeLocation()
        ..onRequest = LocationAccess.deniedForever;
      final PageSpy spy = PageSpy();
      await pumpMoney(
        tester,
        location: gps,
        webScene: spy.build,
        initialLocation: Routes.money(tab: MoneyTab.abroad),
      );
      await spy.wait(tester, () => spy.pages.isNotEmpty);
      Map<String, Object?> d = spy.data(AbroadView.lastBridge!);
      expect(d['atmBtn'], 'Usar mi ubicación');
      expect(d['atmNote'], contains('ubicación'));
      spy.send!('locate');
      await spy.wait(
        tester,
        () => spy.data(AbroadView.lastBridge!)['atmNote'] != d['atmNote'],
      );
      d = spy.data(AbroadView.lastBridge!);
      expect(d['atmNote'], contains('Activa la ubicación'));
    });

    testWidgets('gastos: elegir el bote del viaje, límite y añadir a mano', (
      WidgetTester tester,
    ) async {
      final MemorySettingsStore prefs = MemorySettingsStore();
      final MoneyBackend b = MoneyBackend()..current = groupJson();
      final PageSpy spy = PageSpy();
      await pumpMoney(
        tester,
        backend: b,
        prefs: prefs,
        webScene: spy.build,
        initialLocation: Routes.money(tab: MoneyTab.abroad),
      );
      await spy.wait(
        tester,
        () => (spy.data(AbroadView.lastBridge!)['trips']! as List<Object?>)
            .isNotEmpty,
      );
      Map<String, Object?> d = spy.data(AbroadView.lastBridge!);
      expect(d['trip'], isNull);
      expect(d['tripNote'], contains('Elige el bote'));
      // "Cambiar" → el bote "Madrid" → tu límite.
      spy.send!('trip:0');
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '100');
      await tester.tap(find.text('Guardar'));
      await spy.wait(
        tester,
        () => spy.data(AbroadView.lastBridge!)['trip'] != null,
      );
      expect(TripBudget.load(prefs)!.limitMinor, 10000);
      d = spy.data(AbroadView.lastBridge!);
      final Map<String, Object?> trip = d['trip']! as Map<String, Object?>;
      expect(trip['limit'], 100);
      // Tu parte de la cena (43 €) ya está gastada.
      expect(trip['spent'], 43);
      expect(trip['head'], startsWith('MADRID · DÍA'));
      expect(
        (trip['recent']! as List<Object?>).first,
        containsPair('name', 'Cena en La Latina'),
      );
      expect((d['trips']! as List<Object?>).first, containsPair('on', true));
      // "Añadir a mano": 12 € de comida, pagado por ti y solo para ti.
      spy.send!(
        'add:0:${base64Url.encode(utf8.encode(jsonEncode(<String, Object?>{'c': 0, 'n': 'Desayuno', 'a': 12}))).replaceAll('=', '')}',
      );
      await spy.wait(tester, () => b.expenses.isNotEmpty);
      expect(b.expenses.single['title'], 'Desayuno');
      expect(b.expenses.single['amount_minor'], 1200);
      expect(b.expenses.single['participants'], <Object?>[1]);
      expect(b.expenses.single['payer_seat'], 1);
      // "Sin viaje activo": deja de contar.
      spy.send!('notrip');
      await spy.wait(
        tester,
        () => spy.data(AbroadView.lastBridge!)['trip'] == null,
      );
      expect(TripBudget.load(prefs), isNull);
    });
  });
}
