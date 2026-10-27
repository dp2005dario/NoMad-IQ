// Tests de las pantallas del Mapa y de la Audioguía, con el servidor, el
// GPS, el mapa y el reproductor falsos (ver helpers.dart).
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:eclipta/auth/session.dart';
import 'package:eclipta/core/router.dart';
import 'package:eclipta/features/map/geo.dart';
import 'package:eclipta/features/map/location.dart';
import 'package:eclipta/features/map/street_photos_api.dart';

import 'helpers.dart';
import 'zones_fixture.dart';

/// Un backend con zonas y la audioguía de la Puerta del Sol.
FakeGateway backend({bool audioReady = true, int scriptMissing = 0}) {
  final FakeGateway g = FakeGateway();
  int missing = scriptMissing;
  g.services['/v1/zones'] = (_) => FakeGateway.json(zonesCollection());
  g.services['/v1/positions'] = (http.Request r) {
    final Map<String, Object?> body =
        jsonDecode(r.body) as Map<String, Object?>;
    final int n = (body['positions']! as List<Object?>).length;
    return FakeGateway.json(<String, Object?>{'accepted': n}, 202);
  };
  g.services['/v1/audioguides/$solId'] = (_) {
    if (missing-- > 0) return http.Response('', 404);
    return FakeGateway.json(<String, Object?>{
      'zone_id': solId,
      'zone_name': 'Puerta del Sol',
      'language': 'es',
      'content_language': 'es',
      'title': 'El corazón de Madrid',
      'segments': <Object?>[
        <String, Object?>{
          'text': 'Bienvenida a la plaza.',
          'fact_ids': <String>['F1'],
        },
        <String, Object?>{
          'text': 'El Kilómetro Cero.',
          'fact_ids': <String>['F2'],
        },
      ],
      'facts': <Object?>[],
      'source': 'rules',
      'model': '',
      'content_version': 3,
      'generated_at': '2026-10-23T10:00:00Z',
    });
  };
  g.services['/v1/audioguides/$solId/audio'] = (_) {
    if (!audioReady) return http.Response('', 404);
    return FakeGateway.json(<String, Object?>{
      'zone_id': solId,
      'language': 'es',
      'content_language': 'es',
      'content_version': 3,
      'audio_content_version': 3,
      'stale': false,
      'source': 'rules',
      'voice': 'es_ES-davefx-medium',
      'total_seconds': 50.0,
      'parts': <Object?>[
        <String, Object?>{
          'index': 2,
          'url': '/v1/audio/puerta-del-sol/es/v3/abc/parte-2.opus',
          'duration_seconds': 22.0,
          'text': 'El Kilómetro Cero.',
        },
        <String, Object?>{
          'index': 1,
          'url': '/v1/audio/puerta-del-sol/es/v3/abc/parte-1.opus',
          'duration_seconds': 28.0,
          'text': 'Bienvenida a la plaza.',
        },
      ],
    });
  };
  return g;
}

/// El mapa espera 350 ms quieto antes de pedir zonas.
Future<void> settleMap(WidgetTester tester) async {
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('zonas en el mapa, tocar una y escuchar su audioguía', (
    WidgetTester tester,
  ) async {
    final FakeGateway g = backend();
    final SessionController s = await signedInSession(g);
    final FakeMap map = FakeMap();
    final List<FakePlayer> players = <FakePlayer>[];
    await pumpApp(
      tester,
      locale: 'es',
      initialLocation: Routes.map,
      session: s,
      services: fakeServices(s, gateway: g, map: map, players: players),
    );
    await settleMap(tester);

    // Las 3 zonas llegaron al mapa.
    expect((map.zones!['features']! as List<Object?>), hasLength(3));
    expect(find.text('Activar ubicación'), findsOneWidget);
    expect(find.text('Cerca de ti'), findsOneWidget);

    // Tocar dentro de la Puerta del Sol la selecciona (no el centro entero).
    map.spec!.onTap(solCenter);
    await tester.pumpAndSettle();
    expect(find.text('Puerta del Sol'), findsOneWidget);
    expect(find.text('ZONA TURÍSTICA'), findsOneWidget);
    expect(jsonEncode(map.zones), contains('"selected":true'));

    await tester.tap(find.text('Escuchar la audioguía'));
    await tester.pumpAndSettle();
    expect(find.text('El corazón de Madrid'), findsOneWidget);
    expect(find.text('Parte 1 de 2'), findsOneWidget);
    // Las partes llegan desordenadas y la app las ordena; las rutas se
    // completan con la dirección de la puerta de entrada.
    expect(players.single.loaded.map((Uri u) => u.toString()), <String>[
      'http://gateway.test/v1/audio/puerta-del-sol/es/v3/abc/parte-1.opus',
      'http://gateway.test/v1/audio/puerta-del-sol/es/v3/abc/parte-2.opus',
    ]);
    // Lo que se ve con el móvil bloqueado.
    expect(players.single.info?.album, 'Puerta del Sol');
    expect(players.single.info?.titles, <String>[
      'Parte 1 de 2 · El corazón de Madrid',
      'Parte 2 de 2 · El corazón de Madrid',
    ]);

    await tester.tap(find.byIcon(Icons.play_arrow_rounded));
    await tester.pumpAndSettle();
    expect(players.single.state.value.playing, isTrue);
    expect(find.text('SONANDO'), findsOneWidget);

    await tester.tap(find.widgetWithText(ChoiceChip, '2'));
    await tester.pumpAndSettle();
    expect(find.text('Parte 2 de 2'), findsOneWidget);
    expect(find.text('El Kilómetro Cero.'), findsOneWidget);

    await tester.tap(find.text('1×'));
    await tester.pumpAndSettle();
    expect(find.text('1,25×'), findsOneWidget);
    expect(players.single.speed, 1.25);

    // Al salir, el reproductor se apaga.
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(players.single.disposed, isTrue);
  });

  testWidgets('al activar la ubicación avisa al entrar y manda posiciones', (
    WidgetTester tester,
  ) async {
    final FakeGateway g = backend();
    final SessionController s = await signedInSession(g);
    final FakeMap map = FakeMap();
    final FakeLocation loc = FakeLocation();
    await pumpApp(
      tester,
      locale: 'es',
      initialLocation: Routes.map,
      session: s,
      services: fakeServices(s, gateway: g, map: map, location: loc),
    );
    await settleMap(tester);
    expect(loc.requests, 0); // nunca se pregunta sin pulsar el botón

    await tester.tap(find.text('Activar ubicación'));
    await tester.pumpAndSettle();
    expect(loc.requests, 1);
    expect(find.text('Activar ubicación'), findsNothing);

    final DateTime t0 = DateTime.now();
    for (int i = 0; i < 10; i++) {
      loc.fixes.add(
        PositionFix(
          point: solCenter,
          accuracyM: 6,
          recordedAt: t0.add(Duration(seconds: i * 2)),
        ),
      );
      await tester.pump();
    }
    await tester.pumpAndSettle();

    expect(map.me, solCenter);
    expect(map.calls, contains('flyTo ${solCenter.lat},${solCenter.lon}'));
    expect(find.text('Has entrado en Puerta del Sol'), findsOneWidget);
    expect(find.text('ESTÁS EN LA ZONA'), findsOneWidget);
    // 10 posiciones = un lote, enviado de una vez (no 10 peticiones).
    expect(
      g.calls.where((String c) => c == 'POST /v1/positions'),
      hasLength(1),
    );
  });

  testWidgets('modo viaje desde el mapa; tocar un aviso abre la audioguía', (
    WidgetTester tester,
  ) async {
    final FakeGateway g = backend();
    final SessionController s = await signedInSession(g);
    final FakeLocation loc = FakeLocation()..access = LocationAccess.granted;
    final FakeNotices notices = FakeNotices();
    await pumpApp(
      tester,
      locale: 'es',
      initialLocation: Routes.map,
      session: s,
      services: fakeServices(s, gateway: g, location: loc, notices: notices),
    );
    await settleMap(tester);

    await tester.tap(find.text('Modo viaje'));
    await tester.pumpAndSettle();
    expect(notices.asked, 1);
    expect(loc.watches.last, isTrue); // GPS con notificación fija
    expect(
      find.text('Modo viaje activado: te aviso aunque cierres la app.'),
      findsOneWidget,
    );

    // El usuario toca el aviso "Audioguía cerca" de la barra del móvil.
    notices.tapsController.add(Routes.audioguide(solId, ''));
    await tester.pumpAndSettle();
    expect(find.text('El corazón de Madrid'), findsOneWidget);
  });

  testWidgets('un invitado ve el mapa pero se le invita a crear cuenta', (
    WidgetTester tester,
  ) async {
    await pumpApp(tester, locale: 'es', initialLocation: Routes.map);
    await settleMap(tester);
    expect(
      find.text('Crea una cuenta para ver las zonas y las audioguías.'),
      findsOneWidget,
    );
  });

  testWidgets('el permiso denegado para siempre ofrece abrir Ajustes', (
    WidgetTester tester,
  ) async {
    final FakeLocation loc = FakeLocation()
      ..onRequest = LocationAccess.deniedForever;
    final SessionController s = newSession()..continueAsGuest();
    await pumpApp(
      tester,
      locale: 'es',
      initialLocation: Routes.map,
      session: s,
      services: fakeServices(s, location: loc),
    );
    await tester.tap(find.text('Activar ubicación'));
    await tester.pumpAndSettle();
    expect(find.text('Ajustes'), findsOneWidget);
  });

  testWidgets('el mapa en árabe (de derecha a izquierda) cabe en pantalla', (
    WidgetTester tester,
  ) async {
    await pumpApp(tester, locale: 'ar', initialLocation: Routes.map);
    await settleMap(tester);
    expect(tester.takeException(), isNull);
    expect(find.text('تفعيل الموقع'), findsOneWidget);
  });

  testWidgets('audioguía aún en preparación: espera y se reintenta sola', (
    WidgetTester tester,
  ) async {
    final FakeGateway g = backend(scriptMissing: 1, audioReady: false);
    final SessionController s = await signedInSession(g);
    await pumpApp(
      tester,
      locale: 'es',
      initialLocation: Routes.audioguide(solId, 'Puerta del Sol'),
      session: s,
      services: fakeServices(s, gateway: g),
    );
    // pumpApp espera a que todo se calme: por el camino pasaron los 5 s y
    // la app volvió a preguntar sola.
    expect(
      g.calls.where((String c) => c == 'GET /v1/audioguides/$solId'),
      hasLength(2),
    );
    // Sin audio todavía: se lee el guion completo.
    expect(
      find.textContaining('El audio aún se está grabando'),
      findsOneWidget,
    );
    expect(find.text('Bienvenida a la plaza.'), findsOneWidget);
    expect(find.text('El Kilómetro Cero.'), findsOneWidget);
  });

  testWidgets('audioguía para invitados: invita a entrar', (
    WidgetTester tester,
  ) async {
    await pumpApp(
      tester,
      locale: 'es',
      initialLocation: Routes.audioguide(solId, 'Puerta del Sol'),
    );
    expect(
      find.textContaining('Las audioguías son para cuentas'),
      findsOneWidget,
    );
    await tester.tap(find.text('Inicia sesión o crea una cuenta'));
    await tester.pumpAndSettle();
    expect(find.text('Iniciar sesión'), findsWidgets);
  });

  testWidgets('"Ver la calle de verdad" enseña fotos reales del centro', (
    WidgetTester tester,
  ) async {
    final FakeGateway g = backend();
    final List<Uri> asked = <Uri>[];
    g.services['/v1/streetview'] = (http.Request r) {
      asked.add(r.url);
      const String cdn = 'https://scontent.xx.fbcdn.net/a.jpg';
      return FakeGateway.json(<String, Object?>{
        'lat': 40.415,
        'lon': -3.705,
        'attribution': 'Mapillary (CC BY-SA 4.0)',
        'license_url': 'https://creativecommons.org/licenses/by-sa/4.0/',
        'photos': <Object?>[
          <String, Object?>{
            'id': '1',
            'lat': 40.4151,
            'lon': -3.7049,
            'captured_at': '2023-07-22T04:26:40Z',
            'compass_angle': 90.0,
            'is_pano': false,
            'thumb_url': cdn,
            'image_url': cdn,
            'creator': 'ana',
            'page_url': 'https://www.mapillary.com/app/?pKey=1&focus=photo',
          },
          // Una con enlace inseguro: se descarta, no rompe nada.
          <String, Object?>{
            'id': '2',
            'lat': 40.4152,
            'lon': -3.7048,
            'thumb_url': 'http://x.test/a.jpg',
            'image_url': cdn,
            'page_url': 'https://www.mapillary.com/app/?pKey=2',
          },
        ],
      });
    };
    final SessionController s = await signedInSession(g);
    await pumpApp(
      tester,
      locale: 'es',
      initialLocation: Routes.map,
      session: s,
      services: fakeServices(s, gateway: g, map: FakeMap()),
    );
    await settleMap(tester);

    await tester.tap(find.text('Ver la calle de verdad'));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('La calle de verdad'), findsOneWidget);
    expect(find.text('Foto: ana · Hecha en 2023'), findsOneWidget);
    expect(find.text('Abrir en Mapillary'), findsOneWidget);
    // Solo sale del móvil el centro redondeado a ~100 m.
    expect(asked.single.queryParameters, <String, String>{
      'lat': '40.415',
      'lon': '-3.705',
    });
  });

  test('las fotos de calle solo se aceptan con enlaces https', () {
    expect(
      StreetPhoto.parse(<String, Object?>{
        'id': '1',
        'lat': 1,
        'lon': 2,
        'thumb_url': 'javascript:alert(1)',
        'image_url': 'https://a.test/x.jpg',
        'page_url': 'https://a.test',
      }),
      isNull,
    );
    final GeoPoint cell = streetCell(const GeoPoint(40.41694, -3.70361));
    expect((cell.lat, cell.lon), (40.417, -3.704));
  });
}
