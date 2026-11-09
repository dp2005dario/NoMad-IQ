// Cromos con amigos: crear la liga, subir los sellos, la clasificación,
// aceptar un cambio y proponer otro.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:eclipta/auth/session.dart';
import 'package:eclipta/core/router.dart';
import 'package:eclipta/core/settings.dart';
import 'package:eclipta/features/camera/stamps.dart';
import 'package:eclipta/features/cards/cards_screen.dart';
import 'package:eclipta/features/cards/league_api.dart';

import 'helpers.dart';

Map<String, Object?> cardJson(String qid, String name, int? year) =>
    <String, Object?>{
      'qid': qid,
      'name': name,
      'year': year,
      'month': '2026-10',
    };

Map<String, Object?> standing(
  int seat,
  String name,
  int points, {
  bool me = false,
  String? city,
}) => <String, Object?>{
  'seat': seat,
  'name': name,
  'me': me,
  'points_month': points,
  'points_total': points,
  'cards': 2,
  'legendary': 1,
  'countries': 3,
  'city': city,
  'city_at': city == null ? null : DateTime.now().toUtc().toIso8601String(),
};

void main() {
  test('un sello se comparte solo con el mes, y los puntos por rareza', () {
    final LeagueCard c = LeagueCard.ofStamp(
      Stamp(
        qid: 'Q243',
        name: 'Torre Eiffel',
        date: DateTime.utc(2026, 3, 5, 18),
        lat: 48.85,
        lon: 2.29,
        year: 1889,
      ),
    );
    expect(c.toJson(), <String, Object?>{
      'qid': 'Q243',
      'name': 'Torre Eiffel',
      'year': 1889,
      'month': '2026-03',
    });
    expect(cardPoints(1889), 40);
    expect(cardPoints(711), 150);
    expect(cardPoints(null), 10);
  });

  testWidgets('crear la liga, ver la clasificación y cambiar cromos', (
    WidgetTester tester,
  ) async {
    final FakeGateway g = FakeGateway();
    final SessionController session = await signedInSession(g);
    final MemorySettingsStore store = MemorySettingsStore();
    await store.writeStamps(
      jsonEncode(<Object?>[
        Stamp(
          qid: 'Q183536',
          name: 'Torre de Tokio',
          date: DateTime.utc(2026, 10, 2),
          year: 1958,
        ).toJson(),
      ]),
    );
    bool created = false;
    String swapStatus = 'pending';
    Map<String, Object?>? uploaded;
    Map<String, Object?>? proposed;
    const String id = '9b2f3c1e-1111-4111-8111-111111111111';
    Map<String, Object?> view() => <String, Object?>{
      'league_id': id,
      'title': 'Exploradores',
      'invite_code': '7K2M9QXD',
      'month': '2026-10',
      'my_seat': 1,
      'standings': <Object?>[
        standing(2, 'Noelia', 300, city: 'Kioto'),
        standing(1, 'Darío', 10, me: true),
      ],
      'swaps': <Object?>[
        <String, Object?>{
          'swap_id': 's1',
          'from_seat': 2,
          'to_seat': 1,
          'give': cardJson('Q1059207', 'Fushimi Inari', 711),
          'want': cardJson('Q183536', 'Torre de Tokio', 1958),
          'status': swapStatus,
          'created_at': '2026-10-24T10:00:00Z',
        },
      ],
      'received': <Object?>[
        if (swapStatus == 'accepted')
          cardJson('Q1059207', 'Fushimi Inari', 711),
      ],
    };
    g.services['/v1/leagues'] = (http.Request r) {
      if (r.method == 'POST') {
        created = true;
        return FakeGateway.json(view(), 201);
      }
      return FakeGateway.json(<String, Object?>{
        'items': <Object?>[
          if (created)
            <String, Object?>{
              'league_id': id,
              'title': 'Exploradores',
              'members': 2,
              'my_position': 2,
            },
        ],
      });
    };
    g.services['/v1/leagues/$id/me'] = (http.Request r) {
      uploaded = jsonDecode(r.body) as Map<String, Object?>;
      return http.Response('', 204);
    };
    g.services['/v1/leagues/$id'] = (_) => FakeGateway.json(view());
    g.services['/v1/leagues/$id/swaps/s1/accept'] = (_) {
      swapStatus = 'accepted';
      return FakeGateway.json(<String, Object?>{});
    };
    g.services['/v1/leagues/$id/members/2/cards'] = (_) =>
        FakeGateway.json(<String, Object?>{
          'seat': 2,
          'name': 'Noelia',
          'cards': <Object?>[
            cardJson('Q1059207', 'Fushimi Inari', 711),
            cardJson('Q10285', 'Coliseo', 80),
          ],
        });
    g.services['/v1/leagues/$id/swaps'] = (http.Request r) {
      proposed = jsonDecode(r.body) as Map<String, Object?>;
      return FakeGateway.json(<String, Object?>{}, 201);
    };
    tester.view.physicalSize = const Size(1200, 4000);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    CardsScreen.undoTime = const Duration(milliseconds: 50);
    final List<String> pages = <String>[];
    void Function(String)? send;
    await pumpApp(
      tester,
      locale: 'es',
      session: session,
      initialLocation: Routes.cards,
      services: fakeServices(
        session,
        gateway: g,
        prefs: store,
        webScene: (String html, void Function(String) onMessage) {
          pages.add(html);
          send = onMessage;
          return const SizedBox.expand();
        },
      ),
    );
    Future<void> wait(bool Function() done) async {
      for (int i = 0; i < 100 && !done(); i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(done(), isTrue);
    }

    // Lo último que sabe la página: lo de la carga más lo que llegó después.
    Map<String, Object?> data() {
      expect(pages.toSet(), hasLength(1));
      final String html = pages.first;
      final int at = html.indexOf('window.ECL=') + 'window.ECL='.length;
      final Map<String, Object?> d = jsonDecode(
        html.substring(at, html.indexOf(';</script>', at)),
      ) as Map<String, Object?>;
      for (final String js in CardsScreen.lastBridge!.sent) {
        final int a = js.indexOf('ECLin(') + 'ECLin('.length;
        d.addAll(
          jsonDecode(js.substring(a, js.length - 1)) as Map<String, Object?>,
        );
      }
      return d;
    }

    Map<String, Object?> swap(int i) =>
        (data()['swaps']! as List<Object?>)[i]! as Map<String, Object?>;

    await wait(() => pages.isNotEmpty && g.calls.contains('GET /v1/leagues'));
    await tester.pumpAndSettle();
    // Sin liga: la maqueta invita a crear una o entrar con un código.
    expect(swap(0)['kind'], 'join');
    expect(swap(0)['button'], 'Crear una liga');
    send!('create');
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, 'Nombre de la liga'),
      'Exploradores',
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Tu nombre en la liga'),
      'Darío',
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Crear una liga').last);
    await tester.pumpAndSettle();
    await wait(() => uploaded != null && swap(0)['kind'] != 'join');
    expect(store.readGroupName(), 'Darío');
    // Se suben los sellos antes de leer la clasificación.
    expect((uploaded!['cards']! as List<Object?>).single, <String, Object?>{
      'qid': 'Q183536',
      'name': 'Torre de Tokio',
      'year': 1958,
      'month': '2026-10',
    });

    // Cambiar: Noelia ofrece Fushimi Inari por la Torre de Tokio.
    expect(swap(0)['kind'], 'in');
    expect(swap(0)['title'], 'Tu Torre de Tokio por su Fushimi Inari');
    expect((swap(0)['theirs']! as Map<String, Object?>)['label'], 'LEGENDARIA');
    // Aceptar y deshacer: no se manda nada.
    send!('accept:0');
    send!('undo:0');
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 120)),
    );
    await tester.pump();
    expect(g.calls, isNot(contains('POST /v1/leagues/$id/swaps/s1/accept')));
    // Aceptar de verdad: pasado el tiempo de deshacer, se manda.
    send!('accept:0');
    await wait(() => g.calls.contains('POST /v1/leagues/$id/swaps/s1/accept'));
    // Ya tengo Fushimi: ahora a Noelia solo le puedo pedir el Coliseo.
    await wait(() => swap(0)['kind'] == 'new');
    expect(swap(0)['title'], 'Tu Torre de Tokio por su Coliseo');
    send!('offer:0');
    await wait(() => proposed != null);
    expect(proposed, <String, Object?>{
      'to_seat': 2,
      'give_qid': 'Q183536',
      'want_qid': 'Q10285',
    });

    // Liga y amigos.
    await tester.pumpAndSettle();
    final Map<String, Object?> d = data();
    expect(d['headPos'], 'Vas 2.º de 2');
    expect(d['headSub'], 'Te faltan 290 puntos para Noelia');
    final Map<String, Object?> friend =
        (d['friends']! as List<Object?>).single! as Map<String, Object?>;
    expect(friend['where'], 'Kioto');
    expect(friend['meta'], contains('tiene 1 cromo que te falta'));
    CardsScreen.undoTime = const Duration(seconds: 30);
  });
}
