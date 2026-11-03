// Inicio: la bola de Flyra (tocar = chat, mantener = hablar), la caja de
// escribir y el carrusel infinito de 19 cuadrados.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:eclipta/core/router.dart';
import 'package:eclipta/features/assistant/interpreter.dart';
import 'package:eclipta/features/sos/sos_screen.dart';

import 'helpers.dart';

/// Un micro de mentira que "oye" una frase.
class HeardMic implements SpeechInput {
  final List<String> langs = <String>[];

  @override
  Future<String?> listen(String lang) async {
    langs.add(lang);
    return '¿Qué visito hoy?';
  }

  @override
  Future<void> stop() async {}
}

void main() {
  testWidgets('mantener pulsada a Flyra le habla y abre el chat', (
    WidgetTester tester,
  ) async {
    final HeardMic mic = HeardMic();
    final session = await signedInSession(FakeGateway());
    tester.view.physicalSize = const Size(1200, 3000);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await pumpApp(
      tester,
      locale: 'es',
      session: session,
      initialLocation: Routes.home,
      services: fakeServices(session, speechInput: mic),
    );
    await tester.pumpAndSettle();
    expect(find.text('Mantén pulsado para hablar'), findsOneWidget);
    await tester.longPress(find.bySemanticsLabel('Hablar con Flyra'));
    await tester.pumpAndSettle();
    expect(mic.langs, <String>['es']);
    // La pregunta oída llega escrita a la caja del chat.
    expect(find.text('¿Qué visito hoy?'), findsOneWidget);
  });

  testWidgets('el carrusel da la vuelta y un toque centra, otro abre', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 3000);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await pumpApp(tester, locale: 'es', initialLocation: Routes.home);
    await tester.pumpAndSettle();
    expect(find.text('Explorar'), findsOneWidget);
    expect(find.text('Lugares y planes cerca'), findsOneWidget);
    // Hacia atrás desde el primero aparece el último (es infinito).
    await tester.drag(find.byType(PageView), const Offset(300, 0));
    await tester.pumpAndSettle();
    expect(find.text('Cambia el idioma'), findsOneWidget);
  });

  testWidgets('SOS: mantener 2 s, cuenta atrás, CANCELAR y luego avisar', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 3000);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await pumpApp(tester, locale: 'es', initialLocation: Routes.home);
    await tester.pumpAndSettle();
    final Finder room = find.byKey(const ValueKey<String>('homeSosHold'));
    await tester.scrollUntilVisible(
      room,
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();

    // Soltar antes de 2 s no hace nada.
    TestGesture finger = await tester.startGesture(tester.getCenter(room));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await finger.up();
    await tester.pumpAndSettle();
    expect(find.text('CANCELAR'), findsNothing);

    // Mantener 2 s: cuenta atrás con CANCELAR.
    finger = await tester.startGesture(tester.getCenter(room));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 2100));
    await finger.up();
    await tester.pump();
    expect(find.text('CANCELAR'), findsOneWidget);
    await tester.tap(find.text('CANCELAR'));
    await tester.pumpAndSettle();
    expect(find.text('CANCELAR'), findsNothing);

    // Otra vez, y esta vez se deja llegar a 0: se abre el SOS activado.
    finger = await tester.startGesture(tester.getCenter(room));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 2100));
    await finger.up();
    for (int i = 0; i < 6; i++) {
      await tester.pump(const Duration(seconds: 1));
    }
    await tester.pumpAndSettle();
    expect(
      find.byWidgetPredicate((Widget w) => w is SosScreen && w.armed),
      findsOneWidget,
    );
    // La pantalla SOS espera al GPS hasta 15 s: se deja terminar.
    await tester.pump(const Duration(seconds: 16));
  });
}
