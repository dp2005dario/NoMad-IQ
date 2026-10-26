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
    await pumpApp(
      tester,
      locale: 'es',
      session: session,
      initialLocation: Routes.cards,
      services: fakeServices(session, gateway: g, prefs: store),
    );
    await tester.pumpAndSettle();
    expect(find.text('Crear una liga'), findsOneWidget);

    await tester.tap(find.text('Crear una liga'));
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
    expect(store.readGroupName(), 'Darío');
    // Se suben los sellos antes de leer la clasificación.
    expect((uploaded!['cards']! as List<Object?>).single, <String, Object?>{
      'qid': 'Q183536',
      'name': 'Torre de Tokio',
      'year': 1958,
      'month': '2026-10',
    });

    // Cambiar: Noelia ofrece Fushimi Inari por la Torre de Tokio.
    expect(
      find.text('Noelia te da Fushimi Inari por tu Torre de Tokio'),
      findsOneWidget,
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Cambiar'));
    await tester.pumpAndSettle();
    expect(g.calls, contains('POST /v1/leagues/$id/swaps/s1/accept'));
    expect(find.text('Copias que te han dado'), findsOneWidget);

    // Proponer: ya no le puedo pedir Fushimi (la tengo), sí el Coliseo.
    await tester.tap(find.widgetWithText(ChoiceChip, 'Noelia'));
    await tester.pumpAndSettle();
    expect(find.text('Coliseo'), findsOneWidget);
    await tester.tap(find.text('Coliseo'));
    await tester.tap(find.text('Torre de Tokio'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Enviar la oferta'));
    await tester.pumpAndSettle();
    expect(proposed, <String, Object?>{
      'to_seat': 2,
      'give_qid': 'Q183536',
      'want_qid': 'Q10285',
    });

    // Liga y amigos.
    await tester.tap(find.text('Liga'));
    await tester.pumpAndSettle();
    expect(find.text('Vas el 2 de 2'), findsOneWidget);
    expect(find.text('Te faltan 290 puntos para Noelia'), findsOneWidget);
    await tester.tap(find.text('Amigos'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Kioto'), findsOneWidget);
  });
}
