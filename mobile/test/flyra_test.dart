// Tests del chat con Flyra: preguntar, ver la respuesta, el cupo diario,
// "Flyra ocupada", el modo invitado y que la conversación solo viva en el móvil.
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:eclipta/features/flyra/flyra_chat_screen.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:eclipta/core/api_client.dart';
import 'package:eclipta/auth/session.dart';
import 'package:eclipta/core/router.dart';
import 'package:eclipta/core/settings.dart';
import 'package:eclipta/features/assistant/interpreter.dart';
import 'package:eclipta/features/camera/speaker.dart';
import 'package:eclipta/features/flyra/flyra_api.dart';

import 'money_test.dart' as m;
import 'helpers.dart';

const String chatPath = '/v1/flyra/chat';

/// Una voz de mentira: apunta lo que "lee" y en qué idioma.
class SaidSpeaker implements Speaker {
  final List<String> said = <String>[];

  @override
  Future<void> speak(String text, String language) async =>
      said.add('$language:$text');

  @override
  Future<void> stop() async {}
}

/// Un micro de mentira que "oye" siempre la misma frase.
class OneMic implements SpeechInput {
  OneMic(this.phrase);

  final String phrase;
  final List<String> langs = <String>[];

  @override
  Future<String?> listen(String lang, {ValueChanged<String>? onPartial}) async {
    langs.add(lang);
    return phrase;
  }

  @override
  Future<void> stop() async {}

  @override
  ValueListenable<double> get level => ValueNotifier<double>(0);
}

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
  Speaker? speaker,
  SpeechInput? speechInput,
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
    services: fakeServices(
      s,
      gateway: b.g,
      prefs: prefs,
      speaker: speaker,
      speechInput: speechInput,
    ),
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

  group('esperar a la IA', () {
    // Un servidor que tarda en contestar (como Gemini con una respuesta larga).
    Future<ApiClient> slowApi(Duration delay) async => ApiClient(
      baseUrl: Uri.parse('http://gateway.test'),
      session: await signedInSession(FakeGateway()),
      timeout: const Duration(milliseconds: 50),
      client: MockClient((http.Request r) async {
        await Future<void>.delayed(delay);
        return http.Response(
          jsonEncode(<String, Object?>{'reply': 'hola', 'remaining_today': 3}),
          200,
          headers: <String, String>{'content-type': 'application/json'},
        );
      }),
    );

    test('Flyra espera más que las demás llamadas', () async {
      final ApiClient api = await slowApi(const Duration(milliseconds: 200));
      final FlyraReply reply = await FlyraApi(api).ask(const <ChatTurn>[
        ChatTurn(ChatRole.user, '¿Qué eres?'),
      ], language: 'es');
      expect(reply.text, 'hola');
    });

    test('si el servidor no contesta a tiempo NO es "sin conexión"', () async {
      final ApiClient api = await slowApi(const Duration(milliseconds: 200));
      await expectLater(
        api.getJson('/v1/lo-que-sea'),
        throwsA(
          isA<ApiException>().having(
            (ApiException e) => e.error,
            'error',
            ApiError.unavailable,
          ),
        ),
      );
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

  testWidgets('dictar con el micro, ver a Flyra teclear y escucharla', (
    WidgetTester tester,
  ) async {
    final SaidSpeaker voice = SaidSpeaker();
    final OneMic mic = OneMic('¿Qué veo en Lisboa?');
    final FlyraBackend b = await pumpFlyra(
      tester,
      speaker: voice,
      speechInput: mic,
    );

    // El micro escribe en la caja lo oído (no lo envía solo).
    await tester.tap(find.byTooltip('Hablar'));
    await tester.pumpAndSettle();
    expect(mic.langs, <String>['es']);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      '¿Qué veo en Lisboa?',
    );
    expect(b.sent, isEmpty);

    await tester.tap(find.byTooltip('Enviar'));
    // Al poco de llegar, la respuesta aún se está "tecleando"...
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(
      find.text('En Lisboa: Alfama, Belém y un pastel de nata.'),
      findsNothing,
    );
    // ...y al acabar se ve entera.
    await tester.pumpAndSettle();
    expect(
      find.text('En Lisboa: Alfama, Belém y un pastel de nata.'),
      findsOneWidget,
    );

    // El altavoz de su bocadillo la lee en el idioma de la app. El primero
    // es el saludo; el último, su respuesta.
    await tester.tap(find.byTooltip('Escuchar').last);
    await tester.pump();
    expect(voice.said, <String>[
      'es:En Lisboa: Alfama, Belém y un pastel de nata.',
    ]);
  });

  testWidgets('una sugerencia se envía al tocarla', (
    WidgetTester tester,
  ) async {
    final FlyraBackend b = await pumpFlyra(tester);
    // Las ideas van debajo de la portada de Flyra: se baja hasta ellas.
    await tester.ensureVisible(
      find.text('¿Qué puedo ver en 2 días en Lisboa?'),
    );
    await tester.pumpAndSettle();
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

  testWidgets('Flyra apagada en el servidor (404): lo dice claro', (
    WidgetTester tester,
  ) async {
    final FlyraBackend b = FlyraBackend()..failWith = 404;
    await pumpFlyra(tester, backend: b);
    await tester.enterText(find.byType(TextField), 'hola');
    await tester.tap(find.byTooltip('Enviar'));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('no está activada en el servidor'),
      findsOneWidget,
    );
    expect(find.textContaining('muy ocupada'), findsNothing);
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
    final m.PageSpy spy = m.PageSpy();
    final FlyraBackend b = FlyraBackend();
    final SessionController s = await signedInSession(b.g);
    await pumpApp(
      tester,
      locale: 'es',
      session: s,
      initialLocation: Routes.home,
      services: fakeServices(s, gateway: b.g, webScene: spy.build),
    );
    // La caja "O escríbele a Flyra…" de la página de Inicio.
    await spy.wait(tester, () => spy.pages.isNotEmpty);
    spy.send!(
      'ask:0:${base64Url.encode(utf8.encode(jsonEncode(<String, Object?>{'q': 'Hola'}))).replaceAll('=', '')}',
    );
    await tester.pumpAndSettle();
    expect(find.byType(FlyraChatScreen), findsOneWidget);
  });
}
