// Tests de la pantalla Grupo con destino (maqueta 7): gustos de cada uno,
// los 4 pasos de Flyra, votar dónde dormir, "¿Qué os apetece?" y la hora
// dorada. El servidor es falso (en memoria) y se comporta como el de verdad.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:eclipta/auth/session.dart';
import 'package:eclipta/core/router.dart';
import 'package:eclipta/features/group/cravings_api.dart';
import 'package:eclipta/features/group/group_api.dart';
import 'package:eclipta/features/group/group_hub.dart';
import 'package:eclipta/features/group/sun.dart';
import 'package:eclipta/features/map/geo.dart';
import 'package:eclipta/features/plans/plans_api.dart';
import 'package:eclipta/l10n/generated/app_localizations_es.dart';

import 'helpers.dart';

const String tripId = '6f1c2d3e-4a5b-4c6d-8e9f-0a1b2c3d4e5f';
const String base = '/v1/group-negotiations/$tripId';
const GeoPoint lisboa = GeoPoint(38.7223, -9.1393);

Map<String, Object?> member(
  String alias, {
  String? name,
  bool me = false,
  List<String> tastes = const <String>[],
}) => <String, Object?>{
  'alias': alias,
  'name': name,
  'tastes': tastes,
  'submitted': true,
  'me': me,
};

/// Un viaje terminado: el grupo eligió Lisboa.
Map<String, Object?> tripJson(List<String> myTastes) => <String, Object?>{
  'negotiation_id': tripId,
  'title': 'Puente de mayo',
  'status': 'concluded',
  'currency': 'EUR',
  'language': 'es',
  'options': <Object?>[
    <String, Object?>{
      'option_id': 'lis',
      'label': 'Lisboa',
      'price_minor': 30000,
    },
    <String, Object?>{
      'option_id': 'rom',
      'label': 'Roma',
      'price_minor': 40000,
    },
  ],
  'deadline': '2026-10-26T16:00:00Z',
  'created_at': '2026-10-23T16:00:00Z',
  'concluded_at': '2026-10-24T16:00:00Z',
  'members': <Object?>[
    member('Viajero 1', name: 'Darío', me: true, tastes: myTastes),
    member('Viajero 2', name: 'Noelia', tastes: <String>['tapas', 'views']),
  ],
  'my_alias': 'Viajero 1',
  'i_organize': true,
  'invite_code': null,
  'my_preferences': null,
  'result': <String, Object?>{
    'outcome': 'consensus',
    'chosen_option_id': 'lis',
    'rounds': 1,
    'explanation': '',
    'excluded_over_budget': <String>[],
    'members': <Object?>[],
    'llm_used': false,
  },
};

/// Un ai-orchestrator falso: viaje, mapa, zonas, antojos y el tablero.
class HubBackend {
  HubBackend() {
    g.services[base] = (_) => FakeGateway.json(tripJson(myTastes));
    g.services['$base/tastes'] = (http.Request r) {
      final Map<String, Object?> body =
          jsonDecode(r.body) as Map<String, Object?>;
      myTastes = <String>[
        for (final Object? t in body['tastes']! as List<Object?>) t! as String,
      ];
      sentTastes.add(myTastes);
      return FakeGateway.json(tripJson(myTastes));
    };
    g.services['/v1/geocode'] = (_) => FakeGateway.json(<String, Object?>{
      'items': <Object?>[
        <String, Object?>{
          'name': 'Lisboa',
          'address': 'Lisboa, Portugal',
          'lat': lisboa.lat,
          'lon': lisboa.lon,
        },
      ],
    });
    g.services['/v1/stays'] = (_) => FakeGateway.json(<String, Object?>{
      'zones': <Object?>[
        <String, Object?>{
          'id': 'here',
          'lat': 38.72,
          'lon': -9.14,
          'km': 0.3,
          'minutes': 5,
          'by': 'walk',
          'lodgings': 40,
        },
        <String, Object?>{
          'id': 'alfama',
          'name': 'Alfama',
          'lat': 38.711,
          'lon': -9.13,
          'km': 1.5,
          'minutes': 12,
          'by': 'train',
          'lodgings': 25,
        },
      ],
      'attribution': '© OpenStreetMap contributors',
    });
    g.services['/v1/cravings'] = (http.Request r) {
      cravings.add(r.url.queryParameters['kind']!);
      return FakeGateway.json(<String, Object?>{
        'kind': r.url.queryParameters['kind'],
        'lat': 38.72,
        'lon': -9.14,
        'spots': <Object?>[
          // Lejos (más de 1 km): no sale.
          <String, Object?>{
            'id': 'n1',
            'name': 'Muy lejos',
            'lat': 38.76,
            'lon': -9.10,
          },
          <String, Object?>{
            'id': 'n2',
            'name': 'Taberna do Largo',
            'lat': 38.7250,
            'lon': -9.1380,
            'opening_hours': 'Mo-Su 18:00-24:00',
          },
          <String, Object?>{
            'id': 'n3',
            'name': 'Petiscos da Sé',
            'lat': 38.7230,
            'lon': -9.1400,
          },
        ],
      });
    };
    g.services['$base/plans'] = (http.Request r) {
      if (r.method == 'POST') {
        final Map<String, Object?> body =
            jsonDecode(r.body) as Map<String, Object?>;
        for (final Object? p in body['plans']! as List<Object?>) {
          final Map<String, Object?> plan = p! as Map<String, Object?>;
          added.add(plan);
          final bool known = plans.any(
            (Map<String, Object?> x) =>
                x['kind'] == plan['kind'] &&
                (x['title']! as String).toLowerCase() ==
                    (plan['title']! as String).toLowerCase(),
          );
          if (!known) {
            plans.add(<String, Object?>{
              'plan_id': 'p${plans.length + 1}',
              'title': plan['title'],
              'kind': plan['kind'] ?? 'plan',
              'votes': <int, bool>{},
            });
          }
        }
      }
      return FakeGateway.json(board(), r.method == 'POST' ? 201 : 200);
    };
    for (int i = 1; i <= 6; i++) {
      g.services['$base/plans/p$i/vote'] = (http.Request r) {
        final Map<String, Object?> body =
            jsonDecode(r.body) as Map<String, Object?>;
        votes.add('p$i=${body['yes']}');
        (plans[i - 1]['votes']! as Map<int, bool>)[1] = body['yes']! as bool;
        return FakeGateway.json(board());
      };
    }
  }

  final FakeGateway g = FakeGateway();
  List<String> myTastes = <String>['tapas', 'late'];
  final List<List<String>> sentTastes = <List<String>>[];
  final List<String> cravings = <String>[];
  final List<Map<String, Object?>> added = <Map<String, Object?>>[];
  final List<String> votes = <String>[];

  /// El tablero: Noelia (asiento 2) ya votó Alfama para dormir.
  final List<Map<String, Object?>> plans = <Map<String, Object?>>[
    <String, Object?>{
      'plan_id': 'p1',
      'title': 'Junto a Lisboa',
      'kind': 'sleep',
      'votes': <int, bool>{2: false},
    },
    <String, Object?>{
      'plan_id': 'p2',
      'title': 'Alfama',
      'kind': 'sleep',
      'votes': <int, bool>{2: true},
    },
  ];

  Map<String, Object?> board() => <String, Object?>{
    'negotiation_id': tripId,
    'members': 2,
    'people': <Object?>[],
    'plans': <Object?>[
      for (final Map<String, Object?> p in plans)
        <String, Object?>{
          'plan_id': p['plan_id'],
          'title': p['title'],
          'kind': p['kind'],
          'mine': false,
          'my_vote': (p['votes']! as Map<int, bool>)[1],
          'yes': (p['votes']! as Map<int, bool>).values
              .where((bool v) => v)
              .length,
          'voted': (p['votes']! as Map<int, bool>).length,
          'match': false,
          'match_with': <String>[],
          'planned': false,
        },
    ],
  };
}

void main() {
  final AppLocalizationsEs t = AppLocalizationsEs();

  test('la hora dorada sale de la posición del sol', () {
    // Lisboa, 3 de noviembre: el sol se pone hacia las 17:34 (UTC).
    final DateTime set = sunsetUtc(DateTime.utc(2026, 11, 3), lisboa)!;
    expect(set.isUtc, isTrue);
    expect(
      set.difference(DateTime.utc(2026, 11, 3, 17, 34)).inMinutes.abs(),
      lessThan(6),
    );
    // Madrid, 21 de junio: hacia las 19:48 UTC (21:48 en España).
    final DateTime june = sunsetUtc(
      DateTime.utc(2026, 6, 21),
      const GeoPoint(40.4168, -3.7038),
    )!;
    expect(
      june.difference(DateTime.utc(2026, 6, 21, 19, 48)).inMinutes.abs(),
      lessThan(6),
    );
    expect(
      goldenHour(DateTime.utc(2026, 11, 3), lisboa),
      set.subtract(const Duration(minutes: 30)),
    );
    // En el polo en verano no se pone el sol.
    expect(sunsetUtc(DateTime.utc(2026, 6, 21), const GeoPoint(80, 0)), isNull);
  });

  test('gustos: los más repetidos, el antojo de inicio y el chat', () {
    const List<TripMember> members = <TripMember>[
      TripMember(
        alias: 'A',
        submitted: true,
        me: true,
        tastes: <String>['late', 'views'],
      ),
      TripMember(
        alias: 'B',
        submitted: true,
        me: false,
        tastes: <String>['views', 'fish'],
      ),
    ];
    expect(topTastes(members).first, ('views', 2));
    expect(firstCraving(members), Craving.views);
    expect(firstCraving(const <TripMember>[]), Craving.tapas);
    expect(
      tastesInText(t, 'Esta noche me apetece algo de FADO y cenar pescado'),
      <String>['music', 'fish'],
    );
    expect(tastesInText(t, 'nada que ver'), isEmpty);
  });

  test('sitios: solo a un paseo, y lo votado sube', () {
    const CravingSpot near = CravingSpot(
      id: 'a',
      name: 'Cerca',
      point: GeoPoint(38.7224, -9.1394),
    );
    const CravingSpot mid = CravingSpot(
      id: 'b',
      name: 'Medio',
      point: GeoPoint(38.7250, -9.1393),
    );
    const CravingSpot far = CravingSpot(
      id: 'c',
      name: 'Lejos',
      point: GeoPoint(38.76, -9.10),
    );
    List<String> names(Map<String, GroupPlan> votes) => rankSpots(
      <CravingSpot>[far, mid, near],
      lisboa,
      votes,
    ).map((CravingSpot s) => s.name).toList();
    expect(names(<String, GroupPlan>{}), <String>['Cerca', 'Medio']);
    const GroupPlan liked = GroupPlan(
      id: 'p',
      title: 'Medio',
      mine: false,
      yes: 2,
      voted: 2,
      match: true,
    );
    expect(names(<String, GroupPlan>{'medio': liked}), <String>[
      'Medio',
      'Cerca',
    ]);
    const GroupPlan passed = GroupPlan(
      id: 'q',
      title: 'Cerca',
      mine: false,
      yes: 0,
      voted: 1,
      match: false,
      myVote: false,
    );
    expect(names(<String, GroupPlan>{'cerca': passed}), <String>[
      'Medio',
      'Cerca',
    ]);
    expect(walkMinutes(400), 5);
  });

  test('el tablero separa planes de antojos y zonas', () {
    final PlanBoard b = PlanBoard.parse(HubBackend().board());
    expect(b.plans, isEmpty);
    expect(b.extras.map((GroupPlan p) => p.kind).toSet(), <PlanKind>{
      PlanKind.sleep,
    });
    expect(
      const NewPlan(title: 'X', kind: PlanKind.crave).toJson()['kind'],
      'crave',
    );
    expect(const NewPlan(title: 'X').toJson().containsKey('kind'), isFalse);
  });

  testWidgets('Grupo con destino: gustos, dormir, antojos y hora dorada', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 12000);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    final HubBackend b = HubBackend();
    final List<Uri> opened = <Uri>[];
    final SessionController s = await signedInSession(b.g);
    await pumpApp(
      tester,
      locale: 'es',
      session: s,
      initialLocation: Routes.groupTrip(tripId),
      services: fakeServices(
        s,
        gateway: b.g,
        openBooking: (Uri u) async {
          opened.add(u);
          return true;
        },
      ),
    );

    // Atajos y "Gustos de cada uno".
    expect(find.text('Chat del viaje'), findsWidgets);
    expect(find.text('El bote común'), findsOneWidget);
    expect(find.text('Gustos de cada uno'), findsOneWidget);
    expect(find.text(t.tastesHintMine), findsOneWidget);
    // El ejemplo del chat: así se apuntan los gustos sin tocar nada.
    expect(find.text(t.hubChatSample), findsOneWidget);
    await tester.tap(find.text('Museos').first);
    await tester.pumpAndSettle();
    expect(b.sentTastes.single, <String>['tapas', 'late', 'museums']);
    // Los de Noelia se ven, pero no se tocan.
    await tester.tap(
      find
          .descendant(
            of: find.byType(AnimatedContainer),
            matching: find.text('Noelia'),
          )
          .first,
    );
    await tester.pumpAndSettle();
    expect(find.text('Esto lo marcó Noelia en su móvil.'), findsOneWidget);
    await tester.tap(find.text('Museos').first);
    await tester.pumpAndSettle();
    expect(b.sentTastes, hasLength(1));

    // Los 4 pasos, en pestañas, con datos reales.
    expect(
      find.text(
        'Lo que más se repite: Tapas (2) · Museos (1) · Con vistas (1)',
      ),
      findsOneWidget,
    );
    await tester.tap(find.text('Zona'));
    await tester.pumpAndSettle();
    expect(find.text('Primera opción: Junto a Lisboa'), findsOneWidget);
    expect(find.text('Abrir Booking'), findsNothing);
    await tester.tap(find.text('Dormir'));
    await tester.pumpAndSettle();
    expect(find.text('Abrir Booking'), findsOneWidget);
    await tester.tap(find.text('Zona'));
    await tester.pumpAndSettle();

    // Votad dónde dormir: Noelia ya eligió Alfama; al elegirla yo, acuerdo.
    expect(find.text('Votos que faltan, contando el tuyo: 1.'), findsOneWidget);
    await tester.tap(find.text('Alfama'));
    await tester.pumpAndSettle();
    expect(b.added, isEmpty); // las dos zonas ya estaban en el tablero
    expect(b.votes, <String>['p1=false', 'p2=true']);
    expect(find.text(t.sleepDeal), findsOneWidget);
    expect(find.text('Abrir Booking'), findsOneWidget); // el del acuerdo

    // "¿Qué os apetece?": empieza por tapas (el gusto más repetido).
    expect(b.cravings, <String>['tapas']);
    expect(find.text('Muy lejos'), findsNothing);
    expect(find.text('Petiscos da Sé'), findsOneWidget);
    expect(find.text('Encaja con Tú, Noelia'), findsNWidgets(2));
    await tester.ensureVisible(find.text('Me apetece').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Me apetece').first);
    await tester.pumpAndSettle();
    expect(b.added.single, <String, Object?>{
      'title': 'Petiscos da Sé',
      'note': 'Tapas',
      'kind': 'crave',
    });
    expect(b.votes.last, 'p3=true');
    expect(find.text('1 de 2 se apuntan'), findsOneWidget);
    // "Ir": Google Maps andando hasta el sitio.
    await tester.ensureVisible(find.text('Ir').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Ir').first);
    await tester.pumpAndSettle();
    expect(opened.last.host, 'www.google.com');
    expect(opened.last.queryParameters['travelmode'], 'walking');
    await tester.ensureVisible(find.text('Café').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Café').first);
    await tester.pumpAndSettle();
    expect(b.cravings, <String>['tapas', 'cafe']);
    expect(find.textContaining('Hora dorada hoy sobre las'), findsOneWidget);
    expect(find.text(t.craveSource), findsOneWidget);
    expect(find.text('De dónde saca Flyra los datos'), findsOneWidget);
  });
}
