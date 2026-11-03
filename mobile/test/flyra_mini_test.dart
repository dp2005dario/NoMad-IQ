// La mini Flyra de la esquina: solo avisos reales (internet, push, errores).
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:eclipta/core/router.dart';
import 'package:eclipta/features/flyra/flyra_chat_screen.dart';
import 'package:eclipta/features/flyra/flyra_mini.dart';

import 'helpers.dart';

void main() {
  testWidgets('avisa cuando se va y vuelve internet, y al tocarla lo repite', (
    WidgetTester tester,
  ) async {
    final StreamController<bool> net = StreamController<bool>();
    addTearDown(net.close);
    final session = newSession()..continueAsGuest();
    await pumpApp(
      tester,
      locale: 'es',
      session: session,
      initialLocation: Routes.home,
      services: fakeServices(session, onlineChanges: () => net.stream),
    );
    const String offline = 'Sin conexión a internet. Reintentando…';
    // Al abrir con internet, nada que decir.
    net.add(true);
    await tester.pump();
    expect(find.text(offline), findsNothing);

    net.add(false);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text(offline), findsOneWidget);
    // A los 4 s se esconde el bocadillo; tocar la bolita lo saca otra vez.
    await tester.pump(const Duration(seconds: 5));
    await tester.tap(find.byKey(FlyraMini.orbKey));
    await tester.pump(const Duration(milliseconds: 400));
    expect(FlyraNotes.instance.count, 1);

    net.add(true);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Ya tienes conexión otra vez.'), findsOneWidget);
    await tester.pumpAndSettle(const Duration(seconds: 5));
  });

  testWidgets('sin avisos, tocarla abre el chat con Flyra', (
    WidgetTester tester,
  ) async {
    final session = newSession()..continueAsGuest();
    await pumpApp(
      tester,
      locale: 'es',
      session: session,
      initialLocation: Routes.home,
    );
    await tester.tap(find.byKey(FlyraMini.orbKey));
    await tester.pumpAndSettle();
    expect(FlyraNotes.instance.last, isNull);
    expect(find.byType(FlyraChatScreen), findsOneWidget);
  });
}
