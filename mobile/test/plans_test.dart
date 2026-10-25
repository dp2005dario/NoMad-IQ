// Elegid planes: deslizar tarjetas, el match y las ideas de la ciudad
// (servidor de mentira que guarda los planes en memoria).
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:nomadiq/core/router.dart';
import 'package:nomadiq/features/plans/plans_api.dart';

import 'helpers.dart';

const String trip = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';

/// El servidor: dos personas; Noelia (la otra) ya votó sí a todo.
class FakePlans {
  final List<Map<String, Object?>> plans = <Map<String, Object?>>[];

  Map<String, Object?> board() => <String, Object?>{
    'negotiation_id': trip,
    'members': 2,
    'plans': plans,
  };

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
    for (int i = 1; i <= 20; i++) {
      g.services['$base/p$i/vote'] = (http.Request r) {
        final bool yes =
            (jsonDecode(r.body) as Map<String, Object?>)['yes']! as bool;
        final Map<String, Object?> p = plans[i - 1];
        p['my_vote'] = yes;
        p['voted'] = 2;
        p['yes'] = yes ? 2 : 1;
        p['match'] = yes;
        return FakeGateway.json(board());
      };
    }
  }
}

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
    expect(b.plans.first.photoUrl, isNull);
    expect(const NewPlan(title: 'x', note: 'y').toJson(), <String, Object?>{
      'title': 'x',
      'note': 'y',
    });
  });

  testWidgets('añadir ideas de la ciudad, deslizar y ver el match', (
    WidgetTester tester,
  ) async {
    final FakeGateway g = FakeGateway();
    final FakePlans server = FakePlans()
      ..add(<String, Object?>{
        'title': 'Fado en Alfama',
        'note': 'Esta noche · 21:30',
      }, mine: false);
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
    tester.view.physicalSize = const Size(1200, 4000);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await pumpApp(
      tester,
      locale: 'es',
      session: session,
      initialLocation: Routes.groupPlans(trip, city: 'Lisboa'),
      services: fakeServices(session, gateway: g),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('Lisboa · desliza'), findsOneWidget);
    expect(find.text('Plan 1 de 1'), findsOneWidget);
    expect(find.text('Fado en Alfama'), findsWidgets);

    // Ideas de la ciudad: LIS → la Torre de Belém entra al mazo.
    await tester.tap(find.text('Ideas de la ciudad'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'lis');
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, 'Añadir'));
    await tester.pumpAndSettle();
    expect(server.plans.last['wikidata_id'], 'Q193208');
    expect(find.text('Plan 1 de 2'), findsOneWidget);

    // Deslizar a la derecha = sí.
    await tester.drag(find.text('Esta noche · 21:30'), const Offset(300, 0));
    await tester.pumpAndSettle();
    expect(server.plans.first['my_vote'], true);
    expect(find.text('Plan 2 de 2'), findsOneWidget);

    // El botón ✕ = no.
    await tester.tap(find.byTooltip('NO'));
    await tester.pumpAndSettle();
    expect(server.plans.last['my_vote'], false);

    expect(find.text('¡Match!'), findsOneWidget);
    expect(find.text('Estos planes gustan a los 2.'), findsOneWidget);
    expect(find.text('1 sí · han votado 2 de 2'), findsOneWidget);
  });
}
