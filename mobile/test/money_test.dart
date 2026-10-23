// Tests de Dinero → Tu dinero (gastos compartidos): leer un ticket, crear un
// bote, apuntar un gasto escaneado, "Saldar" y "esto me lo pedí yo".
// El ai-orchestrator es falso: responde lo que le decimos y apunta lo que
// la app le manda.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:nomadiq/auth/session.dart';
import 'package:nomadiq/core/api_client.dart';
import 'package:nomadiq/core/router.dart';
import 'package:nomadiq/features/money/expenses_api.dart';
import 'package:nomadiq/features/money/receipt_parser.dart';
import 'package:nomadiq/features/money/receipt_scanner.dart';

import 'helpers.dart';

const String groupId = '0b6a7c1e-1111-4222-8333-444455556666';
const String expenseId = '9d1e2f3a-aaaa-4bbb-8ccc-ddddeeeeffff';
const String base = '/v1/expense-groups';

/// El ticket de la maqueta, tal y como lo "lee" el móvil (con ruido).
const List<String> mockupTicket = <String>[
  'LL',
  '[NOMBRE DEL LOCAL]',
  'C/ Ejemplo, 12 · 28005 Madrid',
  'NIF B00000000 · Tel. 900 000 000',
  'FACTURA SIMPLIFICADA',
  'Nº FS-2026-004817 Caja 02 22/10/2026 22:47',
  'UDS ARTÍCULO IMPORTE',
  '2 Croquetas  12,00',
  '1 Tortilla  12,00',
  '1 Secreto ibérico  17,75',
  '4 Vino tinto copa  14,00',
  '1 Pulpo a feira  18,50',
  '4 Caña  11,75',
  'BASE IMPONIBLE 78,18',
  'IVA 10 % 7,82',
  'TOTAL  86,00 EUR',
  'TARJETA ****0000 86,00',
  '¡GRACIAS POR SU VISITA!',
];

Map<String, Object?> expenseJson({
  String split = 'items',
  List<int> claimed = const <int>[],
}) => <String, Object?>{
  'expense_id': expenseId,
  'title': 'Cena en La Latina',
  'amount_minor': 8600,
  'payer_seat': 2,
  'split': split,
  'participants': <int>[1, 2],
  'items': <Object?>[
    <String, Object?>{
      'name': 'Croquetas',
      'qty': 2,
      'price_minor': 1200,
      'claimed_by': claimed,
    },
    <String, Object?>{
      'name': 'Pulpo a feira',
      'qty': 1,
      'price_minor': 1850,
      'claimed_by': <int>[2],
    },
  ],
  'shares': <Object?>[
    <String, Object?>{'seat': 1, 'amount_minor': 4300},
    <String, Object?>{'seat': 2, 'amount_minor': 4300},
  ],
  'spent_on': '2026-10-22',
  'created_by': 2,
  'created_at': '2026-10-22T22:50:00Z',
  'original_minor': null,
  'original_currency': null,
};

Map<String, Object?> groupJson({bool withExpense = true}) => <String, Object?>{
  'group_id': groupId,
  'title': 'Madrid',
  'currency': 'EUR',
  'invite_code': '7K2M9QXD',
  'my_seat': 1,
  'members': <Object?>[
    <String, Object?>{'seat': 1, 'name': 'Darío', 'me': true},
    <String, Object?>{'seat': 2, 'name': 'Álex', 'me': false},
  ],
  'expenses': <Object?>[if (withExpense) expenseJson()],
  'payments': <Object?>[],
  'balances': <Object?>[
    <String, Object?>{'seat': 1, 'balance_minor': withExpense ? -4300 : 0},
    <String, Object?>{'seat': 2, 'balance_minor': withExpense ? 4300 : 0},
  ],
  'transfers': <Object?>[
    if (withExpense)
      <String, Object?>{'from_seat': 1, 'to_seat': 2, 'amount_minor': 4300},
  ],
  'total_minor': withExpense ? 8600 : 0,
};

/// Un ai-orchestrator falso para Gastos.
class MoneyBackend {
  MoneyBackend() {
    g.services[base] = (http.Request r) {
      if (r.method == 'GET') {
        return FakeGateway.json(<String, Object?>{
          'items': <Object?>[
            if (current != null)
              <String, Object?>{
                'group_id': groupId,
                'title': 'Madrid',
                'currency': 'EUR',
                'members': 2,
                'my_balance_minor': -4300,
                'total_minor': 8600,
              },
          ],
        });
      }
      created.add(jsonDecode(r.body) as Map<String, Object?>);
      current = groupJson(withExpense: false);
      return FakeGateway.json(current!, 201);
    };
    g.services['$base/$groupId'] = (http.Request r) =>
        current == null ? http.Response('', 404) : FakeGateway.json(current!);
    g.services['$base/$groupId/expenses'] = (http.Request r) {
      expenses.add(jsonDecode(r.body) as Map<String, Object?>);
      current = groupJson();
      return FakeGateway.json(expenseJson(), 201);
    };
    g.services['$base/$groupId/payments'] = (http.Request r) {
      payments.add(jsonDecode(r.body) as Map<String, Object?>);
      return FakeGateway.json(<String, Object?>{}, 201);
    };
    g.services['$base/$groupId/expenses/$expenseId/items/0/claim'] =
        (http.Request r) {
          claims.add(jsonDecode(r.body) as Map<String, Object?>);
          return FakeGateway.json(expenseJson(claimed: <int>[1]));
        };
  }

  final FakeGateway g = FakeGateway();
  Map<String, Object?>? current;
  final List<Map<String, Object?>> created = <Map<String, Object?>>[];
  final List<Map<String, Object?>> expenses = <Map<String, Object?>>[];
  final List<Map<String, Object?>> payments = <Map<String, Object?>>[];
  final List<Map<String, Object?>> claims = <Map<String, Object?>>[];
}

/// Un escáner de tickets falso que "lee" las filas que le digamos.
class FakeScanner implements ReceiptScanner {
  FakeScanner(this.rows);

  final List<String>? rows;
  final List<ReceiptSource> asked = <ReceiptSource>[];

  @override
  Future<List<String>?> scan(
    ReceiptSource source, {
    String currency = 'EUR',
  }) async {
    asked.add(source);
    return rows;
  }
}

Future<MoneyBackend> pumpMoney(
  WidgetTester tester, {
  String initialLocation = '/money',
  MoneyBackend? backend,
  ReceiptScanner? scanner,
  bool guest = false,
}) async {
  tester.view.physicalSize = const Size(1200, 9000);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  final MoneyBackend b = backend ?? MoneyBackend();
  final SessionController s = guest
      ? (newSession(b.g)..continueAsGuest())
      : await signedInSession(b.g);
  await pumpApp(
    tester,
    locale: 'es',
    session: s,
    initialLocation: initialLocation,
    services: fakeServices(s, gateway: b.g, receipts: scanner),
  );
  return b;
}

void main() {
  group('leer un ticket', () {
    test('el ticket de la maqueta: 6 líneas y el total', () {
      final ParsedReceipt r = parseReceipt(mockupTicket);
      expect(r.totalMinor, 8600);
      expect(r.items.map((TicketItem i) => i.name), <String>[
        'Croquetas',
        'Tortilla',
        'Secreto ibérico',
        'Vino tinto copa',
        'Pulpo a feira',
        'Caña',
      ]);
      expect(r.items.first.qty, 2);
      expect(r.items.first.priceMinor, 1200);
      expect(r.itemsMinor, 8600);
    });

    test('miles, puntos ingleses, yenes y "TOTAL" que no es un plato', () {
      final ParsedReceipt en = parseReceipt(<String>[
        '1 x Burger  1,234.50',
        'Fries 3.5',
        'Subtotal 1,238.00',
        'Tax 10.00',
        'Total due 1,248.00',
      ]);
      expect(en.items.map((TicketItem i) => i.priceMinor), <int>[123450, 350]);
      expect(en.totalMinor, 124800);
      final ParsedReceipt yen = parseReceipt(<String>[
        'ラーメン 1,200',
        '餃子 450',
        '合計 1,650',
      ], digits: 0);
      expect(yen.items.map((TicketItem i) => i.priceMinor), <int>[1200, 450]);
      expect(yen.totalMinor, 1650);
      // "TEL" dentro de "Pastel" no lo confunde con un teléfono.
      expect(
        parseReceipt(<String>['Pastel de queso 5,00']).items,
        hasLength(1),
      );
    });

    test('lo que escribe la persona en el importe', () {
      expect(parseAmount('12,50'), 1250);
      expect(parseAmount('12.5'), 1250);
      expect(parseAmount('1.200'), 120000);
      expect(parseAmount('7'), 700);
      expect(parseAmount('1,200', digits: 0), 1200);
      expect(parseAmount(''), isNull);
      expect(parseAmount('0'), isNull);
      expect(parseAmount('abc'), isNull);
    });
  });

  group('lo que llega del servidor', () {
    test('un bote se lee entero', () {
      final ExpenseGroup g = ExpenseGroup.parse(groupJson());
      expect(g.myBalance, -4300);
      expect(g.myDebts.single.toSeat, 2);
      expect(g.nameOf(2), 'Álex');
      expect(g.expenses.single.split, SplitMode.items);
      expect(g.expenses.single.shares[1], 4300);
    });

    test('lo raro se rechaza en vez de romper la pantalla', () {
      for (final Map<String, Object?> bad in <Map<String, Object?>>[
        groupJson()..['currency'] = 'euros',
        groupJson()..['my_seat'] = 0,
        groupJson()..['members'] = 'muchos',
        groupJson()..['expenses'] = <Object?>[expenseJson(split: 'mitad')],
      ]) {
        expect(
          () => ExpenseGroup.parse(bad),
          throwsA(isA<ApiException>()),
          reason: '$bad',
        );
      }
    });
  });

  testWidgets('el atajo Gastos de Inicio abre Dinero', (
    WidgetTester tester,
  ) async {
    await pumpMoney(tester, initialLocation: Routes.home);
    await tester.tap(find.text('Gastos'));
    await tester.pumpAndSettle();
    expect(find.text('Dinero'), findsOneWidget);
    expect(find.text('Tu dinero'), findsOneWidget);
    expect(find.text('Divisas'), findsOneWidget);
  });

  testWidgets('un invitado ve que necesita cuenta', (
    WidgetTester tester,
  ) async {
    await pumpMoney(tester, guest: true);
    expect(
      find.text('Inicia sesión para compartir gastos con tus amigos.'),
      findsOneWidget,
    );
  });

  testWidgets('crear un bote y apuntar la cena escaneando el ticket', (
    WidgetTester tester,
  ) async {
    final FakeScanner scanner = FakeScanner(mockupTicket);
    final MoneyBackend b = await pumpMoney(tester, scanner: scanner);
    expect(find.textContaining('Aún no tienes botes'), findsOneWidget);

    await tester.tap(find.text('Nuevo bote'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, 'Madrid');
    await tester.enterText(find.byType(TextField).last, 'Darío');
    await tester.tap(find.text('Crear bote'));
    await tester.pumpAndSettle();
    expect(b.created.single, <String, Object?>{
      'title': 'Madrid',
      'currency': 'EUR',
      'my_name': 'Darío',
    });
    expect(find.text('7K2M-9QXD'), findsOneWidget);
    expect(find.text('Estáis en paz'), findsOneWidget);

    await tester.tap(find.text('Añadir gasto'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Escanear el ticket'));
    await tester.pumpAndSettle();
    expect(scanner.asked, <ReceiptSource>[ReceiptSource.camera]);
    expect(find.text('6 líneas leídas del ticket'), findsOneWidget);
    expect(find.text('Croquetas'), findsOneWidget);
    expect(find.text('86.00'), findsOneWidget); // el total ya puesto

    await tester.enterText(find.byType(TextField).first, 'Cena en La Latina');
    await tester.tap(find.text('Guardar gasto'));
    await tester.pumpAndSettle();
    final Map<String, Object?> sent = b.expenses.single;
    expect(sent['title'], 'Cena en La Latina');
    expect(sent['amount_minor'], 8600);
    expect(sent['payer_seat'], 1);
    expect(sent['split'], 'items');
    expect(sent['participants'], <int>[1, 2]);
    expect((sent['items']! as List<Object?>).length, 6);
    // De vuelta en el bote, ya se ve la deuda.
    expect(find.text('Gasto apuntado'), findsOneWidget);
    expect(
      find.textContaining('Le debes a Álex', findRichText: true),
      findsOneWidget,
    );
  });

  testWidgets('saldar con Álex apunta el pago', (WidgetTester tester) async {
    final MoneyBackend b = MoneyBackend()..current = groupJson();
    await pumpMoney(
      tester,
      backend: b,
      initialLocation: Routes.expenseGroup(groupId),
    );
    expect(find.textContaining('Le debes a Álex'), findsOneWidget);
    await tester.tap(find.text('Saldar'));
    await tester.pumpAndSettle();
    expect(find.text('Pagar a Álex'), findsOneWidget);
    expect(find.text('43.00'), findsOneWidget);
    await tester.tap(find.text('Ya le he pagado'));
    await tester.pumpAndSettle();
    expect(b.payments.single, <String, Object?>{
      'to_seat': 2,
      'amount_minor': 4300,
    });
  });

  testWidgets('tocar una línea del ticket: "esto me lo pedí yo"', (
    WidgetTester tester,
  ) async {
    final MoneyBackend b = MoneyBackend()..current = groupJson();
    await pumpMoney(
      tester,
      backend: b,
      initialLocation: Routes.expenseGroup(groupId),
    );
    await tester.tap(find.text('Cena en La Latina'));
    await tester.pumpAndSettle();
    expect(find.text('Todos'), findsOneWidget); // las croquetas, de todos
    await tester.tap(find.text('Croquetas'));
    await tester.pumpAndSettle();
    expect(b.claims.single, <String, Object?>{'claimed': true});
    expect(find.text('Todos'), findsNothing); // ahora son mías
  });
}
