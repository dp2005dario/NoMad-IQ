// Elegid planes: deslizar tarjetas, el match y las ideas de la ciudad
// (servidor de mentira que guarda los planes en memoria).
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:eclipta/core/router.dart';
import 'package:eclipta/features/plans/plans_api.dart';
import 'package:eclipta/features/plans/plans_screen.dart';
import 'package:eclipta/features/route/web_scene.dart';

import 'helpers.dart';
import 'money_test.dart' as m;

const String trip = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';

/// El servidor: dos personas; Noelia (la otra) ya votó sí a todo.
class FakePlans {
  final List<Map<String, Object?>> plans = <Map<String, Object?>>[];

  Map<String, Object?> board() => <String, Object?>{
    'negotiation_id': trip,
    'members': 2,
    'people': <Object?>[
      <String, Object?>{'name': 'Dario', 'me': true, 'voted': true},
      <String, Object?>{'name': 'Noelia', 'me': false, 'voted': true},
    ],
    'plans': plans,
  };

  /// Lo que se ha escrito en el chat del viaje.
  final List<String> chat = <String>[];

  void add(Map<String, Object?> p, {bool mine = true}) {
    plans.add(<String, Object?>{
      'plan_id': 'p${plans.length + 1}',
      'title': p['title'],
      'note': p['note'],
      'wikidata_id': p['wikidata_id'],
      'photo_url': null,
      'article_url': p['article_url'],
      'mine': mine,
      'my_vote': null,
      'yes': 1,
      'voted': 1,
      'match': false,
    });
  }

  void install(FakeGateway g) {
    final String base = '/v1/group-negotiations/$trip/plans';
    g.services[base] = (http.Request r) {
      if (r.method == 'POST') {
        final Map<String, Object?> body =
            jsonDecode(r.body) as Map<String, Object?>;
        for (final Object? p in body['plans']! as List<Object?>) {
          add(p! as Map<String, Object?>);
        }
      }
      return FakeGateway.json(board());
    };
    g.services['/v1/group-negotiations/$trip/chat'] = (http.Request r) {
      chat.add((jsonDecode(r.body) as Map<String, Object?>)['text']! as String);
      return FakeGateway.json(<String, Object?>{'messages': <Object?>[]});
    };
    for (int i = 1; i <= 20; i++) {
      g.services['$base/p$i/vote'] = (http.Request r) {
        final bool yes =
            (jsonDecode(r.body) as Map<String, Object?>)['yes']! as bool;
        final Map<String, Object?> p = plans[i - 1];
        p['my_vote'] = yes;
        p['voted'] = 2;
        p['yes'] = yes ? 2 : 1;
        p['match'] = yes;
        // Noelia ya había dicho que sí: con tu sí, coincidís.
        p['match_with'] = yes ? <String>['Noelia'] : <String>[];
        return FakeGateway.json(board());
      };
      g.services['$base/p$i/planned'] = (http.Request r) {
        plans[i - 1]['planned'] = true;
        return FakeGateway.json(board());
      };
    }
  }
}

/// Como lo empaqueta la página (base64url sin "=").
String pack(Map<String, Object?> v) =>
    base64Url.encode(utf8.encode(jsonEncode(v))).replaceAll('=', '');

void main() {
  test('el tablero: lo que me falta por votar y los match', () {
    final PlanBoard b = PlanBoard.parse(<String, Object?>{
      'members': 2,
      'plans': <Object?>[
        <String, Object?>{
          'plan_id': 'a',
          'title': 'Fado',
          'yes': 2,
          'voted': 2,
          'my_vote': true,
          'match': true,
          // Una foto que no es de Wikimedia no se enseña.
          'photo_url': 'https://evil.example/x.jpg',
        },
        <String, Object?>{
          'plan_id': 'b',
          'title': 'Surf',
          'yes': 0,
          'voted': 0,
        },
        <String, Object?>{'title': 'sin id'},
      ],
    });
    expect(b.plans, hasLength(2));
    expect(b.pending.single.title, 'Surf');
    expect(b.matches.single.title, 'Fado');
    // Sin "match_with" no es un match MÍO (no coincido con nadie aún).
    expect(b.plans.first.myMatch, isFalse);
    expect(b.plans.first.photoUrl, isNull);
    expect(const NewPlan(title: 'x', note: 'y').toJson(), <String, Object?>{
      'title': 'x',
      'note': 'y',
    });
  });

  /// Abre "Elegid planes" con la página de mentira.
  Future<(m.PageSpy, FakePlans)> open(
    WidgetTester tester, {
    bool empty = false,
  }) async {
    final FakeGateway g = FakeGateway()..publicPrefixes.add('/v1/places/');
    final FakePlans server = FakePlans();
    if (!empty) {
      server.add(<String, Object?>{
        'title': 'Fado en Alfama',
        'note': 'Esta noche · 21:30',
      }, mine: false);
    }
    server.install(g);
    g.services['/v1/places/LIS'] = (http.Request r) =>
        FakeGateway.json(<String, Object?>{
          'iata': 'LIS',
          'language': 'es',
          'wikidata_id': 'Q597',
          'city': 'Lisboa',
          'attractions': <Object?>[
            <String, Object?>{
              'name': 'Torre de Belém',
              'description': 'torre defensiva',
              'wikidata_id': 'Q193208',
            },
          ],
          'attribution': 'Wikidata',
        });
    final session = await signedInSession(g);
    final m.PageSpy spy = m.PageSpy();
    await pumpApp(
      tester,
      locale: 'es',
      session: session,
      initialLocation: Routes.groupPlans(trip, city: 'Lisboa', iata: 'LIS'),
      services: fakeServices(session, gateway: g, webScene: spy.build),
    );
    return (spy, server);
  }

  List<Object?> list(Map<String, Object?> d, String k) =>
      d[k]! as List<Object?>;

  testWidgets('sin planes: entran solas las ideas de la ciudad', (
    WidgetTester tester,
  ) async {
    final (m.PageSpy spy, FakePlans server) = await open(tester, empty: true);
    await spy.wait(
      tester,
      () =>
          spy.pages.isNotEmpty &&
          list(spy.data(PlansScreen.lastBridge!), 'cards').isNotEmpty,
    );
    expect(server.plans.single['wikidata_id'], 'Q193208');
    final Map<String, Object?> d = spy.data(PlansScreen.lastBridge!);
    final Map<String, Object?> card =
        list(d, 'cards').single! as Map<String, Object?>;
    expect(card['title'], 'Torre de Belém');
    expect(card['why'], 'Idea de la ficha de Lisboa');
    expect(d['sub'], 'Lisboa · derecha: me apetece · izquierda: paso');
  });

  testWidgets('deslizar, el match y añadirlo al plan', (
    WidgetTester tester,
  ) async {
    final (m.PageSpy spy, FakePlans server) = await open(tester);
    WebSceneBridge bridge() => PlansScreen.lastBridge!;
    await spy.wait(
      tester,
      () =>
          spy.pages.isNotEmpty && list(spy.data(bridge()), 'cards').isNotEmpty,
    );
    Map<String, Object?> d = spy.data(bridge());
    expect(list(d, 'people'), hasLength(2));
    expect((list(d, 'people')[1]! as Map<String, Object?>)['on'], isTrue);
    expect(d['total'], 1);

    // Me apetece. Noelia también dijo que sí: ¡match viajero!
    spy.send!('vote:1:${pack(<String, Object?>{'id': 'p1'})}');
    await spy.wait(tester, () => spy.data(bridge())['match'] != null);
    expect(server.plans.first['my_vote'], true);
    d = spy.data(bridge());
    final Map<String, Object?> match = d['match']! as Map<String, Object?>;
    expect(match['title'], 'Fado en Alfama');
    expect(match['who'], <String>['Noelia']);
    expect(list(d, 'cards'), isEmpty);
    expect(list(d, 'matched'), hasLength(1));

    // "Añadir al plan": se apunta y se avisa al grupo por el chat.
    spy.send!('addplan:0:${pack(<String, Object?>{'id': 'p1'})}');
    await spy.wait(tester, () => server.chat.isNotEmpty);
    expect(server.plans.first['planned'], true);
    expect(server.chat.single, contains('Fado en Alfama'));
    d = spy.data(bridge());
    expect(
      (list(d, 'matched').single! as Map<String, Object?>)['planned'],
      isTrue,
    );

    // Volver a empezar y decir que paso.
    spy.send!('again');
    await spy.wait(tester, () => list(spy.data(bridge()), 'cards').isNotEmpty);
    spy.send!('vote:0:${pack(<String, Object?>{'id': 'p1'})}');
    await spy.wait(tester, () => server.plans.first['my_vote'] == false);
  });
}
