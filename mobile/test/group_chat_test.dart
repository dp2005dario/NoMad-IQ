// Chat del viaje: tipo de viaje, escribir, preguntar a @Flyra, recibir lo de
// los demás (preguntando cada pocos segundos) y el final del viaje.
// Servidor de mentira que guarda los mensajes en memoria.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:eclipta/core/router.dart';
import 'package:eclipta/features/group_chat/chat_api.dart';

import 'helpers.dart';

const String trip = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';

class FakeChat {
  String kind = 'friends';
  String myName = 'Viajero 1';
  final List<Map<String, Object?>> messages = <Map<String, Object?>>[];
  final List<String> flyraAsked = <String>[];

  Map<String, Object?> msg(int? seat, String text) {
    final Map<String, Object?> m = <String, Object?>{
      'id': messages.length + 1,
      'seat': seat,
      'name': seat == null ? 'Flyra' : (seat == 1 ? myName : 'Mamá'),
      'text': text,
      'at': '2026-10-25T12:00:00Z',
      'mine': seat == 1,
      'flyra': seat == null,
    };
    messages.add(m);
    return m;
  }

  void install(FakeGateway g) {
    final String base = '/v1/group-negotiations/$trip/chat';
    g.services[base] = (http.Request r) {
      if (r.method == 'POST') {
        final Map<String, Object?> body =
            jsonDecode(r.body) as Map<String, Object?>;
        final String text = body['text']! as String;
        final List<Map<String, Object?>> out = <Map<String, Object?>>[
          msg(1, text),
        ];
        if (mentionsFlyra(text)) {
          flyraAsked.add('${body['language']}');
          out.add(
            msg(null, 'Si llueve: Museo de los Azulejos y Time Out Market.'),
          );
        }
        return FakeGateway.json(<String, Object?>{
          'messages': out,
          'flyra_error': null,
        }, 201);
      }
      final int after = int.tryParse(r.url.queryParameters['after'] ?? '') ?? 0;
      return FakeGateway.json(<String, Object?>{
        'negotiation_id': trip,
        'title': 'Lisboa',
        'kind': kind,
        'members': <Object?>[
          <String, Object?>{
            'seat': 1,
            'name': myName,
            'me': true,
            'active': true,
          },
          <String, Object?>{
            'seat': 2,
            'name': 'Mamá',
            'me': false,
            'active': true,
          },
        ],
        'messages': <Object?>[
          for (final Map<String, Object?> m in messages)
            if ((m['id']! as int) > after) m,
        ],
      });
    };
    g.services['$base/kind'] = (http.Request r) {
      kind = (jsonDecode(r.body) as Map<String, Object?>)['kind']! as String;
      return http.Response('', 204);
    };
    g.services['$base/me'] = (http.Request r) {
      myName = (jsonDecode(r.body) as Map<String, Object?>)['name']! as String;
      return http.Response('', 204);
    };
  }
}

void main() {
  test('leer el chat: lo raro se ignora y "@Flyra" se reconoce', () {
    final ChatPage page = ChatPage.parse(<String, Object?>{
      'title': 'Lisboa',
      'kind': 'couple',
      'members': <Object?>[
        <String, Object?>{'seat': 1, 'name': 'Ana', 'me': true},
        'basura',
      ],
      'messages': <Object?>[
        <String, Object?>{
          'id': 1,
          'seat': null,
          'name': 'Flyra',
          'text': 'Hola',
          'at': '2026-10-25T12:00:00Z',
          'flyra': true,
        },
        <String, Object?>{'id': 'x'},
      ],
    });
    expect(page.kind, ChatTripKind.couple);
    expect(page.members.single.name, 'Ana');
    expect(page.messages.single.flyra, isTrue);
    expect(mentionsFlyra('@flyra, ¿qué hacemos?'), isTrue);
    expect(mentionsFlyra('hola @Flyra'), isFalse);
  });

  testWidgets('tipo de viaje, escribir, @Flyra, mensajes nuevos y fin', (
    WidgetTester tester,
  ) async {
    final FakeGateway g = FakeGateway();
    final FakeChat server = FakeChat()..install(g);
    final session = await signedInSession(g);
    tester.view.physicalSize = const Size(1200, 3000);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await pumpApp(
      tester,
      locale: 'es',
      session: session,
      initialLocation: Routes.groupChat(trip),
      services: fakeServices(session, gateway: g),
    );
    await tester.pumpAndSettle();

    // 1. Chat nuevo: "¿Con quién vas?" → Familia.
    expect(find.text('¿Con quién vas?'), findsOneWidget);
    await tester.tap(find.text('Familia'));
    await tester.pumpAndSettle();
    expect(server.kind, 'family');
    expect(find.textContaining('Familia · Tú, Mamá · Flyra'), findsOneWidget);

    // 2. Escribir al grupo.
    await tester.enterText(find.byType(TextField), 'Mañana qué hacemos?');
    await tester.tap(find.byTooltip('Enviar'));
    await tester.pumpAndSettle();
    expect(find.text('Mañana qué hacemos?'), findsOneWidget);

    // 3. Preguntar a Flyra con un atajo (en el idioma de la app).
    await tester.ensureVisible(find.text('@Flyra plan si llueve'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('@Flyra plan si llueve'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Museo de los Azulejos'), findsOneWidget);
    expect(server.flyraAsked, <String>['es']);

    // 4. Mamá escribe: llega solo, sin tocar nada.
    server.msg(2, '¡Hola! Ya estoy aquí');
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    expect(find.text('¡Hola! Ya estoy aquí'), findsOneWidget);

    // 5. Mi nombre en el chat.
    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Tu nombre en el chat'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'Dario');
    await tester.pump();
    await tester.tap(find.text('Guardar'));
    await tester.pumpAndSettle();
    expect(server.myName, 'Dario');

    // 6. Fin del viaje: resumen y estrellas.
    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Terminar viaje'));
    await tester.pumpAndSettle();
    expect(find.text('VIAJE TERMINADO'), findsOneWidget);
    expect(find.text('Lisboa, ¡qué viaje!'), findsOneWidget);
    await tester.tap(find.byTooltip('Valoración: 5 de 5'));
    await tester.pumpAndSettle();
    expect(find.text('Valorar en Google Play'), findsOneWidget);
  });
}
