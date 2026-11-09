// Chat del viaje: tipo de viaje, escribir, preguntar a @Flyra, recibir lo de
// los demás (preguntando cada pocos segundos) y el final del viaje.
// Servidor de mentira que guarda los mensajes en memoria.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:eclipta/core/router.dart';
import 'package:eclipta/core/settings.dart';
import 'package:eclipta/features/group_chat/chat_api.dart';
import 'package:eclipta/features/group_chat/chat_page.dart';
import 'package:eclipta/features/group_chat/chat_screen.dart';
import 'package:eclipta/features/route/web_scene.dart';

import 'helpers.dart';
import 'money_test.dart' as m;

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

WebSceneBridge bridge() => GroupChatScreen.lastBridge!;

/// Como lo empaqueta la página (base64url sin "=").
String pack(Map<String, Object?> v) =>
    base64Url.encode(utf8.encode(jsonEncode(v))).replaceAll('=', '');

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

  test('la página: tarjetas de Flyra, día, QR y cifras del final', () {
    ChatMessage msg(int id, String text, {bool mine = false, bool f = false}) =>
        ChatMessage(
          id: id,
          name: f ? 'Flyra' : (mine ? 'Dario' : 'Pepa'),
          text: text,
          at: DateTime(2026, 11, 8, 12),
          mine: mine,
          flyra: f,
          seat: f ? null : (mine ? 1 : 2),
        );
    final Map<String, Object?> d = chatPageData(
      city: 'Oporto',
      messages: <ChatMessage>[
        msg(1, '@Flyra ¿Cuánto llevamos gastado?', mine: true),
        msg(2, 'Las cuentas al día', f: true),
        msg(3, '@Flyra ¿Mañana qué hacemos?', mine: true),
        msg(4, 'Mirad', f: true),
        msg(5, 'Hola', f: false),
      ],
      code: '7K2M9QXD',
      now: DateTime(2026, 11, 8, 20),
    );
    final List<Object?> m = d['msgs']! as List<Object?>;
    Map<String, Object?> at(int i) => m[i]! as Map<String, Object?>;
    expect(at(0)['text'], '¿Cuánto llevamos gastado?');
    expect(at(1)['card'], 'money');
    // Sin match en Elegid planes, no hay tarjeta del plan.
    expect(at(3).containsKey('card'), isFalse);
    expect(at(4)['who'], 'p');
    expect(d['day'], 'Hoy · domingo');
    expect(
      chatDayLabel(DateTime(2026, 11, 6), DateTime(2026, 11, 8)),
      'viernes 6 nov',
    );
    expect(d['qr'], startsWith('M0 0h1v1h-1z'));
    expect((d['stats']! as List<Object?>).first, <String, Object?>{
      'v': '1',
      'l': 'día',
    });
    expect(chatCard('Plan si llueve'), isNull);
  });

  /// Abre el chat con la página de mentira.
  Future<m.PageSpy> open(
    WidgetTester tester,
    FakeGateway g, {
    SettingsStore? prefs,
  }) async {
    final session = await signedInSession(g);
    final m.PageSpy spy = m.PageSpy();
    await pumpApp(
      tester,
      locale: 'es',
      session: session,
      initialLocation: Routes.groupChat(trip),
      services: fakeServices(
        session,
        gateway: g,
        prefs: prefs,
        webScene: spy.build,
      ),
    );
    await spy.wait(
      tester,
      () => spy.pages.isNotEmpty && spy.data(bridge())['first'] != null,
    );
    return spy;
  }

  testWidgets('con quién vas, escribir a Flyra, mensajes nuevos y me gusta', (
    WidgetTester tester,
  ) async {
    final FakeGateway g = FakeGateway();
    final FakeChat server = FakeChat()..install(g);
    final MemorySettingsStore prefs = MemorySettingsStore();
    final m.PageSpy spy = await open(tester, g, prefs: prefs);
    List<Object?> msgs() => spy.data(bridge())['msgs']! as List<Object?>;

    // 1. Chat nuevo: "¿Con quién vas?" → Familia.
    expect(spy.data(bridge())['first'], 'type');
    spy.send!('kind:0:${pack(<String, Object?>{'k': 'family'})}');
    await spy.wait(tester, () => spy.data(bridge())['kind'] == 'family');
    expect(server.kind, 'family');

    // 2. Escribir: le llega a Flyra (con "@Flyra" delante) y contesta.
    spy.send!('send:0:${pack(<String, Object?>{'t': 'Plan si llueve'})}');
    await spy.wait(tester, () => msgs().length == 2);
    expect(server.messages.first['text'], '@Flyra Plan si llueve');
    expect(server.flyraAsked, <String>['es']);
    expect((msgs().first! as Map<String, Object?>)['text'], 'Plan si llueve');
    expect(
      (msgs().last! as Map<String, Object?>)['text'],
      contains('Museo de los Azulejos'),
    );

    // 3. Mamá escribe: llega solo, sin tocar nada.
    server.msg(2, '¡Hola! Ya estoy aquí');
    await tester.pump(const Duration(seconds: 5));
    await spy.wait(tester, () => msgs().length == 3);
    expect((msgs().last! as Map<String, Object?>)['name'], 'Mamá');

    // 4. Me gusta a Flyra: se guarda en el móvil.
    spy.send!('like:1:${pack(<String, Object?>{'id': 2})}');
    await spy.wait(
      tester,
      () => (prefs.readData(LocalData.chatLikes) ?? '').contains('$trip:2'),
    );

    // 5. Tocando tu cara: tu nombre en el chat.
    spy.send!('name');
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Dario');
    await tester.pump();
    await tester.tap(find.text('Guardar'));
    await spy.wait(tester, () => server.myName == 'Dario');
  });

  testWidgets('el chat apunta tus gustos por palabras clave (sin IA)', (
    WidgetTester tester,
  ) async {
    final FakeGateway g = FakeGateway();
    final FakeChat server = FakeChat()
      ..kind = 'friends'
      ..install(g);
    List<String> mine = <String>['late'];
    final List<List<String>> sent = <List<String>>[];
    Map<String, Object?> tripJson() => <String, Object?>{
      'negotiation_id': trip,
      'title': 'Lisboa',
      'status': 'concluded',
      'currency': 'EUR',
      'options': <Object?>[
        <String, Object?>{
          'option_id': 'a',
          'label': 'Lisboa',
          'price_minor': 100,
        },
        <String, Object?>{
          'option_id': 'b',
          'label': 'Roma',
          'price_minor': 200,
        },
      ],
      'deadline': '2026-10-26T16:00:00Z',
      'members': <Object?>[
        <String, Object?>{
          'alias': 'Viajero 1',
          'name': 'Darío',
          'tastes': mine,
          'submitted': true,
          'me': true,
        },
      ],
      'my_alias': 'Viajero 1',
      'i_organize': true,
    };
    g.services['/v1/group-negotiations/$trip'] = (_) =>
        FakeGateway.json(tripJson());
    g.services['/v1/group-negotiations/$trip/tastes'] = (http.Request r) {
      mine = <String>[
        for (final Object? t
            in (jsonDecode(r.body) as Map<String, Object?>)['tastes']!
                as List<Object?>)
          t! as String,
      ];
      sent.add(mine);
      return FakeGateway.json(tripJson());
    };
    server.msg(2, 'Hola');
    final m.PageSpy spy = await open(tester, g);
    spy.send!(
      'send:0:${pack(<String, Object?>{'t': 'Esta noche me apetece algo de fado y cenar pescado'})}',
    );
    await spy.wait(tester, () => sent.isNotEmpty);
    await tester.pump();
    expect(sent.single, <String>['late', 'music', 'fish']);
    expect(
      find.text('Apuntado en tus gustos: Música en directo, Pescado'),
      findsOneWidget,
    );
  });
}
