// Inicio: la bola de Flyra (tocar = chat, mantener = hablar), la caja de
// escribir y el carrusel infinito de 19 cuadrados.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:eclipta/core/router.dart';
import 'package:eclipta/features/assistant/interpreter.dart';

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
}
