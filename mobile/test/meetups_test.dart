// Quedadas: la lista de la ciudad, unirse (con nombre oculto), proponer,
// cancelar la mía y denunciar otra (servidor de mentira en memoria).
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:nomadiq/core/router.dart';
import 'package:nomadiq/core/settings.dart';
import 'package:nomadiq/features/meetups/meetups_api.dart';
import 'package:nomadiq/l10n/generated/app_localizations_es.dart';

import 'helpers.dart';

class FakeMeetups {
  final List<Map<String, Object?>> meetups = <Map<String, Object?>>[
    <String, Object?>{
      'meetup_id': 'm1',
      'city': 'LIS',
      'kind': 'food',
      'title': 'Cena de bacalao',
      'place': 'Praça do Comércio',
      'starts_at': DateTime.now()
          .add(const Duration(days: 3))
          .toUtc()
          .toIso8601String(),
      'capacity': 3,
      'going': 2,
      'people': <Object?>[
        <String, Object?>{'name': 'Emma', 'country': 'GB', 'organizer': true},
        <String, Object?>{'name': null, 'country': 'PT', 'organizer': false},
      ],
      'joined': false,
      'mine': false,
    },
  ];
  final List<String> reported = <String>[];
  Map<String, Object?>? lastJoin;
  Map<String, Object?>? lastCreate;

  void install(FakeGateway g) {
    g.services['/v1/meetups'] = (http.Request r) {
      if (r.method == 'POST') {
        final Map<String, Object?> b =
            jsonDecode(r.body) as Map<String, Object?>;
        lastCreate = b;
        final Map<String, Object?> me = b['me']! as Map<String, Object?>;
        final Map<String, Object?> m = <String, Object?>{
          'meetup_id': 'm2',
          'city': b['city'],
          'kind': b['kind'],
          'title': b['title'],
          'place': b['place'],
          'starts_at': b['starts_at'],
          'capacity': b['capacity'],
          'going': 1,
          'people': <Object?>[
            <String, Object?>{
              'name': me['visible'] == true ? me['name'] : null,
              'country': me['country'],
              'organizer': true,
            },
          ],
          'joined': true,
          'mine': true,
        };
        meetups.add(m);
        return FakeGateway.json(m, 201);
      }
      expect(r.url.queryParameters['city'], 'LIS');
      return FakeGateway.json(<String, Object?>{'meetups': meetups});
    };
    g.services['/v1/meetups/m1/join'] = (http.Request r) {
      final Map<String, Object?> m = meetups.first;
      if (r.method == 'POST') {
        lastJoin =
            (jsonDecode(r.body) as Map<String, Object?>)['me']!
                as Map<String, Object?>;
        m['joined'] = true;
        m['going'] = 3;
      } else {
        m['joined'] = false;
        m['going'] = 2;
      }
      return FakeGateway.json(m);
    };
    g.services['/v1/meetups/m1/report'] = (http.Request r) {
      reported.add('m1');
      return http.Response('', 204);
    };
    g.services['/v1/meetups/m2'] = (http.Request r) {
      expect(r.method, 'DELETE');
      meetups.removeWhere((Map<String, Object?> m) => m['meetup_id'] == 'm2');
      return http.Response('', 204);
    };
  }
}

void main() {
  test('una quedada mal formada se ignora y la hora va con zona', () {
    expect(Meetup.parse(<String, Object?>{'meetup_id': 'x'}), isNull);
    final Map<String, Object?> json = NewMeetup(
      city: 'LIS',
      kind: MeetupKind.walk,
      title: 'Paseo',
      place: 'Miradouro',
      startsAt: DateTime.utc(2026, 11, 1, 18),
      capacity: 4,
    ).toJson(const MeetupMe(name: 'Ana', visible: false));
    expect(json['starts_at'], '2026-11-01T18:00:00.000Z');
    expect(json['me'], <String, Object?>{'name': 'Ana', 'visible': false});
  });

  test('hoy y mañana', () {
    final AppLocalizationsEs t = AppLocalizationsEs();
    expect(t.meetupsToday('20:00'), 'Hoy 20:00');
    expect(t.meetupsSeats(4, 6), '4 de 6 plazas');
  });

  testWidgets('unirse oculto, proponer, cancelar y denunciar', (
    WidgetTester tester,
  ) async {
    final FakeGateway g = FakeGateway();
    final FakeMeetups server = FakeMeetups()..install(g);
    final MemorySettingsStore prefs = MemorySettingsStore()
      ..groupName = 'Dario';
    await prefs.writeData(LocalData.visaPassport, 'ES');
    final session = await signedInSession(g);
    tester.view.physicalSize = const Size(1200, 4000);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await pumpApp(
      tester,
      locale: 'es',
      session: session,
      initialLocation: Routes.meetups(city: 'LIS'),
      services: fakeServices(session, gateway: g, prefs: prefs),
    );
    await tester.pumpAndSettle();

    expect(find.text('Si viajas solo · Lisboa'), findsOneWidget);
    expect(find.text('Cena de bacalao'), findsOneWidget);
    expect(find.textContaining('2 de 3 plazas'), findsOneWidget);
    // Quien va oculto sale como "Alguien" (con su bandera).
    expect(find.text('Emma 🇬🇧, Alguien 🇵🇹'), findsOneWidget);

    // Me pongo oculto y me uno: el servidor no recibe "visible".
    await tester.tap(find.text('Visible para otros'));
    await tester.pumpAndSettle();
    expect(prefs.readData(LocalData.meetupHidden), '1');
    await tester.tap(find.text('Unirme'));
    await tester.pumpAndSettle();
    expect(server.lastJoin, <String, Object?>{
      'name': 'Dario',
      'country': 'ES',
      'visible': false,
    });
    expect(find.text('Vas'), findsOneWidget);
    await tester.tap(find.text('Paseo').first);
    await tester.pumpAndSettle();
    expect(find.text('Cena de bacalao'), findsNothing);
    await tester.tap(find.text('Todas'));
    await tester.pumpAndSettle();

    // Proponer una.
    await tester.tap(find.text('Proponer quedada'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ChoiceChip, 'Paseo').last);
    await tester.enterText(
      find.widgetWithText(TextField, 'Qué plan (p. ej. cena de ramen)'),
      'Atardecer en el mirador',
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Dónde quedáis'),
      'Miradouro da Graça',
    );
    await tester.pump();
    await tester.tap(find.text('Publicar'));
    await tester.pumpAndSettle();
    expect(server.lastCreate!['kind'], 'walk');
    expect(server.lastCreate!['capacity'], 6);
    expect(server.lastCreate!['starts_at'], endsWith('Z'));
    expect(find.text('Atardecer en el mirador'), findsOneWidget);
    expect(find.text('La tuya'), findsOneWidget);

    // Cancelar la mía (va primero: empieza antes).
    await tester.tap(find.byTooltip('Más opciones').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancelar quedada'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Cancelar quedada'));
    await tester.pumpAndSettle();
    expect(find.text('Atardecer en el mirador'), findsNothing);

    // Denunciar la otra: desaparece de mi lista.
    await tester.tap(find.byTooltip('Más opciones').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Denunciar'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Denunciar'));
    await tester.pumpAndSettle();
    expect(server.reported, <String>['m1']);
    expect(find.text('Cena de bacalao'), findsNothing);
  });
}
