// Tests del chat con Flyra: preguntar, ver la respuesta, el cupo diario,
// "Flyra ocupada", el modo invitado y que la conversación solo viva en el móvil.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:eclipta/auth/session.dart';
import 'package:eclipta/core/router.dart';
import 'package:eclipta/core/settings.dart';
import 'package:eclipta/features/flyra/flyra_api.dart';

import 'helpers.dart';

const String chatPath = '/v1/flyra/chat';

/// Un ai-orchestrator falso para Flyra: apunta lo que recibe.
class FlyraBackend {
  FlyraBackend() {
    g.services[chatPath] = (http.Request r) {
      sent.add(jsonDecode(r.body) as Map<String, Object?>);
      final int? status = failWith;
      if (status != null) return http.Response('{}', status);
      remaining--;
      return FakeGateway.json(<String, Object?>{
        'reply': 'En Lisboa: Alfama, Belém y un pastel de nata.',
        'remaining_today': remaining,
      });
    };
  }

  final FakeGateway g = FakeGateway();
  final List<Map<String, Object?>> sent = <Map<String, Object?>>[];
  int remaining = 50;
  int? failWith;
}

Future<FlyraBackend> pumpFlyra(
  WidgetTester tester, {
  FlyraBackend? backend,
  MemorySettingsStore? prefs,
  bool guest = false,
}) async {
  tester.view.physicalSize = const Size(1200, 3000);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  final FlyraBackend b = backend ?? FlyraBackend();
  final SessionController s = guest
      ? (newSession(b.g)..continueAsGuest())
      : await signedInSession(b.g);
  await pumpApp(
    tester,
    locale: 'es',
    session: s,
    initialLocation: Routes.flyra(),
    services: fakeServices(s, gateway: b.g, prefs: prefs),
  );
  return b;
}

void main() {
  group('qué se envía', () {
    test('empieza por una pregunta tuya y respeta los límites', () {
      final List<ChatTurn> history = <ChatTurn>[
        for (int i = 0; i < 30; i++) ...<ChatTurn>[
          ChatTurn(ChatRole.user, 'pregunta $i'),
          ChatTurn(ChatRole.flyra, 'respuesta $i'),
        ],
        const ChatTurn(ChatRole.user, '¿y mañana?'),
      ];
      final List<ChatTurn> sent = turnsToSend(history);
      expect(sent.length, lessThanOrEqualTo(maxTurnsSent));
      expect(sent.first.role, ChatRole.user);
      expect(sent.last.text, '¿y mañana?');
    });

    test('el historial guardado sobrevive a datos rotos', () {
      expect(decodeHistory('esto no es json'), isEmpty);
      expect(
        decodeHistory(
          '[{"role":"bot","text":"x"},{"role":"user","text":"hola"}]',
        ).single.text,
        'hola',
      );
      final String saved = encodeHistory(<ChatTurn>[
        for (int i = 0; i < 100; i++) ChatTurn(ChatRole.user, '$i'),
      ]);
      expect(decodeHistory(saved).length, maxTurnsKept);
    });
  });

  testWidgets('preguntar y ver la respuesta (y se guarda en el móvil)', (
    WidgetTester tester,
  ) async {
    final MemorySettingsStore prefs = MemorySettingsStore('es');
    final FlyraBackend b = await pumpFlyra(tester, prefs: prefs);
    expect(find.textContaining('Soy Flyra'), findsOneWidget);

    await tester.enterText(find.byType(TextField), '¿Qué veo en Lisboa?');
    await tester.tap(find.byTooltip('Enviar'));
    await tester.pumpAndSettle();

    expect(find.text('¿Qué veo en Lisboa?'), findsOneWidget);
    expect(find.textContaining('pastel de nata'), findsOneWidget);
    expect(find.textContaining('Te quedan 49 preguntas hoy'), findsOneWidget);
    final Map<String, Object?> body = b.sent.single;
    expect(body['language'], 'es');
    expect(body['messages'], <Object?>[
      <String, Object?>{'role': 'user', 'text': '¿Qué veo en Lisboa?'},
    ]);
    expect(decodeHistory(prefs.flyraChat).length, 2);

    // Borrar: desaparece de la pantalla y del móvil.
    await tester.tap(find.byTooltip('Borrar conversación'));
    await tester.pumpAndSettle();
    expect(find.textContaining('pastel de nata'), findsNothing);
    expect(prefs.flyraChat, isNull);
  });

  testWidgets('una sugerencia se envía al tocarla', (
    WidgetTester tester,
  ) async {
    final FlyraBackend b = await pumpFlyra(tester);
    await tester.tap(find.text('¿Qué puedo ver en 2 días en Lisboa?'));
    await tester.pumpAndSettle();
    expect(b.sent, hasLength(1));
    expect(find.textContaining('pastel de nata'), findsOneWidget);
  });

  testWidgets('sin preguntas hoy: aviso y la caja se bloquea', (
    WidgetTester tester,
  ) async {
    final FlyraBackend b = FlyraBackend()..failWith = 429;
    await pumpFlyra(tester, backend: b);
    await tester.enterText(find.byType(TextField), 'hola');
    await tester.tap(find.byTooltip('Enviar'));
    await tester.pumpAndSettle();
    expect(find.textContaining('preguntas gratis de hoy'), findsOneWidget);
    expect(tester.widget<TextField>(find.byType(TextField)).enabled, isFalse);
  });

  testWidgets('Flyra ocupada: la pregunta vuelve a la caja', (
    WidgetTester tester,
  ) async {
    final FlyraBackend b = FlyraBackend()..failWith = 503;
    await pumpFlyra(tester, backend: b);
    await tester.enterText(find.byType(TextField), 'hola');
    await tester.tap(find.byTooltip('Enviar'));
    await tester.pumpAndSettle();
    expect(find.textContaining('muy ocupada'), findsOneWidget);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      'hola',
    );
  });

  testWidgets('invitado: pide iniciar sesión y no llama al servidor', (
    WidgetTester tester,
  ) async {
    final FlyraBackend b = await pumpFlyra(tester, guest: true);
    expect(find.textContaining('Inicia sesión para hablar'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
    expect(b.sent, isEmpty);
  });

  testWidgets('Inicio abre el chat', (WidgetTester tester) async {
    final FlyraBackend b = FlyraBackend();
    final SessionController s = await signedInSession(b.g);
    await pumpApp(
      tester,
      locale: 'es',
      session: s,
      initialLocation: Routes.home,
      services: fakeServices(s, gateway: b.g),
    );
    await tester.tap(find.bySemanticsLabel('Hablar con Flyra'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Soy Flyra'), findsOneWidget);
  });
}
