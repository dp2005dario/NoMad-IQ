// Tests de lo nuevo de Gastos (maqueta 8): el QR VeriFactu del ticket, el
// descuento, la propina, "Lo que paga cada uno" antes de guardar, el aviso
// "No cuadra con el ticket", "Quién ha marcado qué", "Repartir con la mesa"
// y la hoja de "Saldar" (copiar datos y PayPal.me).
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eclipta/core/router.dart';
import 'package:eclipta/features/money/expenses_api.dart';
import 'package:eclipta/features/money/receipt_parser.dart';
import 'package:eclipta/features/money/settle_sheet.dart';
import 'package:eclipta/features/money/split_preview.dart';

import 'money_test.dart' as m;

const String qr =
    'https://www2.agenciatributaria.gob.es/wlpl/TIKE-CONT/ValidarQR'
    '?nif=B00000000&numserie=FS-2026-004817&fecha=22-10-2026&importe=86.00';

void main() {
  test('el QR VeriFactu: NIF, número, fecha e importe', () {
    final VeriFactu v = parseVeriFactu(qr)!;
    expect(v.nif, 'B00000000');
    expect(v.number, 'FS-2026-004817');
    expect(v.date, DateTime(2026, 10, 22));
    expect(v.totalMinor, 8600);
    expect(parseVeriFactu(qr.replaceFirst('86.00', '9.5'))!.totalMinor, 950);
    // Otros QR (una web cualquiera, http, sin importe) no valen.
    expect(parseVeriFactu('https://example.com/?importe=86.00'), isNull);
    expect(parseVeriFactu(qr.replaceFirst('https', 'http')), isNull);
    expect(parseVeriFactu(qr.replaceFirst('&importe=86.00', '')), isNull);
    expect(parseVeriFactu('hola'), isNull);
  });

  test('el ticket con QR y descuento', () {
    final ParsedReceipt r = parseReceipt(<String>[
      ...m.mockupTicket.take(13),
      'DESCUENTO -5,00',
      'TOTAL 81,00',
    ], qr: qr);
    expect(r.items, hasLength(6));
    expect(r.discountMinor, 500);
    expect(r.totalMinor, 8100);
    // Manda el QR (lo firma el comercio para Hacienda).
    expect(r.trustedTotal, 8600);
    // En yenes no hay QR de Hacienda.
    expect(parseReceipt(m.mockupTicket, digits: 0, qr: qr).veriFactu, isNull);
  });

  test('las cuentas del móvil son las del servidor', () {
    expect(divide(100, <int, int>{1: 1, 2: 1, 3: 1}), <int, int>{
      1: 34,
      2: 33,
      3: 33,
    });
    // Cena de 86 €: croquetas (12) mías, pulpo (18,50) de Álex, el resto de
    // todos. Con 10 % de propina (8,60) se reparte en proporción.
    const List<TicketItem> items = <TicketItem>[
      TicketItem(name: 'Croquetas', priceMinor: 1200, claimedBy: <int>[1]),
      TicketItem(name: 'Pulpo', priceMinor: 1850, claimedBy: <int>[2]),
      TicketItem(name: 'Resto', priceMinor: 5550),
    ];
    expect(tipFor(8600, 10), 860);
    final Map<int, int> s = previewShares(
      amountMinor: 8600 + 860,
      split: SplitMode.items,
      participants: <int>[1, 2],
      items: items,
    );
    expect(s.values.reduce((int a, int b) => a + b), 9460);
    // Empatan a medio céntimo: el céntimo que sobra va al asiento más bajo.
    expect(s, <int, int>{1: 4373, 2: 5087});
    expect(
      previewShares(
        amountMinor: 1000,
        split: SplitMode.weights,
        participants: <int>[1, 2],
        weights: <int>[60, 40],
      ),
      <int, int>{1: 600, 2: 400},
    );
  });

  test('PayPal.me con el importe puesto', () {
    expect(
      paypalMeLink('@alex99', 4300, 'EUR').toString(),
      'https://www.paypal.me/alex99/43.00EUR',
    );
    expect(
      paypalMeLink('ana', 1200, 'JPY').toString(),
      'https://www.paypal.me/ana/1200JPY',
    );
    expect(paypalMeLink('a/b', 100, 'EUR'), isNull);
    expect(paypalMeLink('', 100, 'EUR'), isNull);
  });

  testWidgets('ticket con QR: datos de Hacienda, propina y no cuadra', (
    WidgetTester tester,
  ) async {
    final m.FakeScanner scanner = m.FakeScanner(
      m.mockupTicket,
      qr: qr.replaceFirst('86.00', '90.00'),
    );
    final List<Uri> opened = <Uri>[];
    final m.MoneyBackend b = m.MoneyBackend()
      ..current = m.groupJson(withExpense: false);
    await m.pumpMoney(
      tester,
      backend: b,
      scanner: scanner,
      initialLocation: Routes.expenseGroup(m.groupId),
      openLink: (Uri u) async {
        opened.add(u);
        return true;
      },
    );
    await tester.tap(find.text('Añadir gasto'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Escanear el ticket'));
    await tester.pumpAndSettle();

    // Lo leído del QR, y el total sale del QR (90), no del papel (86).
    expect(find.text('LEÍDO DEL QR VERIFACTU DEL TICKET'), findsOneWidget);
    expect(find.text('FS-2026-004817'), findsOneWidget);
    expect(find.text('90.00'), findsOneWidget);
    await tester.tap(find.text('Comprobar en Hacienda'));
    await tester.pumpAndSettle();
    expect(opened.single.host, 'www2.agenciatributaria.gob.es');

    // Las líneas suman 86 y el QR dice 90: Flyra avisa.
    expect(find.text('No cuadra con el ticket'), findsOneWidget);
    expect(find.textContaining('el QR del ticket dice 90,00'), findsOneWidget);
    await tester.tap(find.text('Usar la suma'));
    await tester.pumpAndSettle();
    expect(find.text('86.00'), findsOneWidget);
    expect(find.text('No cuadra con el ticket'), findsNothing);

    // Propina del 10 %: se suma encima del ticket.
    await tester.tap(find.text('10 %'));
    await tester.pumpAndSettle();
    expect(
      find.text('+8,60\u00a0€ de propina · Total a repartir: 94,60\u00a0€'),
      findsOneWidget,
    );
    // Lo que paga cada uno, antes de guardar (nadie ha marcado: a medias).
    expect(find.text('Lo que paga cada uno'), findsOneWidget);
    // (Los céntimos sueltos de cada línea van al asiento más bajo, como en
    // el servidor.)
    expect(find.text('47,31\u00a0€'), findsOneWidget);
    expect(find.text('47,29\u00a0€'), findsOneWidget);

    await tester.enterText(find.byType(TextField).first, 'Cena');
    await tester.ensureVisible(find.text('Guardar gasto'));
    await tester.tap(find.text('Guardar gasto'));
    await tester.pumpAndSettle();
    expect(b.expenses.single['amount_minor'], 9460);
    expect(b.expenses.single['spent_on'], '2026-10-22'); // la del QR
  });

  testWidgets('quién ha marcado qué y repartir con la mesa', (
    WidgetTester tester,
  ) async {
    final List<String> shared = <String>[];
    final m.MoneyBackend b = m.MoneyBackend()..current = m.groupJson();
    await m.pumpMoney(
      tester,
      backend: b,
      initialLocation: Routes.expenseGroup(m.groupId),
      share: (List<String> _, {String? text}) async => shared.add(text!),
    );
    await tester.tap(find.text('Cena en La Latina'));
    await tester.pumpAndSettle();
    expect(find.text('Quién ha marcado qué'), findsOneWidget);
    expect(find.text('Aún no ha marcado nada'), findsOneWidget); // yo
    expect(find.text('Pulpo a feira'), findsNWidgets(2)); // ticket y Álex
    // El total (86) es más que las líneas (30,50): propina y ajustes.
    expect(find.text('Propina y ajustes'), findsOneWidget);
    await tester.tap(find.text('Mandar al grupo'));
    await tester.pumpAndSettle();
    expect(shared.single, contains('7K2M-9QXD'));
    expect(shared.single, contains('Cena en La Latina'));
    // Actualizar vuelve a pedir el bote.
    await tester.tap(find.byTooltip('Actualizar'));
    await tester.pumpAndSettle();
    expect(find.text('Quién ha marcado qué'), findsOneWidget);
  });

  testWidgets('saldar: copiar datos y PayPal.me', (WidgetTester tester) async {
    final List<Uri> opened = <Uri>[];
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (MethodCall call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map<Object?, Object?>)['text'] as String?;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    final m.MoneyBackend b = m.MoneyBackend()..current = m.groupJson();
    await m.pumpMoney(
      tester,
      backend: b,
      initialLocation: Routes.expenseGroup(m.groupId),
      openLink: (Uri u) async {
        opened.add(u);
        return true;
      },
    );
    await tester.tap(find.text('Saldar'));
    await tester.pumpAndSettle();
    expect(find.text('Pagar a Álex'), findsOneWidget);
    await tester.tap(find.text('Copiar importe y concepto'));
    await tester.pumpAndSettle();
    expect(copied, '43,00\u00a0€ · Madrid');
    expect(find.text('Copiado'), findsOneWidget);
    await tester.enterText(find.byType(TextField).first, 'alex99');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Abrir'));
    await tester.pumpAndSettle();
    expect(opened.single.toString(), 'https://www.paypal.me/alex99/43.00EUR');
    await tester.ensureVisible(find.text('Ya le he pagado'));
    await tester.tap(find.text('Ya le he pagado'));
    await tester.pumpAndSettle();
    expect(b.payments.single, <String, Object?>{
      'to_seat': 2,
      'amount_minor': 4300,
    });
  });
}
