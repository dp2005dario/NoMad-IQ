// Tests de Grupo: crear un viaje y recibir el código, unirse con un código,
// enviar las preferencias privadas, "Empezar" y ver el resultado de Flyra.
// El ai-orchestrator es falso (en memoria) y se comporta como el de verdad.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:eclipta/auth/session.dart';
import 'package:eclipta/core/api_client.dart';
import 'package:eclipta/core/money.dart';
import 'package:eclipta/core/router.dart';
import 'package:eclipta/core/settings.dart';
import 'package:eclipta/features/group/group_api.dart';

import 'helpers.dart';

const String tripId = '6f1c2d3e-4a5b-4c6d-8e9f-0a1b2c3d4e5f';
const String base = '/v1/group-negotiations';

Map<String, Object?> member(
  String alias, {
  String? name,
  bool submitted = false,
  bool me = false,
}) => <String, Object?>{
  'alias': alias,
  'name': name,
  'submitted': submitted,
  'me': me,
};

/// Un viaje como lo manda el servidor (lo mínimo, con valores de ejemplo).
Map<String, Object?> tripJson({
  String status = 'collecting',
  List<Map<String, Object?>>? members,
  bool organize = true,
  String? code = '7K2M9QXD',
  Map<String, Object?>? prefs,
  Map<String, Object?>? result,
}) => <String, Object?>{
  'negotiation_id': tripId,
  'title': 'Puente de mayo',
  'status': status,
  'currency': 'EUR',
  'language': 'es',
  'options': <Object?>[
    <String, Object?>{
      'option_id': 'op-1',
      'label': 'Piso en Alfama',
      'price_minor': 6200,
      'tags': <String>['nightlife', 'history'],
    },
    <String, Object?>{
      'option_id': 'op-2',
      'label': 'Hotel en Baixa',
      'price_minor': 7800,
      'tags': <String>['shopping'],
    },
  ],
  'deadline': '2026-10-26T16:00:00Z',
  'created_at': '2026-10-23T16:00:00Z',
  'concluded_at': null,
  'members':
      members ??
      <Map<String, Object?>>[member('Viajero 1', name: 'Darío', me: true)],
  'my_alias': 'Viajero 1',
  'i_organize': organize,
  'invite_code': status == 'collecting' ? code : null,
  'my_preferences': prefs,
  'result': result,
};

/// Un ai-orchestrator falso para Grupo. Apunta lo que la app le manda.
class GroupBackend {
  GroupBackend() {
    g.services[base] = (http.Request r) {
      if (r.method == 'GET') {
        return FakeGateway.json(<String, Object?>{
          'items': <Object?>[?current],
        });
      }
      created.add(jsonDecode(r.body) as Map<String, Object?>);
      current = tripJson();
      return FakeGateway.json(current!, 201);
    };
    g.services['$base/join'] = (http.Request r) {
      final Map<String, Object?> body =
          jsonDecode(r.body) as Map<String, Object?>;
      joins.add(body);
      if (body['code'] != '7K2M-9QXD') return http.Response('{}', 404);
      current = tripJson(
        organize: false,
        members: <Map<String, Object?>>[
          member('Viajero 1', name: 'Darío'),
          member('Viajero 2', name: body['my_name'] as String?, me: true),
        ],
      );
      return FakeGateway.json(current!);
    };
    g.services['$base/$tripId'] = (http.Request r) =>
        current == null ? http.Response('', 404) : FakeGateway.json(current!);
    g.services['$base/$tripId/preferences'] = (http.Request r) {
      sentPrefs.add(jsonDecode(r.body) as Map<String, Object?>);
      current = tripJson(
        prefs: sentPrefs.last,
        members: <Map<String, Object?>>[
          member('Viajero 1', name: 'Darío', me: true, submitted: true),
          member('Viajero 2', name: 'Noelia', submitted: true),
        ],
      );
      return FakeGateway.json(current!);
    };
    g.services['$base/$tripId/start'] = (http.Request r) {
      starts++;
      current = tripJson(status: 'queued');
      return FakeGateway.json(current!);
    };
  }

  final FakeGateway g = FakeGateway();
  Map<String, Object?>? current;
  final List<Map<String, Object?>> created = <Map<String, Object?>>[];
  final List<Map<String, Object?>> joins = <Map<String, Object?>>[];
  final List<Map<String, Object?>> sentPrefs = <Map<String, Object?>>[];
  int starts = 0;
}

Future<GroupBackend> pumpGroup(
  WidgetTester tester, {
  String initialLocation = Routes.group,
  GroupBackend? backend,
  MemorySettingsStore? prefs,
  bool guest = false,
}) async {
  tester.view.physicalSize = const Size(1200, 9000);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  final GroupBackend b = backend ?? GroupBackend();
  final SessionController s = guest
      ? (newSession(b.g)..continueAsGuest())
      : await signedInSession(b.g);
  await pumpApp(
    tester,
    locale: 'es',
    session: s,
    initialLocation: initialLocation,
    services: fakeServices(s, gateway: b.g, prefs: prefs),
  );
  return b;
}

void main() {
  group('lo que llega del servidor', () {
    test('un viaje terminado se lee entero', () {
      final GroupTrip trip = GroupTrip.parse(
        tripJson(
          status: 'concluded',
          result: <String, Object?>{
            'outcome': 'consensus',
            'chosen_option_id': 'op-1',
            'rounds': 2,
            'explanation': 'texto del servidor (la app no lo usa)',
            'excluded_over_budget': <String>['op-2'],
            'members': <Object?>[
              <String, Object?>{
                'alias': 'Viajero 1',
                'ranking': <String>['op-1'],
                'acceptable': <String>['op-1'],
                'argument': 'Fado cerca y entra en el presupuesto.',
                'source': 'llm',
                'chosen_rank': 1,
              },
            ],
            'llm_used': true,
          },
        ),
      );
      expect(trip.status, TripStatus.concluded);
      expect(trip.inviteCode, isNull);
      expect(trip.option(trip.result!.chosenOptionId)!.label, 'Piso en Alfama');
      expect(trip.result!.excludedOverBudget, 1);
      expect(trip.result!.members.single.byAi, isTrue);
      expect(trip.nameOf('Viajero 1'), 'Darío');
    });

    test('lo raro se rechaza en vez de romper la pantalla', () {
      for (final Map<String, Object?> bad in <Map<String, Object?>>[
        tripJson()..['status'] = 'bailando',
        tripJson()..['currency'] = 'euros',
        tripJson()..['i_organize'] = 'sí',
        tripJson()..['options'] = 'muchas',
      ]) {
        expect(
          () => GroupTrip.parse(bad),
          throwsA(isA<ApiException>()),
          reason: '$bad',
        );
      }
    });

    test('importes enteros ↔ unidades mínimas según la divisa', () {
      expect(wholeToMinor(70, 'EUR'), 7000);
      expect(wholeToMinor(9000, 'JPY'), 9000); // el yen no tiene céntimos
      expect(minorToWhole(7050, 'EUR'), 70);
      expect(formatInviteCode('7K2M9QXD'), '7K2M-9QXD');
    });
  });

  testWidgets('invitado: Grupo pide crear una cuenta', (
    WidgetTester tester,
  ) async {
    final GroupBackend b = await pumpGroup(tester, guest: true);
    expect(find.text('Viajes en grupo'), findsOneWidget);
    expect(find.textContaining('necesitan una cuenta'), findsOneWidget);
    expect(find.text('Nuevo viaje en grupo'), findsNothing);
    expect(b.created, isEmpty);
  });

  testWidgets('crear un viaje: opciones, precio por persona y el código', (
    WidgetTester tester,
  ) async {
    final MemorySettingsStore prefs = MemorySettingsStore('es');
    final GroupBackend b = await pumpGroup(tester, prefs: prefs);
    expect(
      find.textContaining('Aún no tienes viajes en grupo'),
      findsOneWidget,
    );

    await tester.tap(find.text('Nuevo viaje en grupo'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Nombre del viaje'),
      'Puente de mayo',
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Tu nombre para el grupo'),
      'Darío',
    );
    final Finder names = find.widgetWithText(TextFormField, 'Nombre');
    final Finder prices = find.widgetWithText(
      TextFormField,
      'Precio por persona',
    );
    // Sin rellenar las opciones no se envía nada.
    await tester.tap(find.text('Crear y obtener el código'));
    await tester.pumpAndSettle();
    expect(b.created, isEmpty);
    expect(find.text('Obligatorio'), findsNWidgets(2));

    await tester.enterText(names.at(0), 'Piso en Alfama');
    await tester.enterText(prices.at(0), '62');
    await tester.enterText(names.at(1), 'Hotel en Baixa');
    await tester.enterText(prices.at(1), '78');
    await tester.tap(find.text('Fiesta').first);
    await tester.pump();
    await tester.tap(find.text('Crear y obtener el código'));
    await tester.pumpAndSettle();

    final Map<String, Object?> sent = b.created.single;
    expect(sent['title'], 'Puente de mayo');
    expect(sent['currency'], 'EUR');
    expect(sent['language'], 'es');
    expect(sent['members'], isEmpty);
    expect(sent['my_name'], 'Darío');
    final List<Object?> options = sent['options']! as List<Object?>;
    expect(options.first, <String, Object?>{
      'option_id': 'op-1',
      'label': 'Piso en Alfama',
      'price_minor': 6200,
      'tags': <String>['nightlife'],
    });
    expect(prefs.groupName, 'Darío');

    // Se abre el viaje con el código para invitar, listo para copiar.
    expect(find.text('Invita a tu grupo'), findsOneWidget);
    expect(find.text('7K2M-9QXD'), findsOneWidget);
    expect(find.text('Tus preferencias'), findsOneWidget);
  });

  testWidgets('unirse con un código', (WidgetTester tester) async {
    final GroupBackend b = await pumpGroup(tester);
    await tester.tap(find.text('Unirme con un código'));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.widgetWithText(TextField, 'Código de invitación'),
      'XXXX-0000',
    );
    await tester.tap(find.text('Unirme'));
    await tester.pumpAndSettle();
    expect(find.text('Ese código no existe o ha caducado.'), findsOneWidget);

    await tester.enterText(
      find.widgetWithText(TextField, 'Código de invitación'),
      '7K2M-9QXD',
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Tu nombre para el grupo'),
      'Noelia',
    );
    await tester.tap(find.text('Unirme'));
    await tester.pumpAndSettle();

    expect(b.joins.last, <String, Object?>{
      'code': '7K2M-9QXD',
      'my_name': 'Noelia',
    });
    // Dentro: los dos nombres, y quien no organiza espera a que empiecen.
    expect(find.text('Darío'), findsOneWidget);
    expect(find.text('Tú'), findsOneWidget);
    expect(find.textContaining('quien organiza pulsa Empezar'), findsOneWidget);
    expect(find.text('Empezar la negociación'), findsNothing);
  });

  testWidgets('preferencias privadas y Empezar', (WidgetTester tester) async {
    final GroupBackend b = GroupBackend()
      ..current = tripJson(
        members: <Map<String, Object?>>[
          member('Viajero 1', name: 'Darío', me: true),
          member('Viajero 2', name: 'Noelia', submitted: true),
        ],
      );
    await pumpGroup(
      tester,
      backend: b,
      initialLocation: Routes.groupTrip(tripId),
    );
    expect(find.text('Piso en Alfama'), findsOneWidget);
    // (formatMoney pone un espacio que no se parte entre 62 y €.)
    expect(find.text('62\u00a0€/persona'), findsOneWidget);
    // Con un solo listo, Empezar está apagado y se explica por qué.
    expect(
      find.text(
        'Hace falta que al menos dos personas envíen sus preferencias.',
      ),
      findsOneWidget,
    );

    await tester.enterText(
      find.widgetWithText(TextFormField, 'Máximo por persona'),
      '70',
    );
    // "Me gusta" es la primera fila de fichas y "Prefiero evitar" la segunda.
    await tester.tap(find.text('Playa').first);
    await tester.tap(find.text('Madrugar').last);
    await tester.pump();
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Una nota para tu agente'),
      'Viajo con mi perro',
    );
    await tester.tap(find.text('Enviar a mi agente'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(b.sentPrefs.single, <String, Object?>{
      'budget_max_minor': 7000,
      'interests': <String>['beach'],
      'avoid': <String>['early-starts'],
      'notes': 'Viajo con mi perro',
    });
    expect(find.text('Actualizar mis preferencias'), findsOneWidget);
    // Se espera a que se vaya el aviso "Enviado" (tapa el final de la lista).
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Empezar la negociación'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(b.starts, 1);
    expect(find.text('Los agentes están negociando'), findsOneWidget);
    // Sale de la pantalla: deja de preguntar (no queda ningún temporizador).
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('el resultado: la opción, por qué y lo que dijo cada agente', (
    WidgetTester tester,
  ) async {
    final GroupBackend b = GroupBackend()
      ..current = tripJson(
        status: 'concluded',
        members: <Map<String, Object?>>[
          member('Viajero 1', name: 'Darío', me: true, submitted: true),
          member('Viajero 2', name: 'Noelia', submitted: true),
        ],
        result: <String, Object?>{
          'outcome': 'arbitration',
          'chosen_option_id': 'op-1',
          'rounds': 3,
          'explanation': '',
          'excluded_over_budget': <String>['op-3', 'op-4'],
          'members': <Object?>[
            <String, Object?>{
              'alias': 'Viajero 1',
              'ranking': <String>['op-1', 'op-2'],
              'acceptable': <String>['op-1'],
              'argument': 'Prefiere fado y es la más barata.',
              'source': 'llm',
              'chosen_rank': 1,
            },
            <String, Object?>{
              'alias': 'Viajero 2',
              'ranking': <String>['op-2', 'op-1'],
              'acceptable': <String>['op-2'],
              'argument': '',
              'source': 'rules',
              'chosen_rank': 2,
            },
          ],
          'llm_used': true,
        },
      );
    await pumpGroup(
      tester,
      backend: b,
      initialLocation: Routes.groupTrip(tripId),
    );
    expect(find.text('Sin acuerdo: ha decidido el árbitro'), findsOneWidget);
    expect(find.textContaining('Tras 3 rondas sin acuerdo'), findsOneWidget);
    expect(
      find.text(
        'Se descartaron 2 opciones por superar el presupuesto de alguien.',
      ),
      findsOneWidget,
    );
    expect(find.text('Tu agente'), findsOneWidget);
    expect(find.text('Agente de Noelia'), findsOneWidget);
    expect(find.text('Su favorita'), findsOneWidget);
    expect(find.text('Su opción n.º 2'), findsOneWidget);
    expect(find.text('Decidido con reglas (sin IA)'), findsOneWidget);
    expect(find.text('Invita a tu grupo'), findsNothing);
  });
}
