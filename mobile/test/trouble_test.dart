// Si algo falla: plazos de la maleta, la carta y la escala perdida.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nomadiq/core/router.dart';
import 'package:nomadiq/core/settings.dart';
import 'package:nomadiq/features/trouble/bag_claim.dart';

import 'helpers.dart';

void main() {
  final DateTime landed = DateTime(2026, 10, 1);

  test('los plazos del Convenio de Montreal', () {
    expect(deadlineOf(const BagClaim()), isNull);
    final BagClaim waiting = BagClaim(arrived: landed);
    expect(deadlineOf(waiting)!.kind, DeadlineKind.lostFrom);
    expect(deadlineOf(waiting)!.date, DateTime(2026, 10, 22));
    final BagClaim late = waiting.copyWith(delivered: DateTime(2026, 10, 4));
    expect(deadlineOf(late)!.kind, DeadlineKind.delayed);
    expect(deadlineOf(late)!.date, DateTime(2026, 10, 25));
    final BagClaim broken = late.copyWith(problem: BagProblem.damaged);
    expect(deadlineOf(broken)!.date, DateTime(2026, 10, 11));
    expect(deadlineOf(late)!.daysLeft(DateTime(2026, 10, 20)), 5);

    // Se guarda y se vuelve a leer igual.
    final BagClaim again = BagClaim.parse(
      '{"problem":"damaged","reference":"MADIB1","done":[0,2],"arrived":"2026-10-01T00:00:00.000"}',
    );
    expect(again.problem, BagProblem.damaged);
    expect(again.done, <int>{0, 2});
    expect(BagClaim.parse('nope').reference, '');
  });

  test('la carta: perdida a los 21 días, con el enlace del AirTag', () {
    final BagClaim c = BagClaim(
      arrived: landed,
      reference: 'MADIB12345',
      tag: 'IB 123456',
      flight: 'IB3170',
      trackerLink: 'https://found.apple.com/x',
      spent: '85 €',
    );
    final String early = bagLetter(
      c,
      name: 'Dario',
      now: DateTime(2026, 10, 3),
    );
    expect(early, contains('has not been delivered yet'));
    expect(early, contains('MADIB12345'));
    expect(early, contains('https://found.apple.com/x'));
    final String lost = bagLetter(
      c,
      name: 'Dario',
      now: DateTime(2026, 10, 23),
    );
    expect(lost, contains('considered lost'));
    final Uri mail = bagEmail(c, name: 'Dario', now: DateTime(2026, 10, 3));
    expect(mail.scheme, 'mailto');
    expect(mail.toString(), isNot(contains('+')));
  });

  testWidgets('maleta: pasos y carta; escala: buscar el siguiente vuelo', (
    WidgetTester tester,
  ) async {
    final List<Uri> opened = <Uri>[];
    final MemorySettingsStore prefs = MemorySettingsStore()
      ..groupName = 'Dario';
    final session = newSession()..continueAsGuest();
    tester.view.physicalSize = const Size(1200, 5000);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await pumpApp(
      tester,
      locale: 'es',
      session: session,
      initialLocation: Routes.trouble,
      services: fakeServices(
        session,
        prefs: prefs,
        openBooking: (Uri u) async {
          opened.add(u);
          return true;
        },
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.text('Pon el día que aterrizaste para calcular tu plazo.'),
      findsOneWidget,
    );
    await tester.tap(find.byType(CheckboxListTile).first);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, 'Referencia del parte (PIR)'),
      'madib12345',
    );
    await tester.tap(find.text('Escribir la reclamación'));
    await tester.pumpAndSettle();
    expect(opened.single.scheme, 'mailto');
    expect(Uri.decodeComponent(opened.single.query), contains('MADIB12345'));
    // Guardado solo en el móvil.
    final BagClaim saved = BagClaim.parse(prefs.readData(LocalData.bagClaim));
    expect(saved.reference, 'MADIB12345');
    expect(saved.done, <int>{0});

    await tester.tap(find.text('Escala perdida'));
    await tester.pumpAndSettle();
    expect(find.text('No compres otro billete'), findsOneWidget);
    await tester.tap(find.text('Todo en una sola reserva'));
    await tester.pumpAndSettle();
    expect(find.text('Nadie está obligado a reubicarte'), findsOneWidget);
    await tester.enterText(
      find.widgetWithText(TextField, 'Dónde estás (aeropuerto)'),
      'fra',
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Destino final'),
      'hnd',
    );
    await tester.pump();
    await tester.tap(find.text('Buscar vuelos de hoy'));
    await tester.pumpAndSettle();
    expect(find.text('Escala perdida'), findsNothing);
  });
}
