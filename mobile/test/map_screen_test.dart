// Tests de las pantallas del Mapa y de la Audioguía, con el servidor, el
// GPS, el mapa y el reproductor falsos (ver helpers.dart).
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:eclipta/auth/session.dart';
import 'package:eclipta/core/router.dart';
import 'package:eclipta/core/settings.dart';
import 'package:eclipta/features/assistant/assistant_screen.dart';
import 'package:eclipta/features/audioguide/audioguide_screen.dart';
import 'package:eclipta/features/camera/stamps.dart';
import 'package:eclipta/features/flyra/flyra_mini.dart';
import 'package:eclipta/features/map/geo.dart';
import 'package:eclipta/features/map/location.dart';
import 'package:eclipta/features/map/street_photos_api.dart';
import 'package:eclipta/features/map/weather_overlay.dart';
import 'package:eclipta/features/passport/passport_screen.dart';

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

    await tester.tap(find.bySemanticsLabel('Escuchar la audioguía'));
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
    // El bocadillo de Flyra sale unos segundos y se va solo.
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Has entrado en Puerta del Sol'), findsOneWidget);
    expect(find.text('Escuchar ahora'), findsOneWidget);
    await tester.pumpAndSettle();
    expect(find.text('Has entrado en Puerta del Sol'), findsNothing);

    expect(map.me, solCenter);
    expect(map.calls, contains('flyTo ${solCenter.lat},${solCenter.lon}'));
    expect(find.text('ESTÁS EN LA ZONA'), findsOneWidget);
    expect(find.text('Puerta del Sol'), findsOneWidget);
    // 10 posiciones = un lote, enviado de una vez (no 10 peticiones).
    expect(
      g.calls.where((String c) => c == 'POST /v1/positions'),
      hasLength(1),
    );
  });

  testWidgets('tocar un aviso de audioguía abre la audioguía', (
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

  testWidgets('3D, girar, brújula, sellos nuevos, Flyra y buscar calles', (
    WidgetTester tester,
  ) async {
    final FakeGateway g = backend();
    g.services['/v1/geocode'] = (http.Request r) =>
        FakeGateway.json(<String, Object?>{
          'items': <Object?>[
            <String, Object?>{
              'name': 'Calle Mayor',
              'address': 'Calle Mayor, Madrid, España',
              'lat': 40.4155,
              'lon': -3.7074,
            },
          ],
        });
    final SessionController s = await signedInSession(g);
    final MemorySettingsStore prefs = MemorySettingsStore();
    await prefs.writeStamps(
      jsonEncode(<Object?>[
        for (int i = 0; i < 3; i++)
          Stamp(
            qid: 'Q$i',
            name: 'Monumento $i',
            date: DateTime.utc(2026, 10, 1 + i),
          ).toJson(),
      ]),
    );
    final FakeMap map = FakeMap();
    FlyraNotes.instance.reset();
    await pumpApp(
      tester,
      locale: 'es',
      initialLocation: Routes.map,
      session: s,
      services: fakeServices(s, gateway: g, map: map, prefs: prefs),
    );
    await settleMap(tester);

    // 3D ↔ 2D.
    expect(find.text('3D'), findsOneWidget);
    await tester.tap(find.text('3D'));
    await tester.pumpAndSettle();
    expect(find.text('2D'), findsOneWidget);
    expect(map.calls, contains('tilt 0.0'));

    // Girar 45° cada vez y la brújula vuelve al norte.
    await tester.tap(find.bySemanticsLabel('Girar el mapa'));
    await tester.tap(find.bySemanticsLabel('Girar el mapa'));
    await tester.pumpAndSettle();
    expect(map.bearing, 90);
    await tester.tap(find.bySemanticsLabel('Mirar al norte'));
    await tester.pumpAndSettle();
    expect(map.bearing, 0);

    // El tiempo y la hora real, sin botón de "Demo".
    expect(find.textContaining('Ahora: '), findsOneWidget);
    expect(find.textContaining('Automático · hora real'), findsOneWidget);
    expect(find.textContaining('Demo'), findsNothing);

    // 3 sellos sin ver: el número sale en la medalla y se va al abrirla.
    expect(find.bySemanticsLabel('Pasaporte de sellos, 3 nuevos'), findsOne);
    await tester.tap(find.bySemanticsLabel('Pasaporte de sellos, 3 nuevos'));
    await tester.pumpAndSettle();
    expect(find.byType(PassportScreen), findsOneWidget);
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.bySemanticsLabel('Pasaporte de sellos'), findsOne);

    // Un aviso nuevo de Flyra pone su punto rojo; tocarla abre el Asistente.
    FlyraNotes.instance.say(const FlyraNote(FlyraNoteKind.tip, 'Hola'));
    await tester.pumpAndSettle();
    await tester.tap(find.bySemanticsLabel('Habla con Flyra'));
    await tester.pumpAndSettle();
    expect(find.byType(AssistantScreen), findsOneWidget);
    await tester.tap(find.byTooltip('Cerrar'));
    await tester.pumpAndSettle();

    // Buscar una calle (OpenStreetMap) y volar hasta ella.
    await tester.enterText(find.byType(TextField), 'Calle Mayor');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    expect(find.text('Calle Mayor, Madrid, España'), findsOneWidget);
    await tester.tap(find.text('Calle Mayor, Madrid, España'));
    await tester.pumpAndSettle();
    expect(map.calls, contains('flyTo 40.4155,-3.7074'));
    FlyraNotes.instance.reset();
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
    // El botón del mapa (la barra de abajo también tiene la pestaña Ajustes).
    expect(find.widgetWithText(TextButton, 'Ajustes'), findsOneWidget);
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

  testWidgets('audioguía: foto real, ¿Sabías que…?, subtítulos y recorrido', (
    WidgetTester tester,
  ) async {
    final FakeGateway g = backend();
    final List<Uri> asked = <Uri>[];
    final List<Uri> opened = <Uri>[];
    g.services['/v1/landmarks/near'] = (http.Request r) {
      asked.add(r.url);
      return FakeGateway.json(<String, Object?>{
        'qid': 'Q1503138',
        'name': 'Real Casa de Correos',
        'lat': 40.4167,
        'lon': -3.7035,
        'distance_m': 40,
        'photo': <String, Object?>{
          'url': 'https://upload.wikimedia.org/x/800px-Correos.jpg',
          'page_url': 'https://commons.wikimedia.org/wiki/File:Correos.jpg',
        },
        'summary': 'Su reloj da las campanadas de Nochevieja.',
        'article_url': 'https://es.wikipedia.org/wiki/Real_Casa_de_Correos',
      });
    };
    final SessionController s = await signedInSession(g);
    final List<FakePlayer> players = <FakePlayer>[];
    await pumpApp(
      tester,
      locale: 'es',
      initialLocation: Routes.audioguide(
        solId,
        'Puerta del Sol',
        lat: 40.4168,
        lon: -3.7038,
      ),
      session: s,
      services: fakeServices(
        s,
        gateway: g,
        players: players,
        openBooking: (Uri u) async {
          opened.add(u);
          return true;
        },
      ),
    );
    await tester.pumpAndSettle();
    expect(asked.single.queryParameters, <String, String>{
      'lat': '40.41680',
      'lon': '-3.70380',
      'lang': 'es',
    });
    expect(find.textContaining('Foto de Real Casa de Correos'), findsOneWidget);
    await tester.tap(find.textContaining('Foto de Real Casa de Correos'));
    await tester.pumpAndSettle();
    expect(opened.single.host, 'commons.wikimedia.org');
    final Finder subs = find.text('SUBTÍTULOS EN DIRECTO');
    await tester.scrollUntilVisible(subs, 200);
    expect(subs, findsOneWidget);

    final Finder know = find.text('¿SABÍAS QUE…?');
    await tester.scrollUntilVisible(know, 200);
    expect(
      find.text('Su reloj da las campanadas de Nochevieja.'),
      findsOneWidget,
    );
    final Finder route = find.text('Tu recorrido');
    await tester.scrollUntilVisible(route, 200);
    expect(find.text('2 partes · quedan 1 min'), findsOneWidget);
    await tester.tap(find.text('Parte 2'));
    await tester.pumpAndSettle();
    expect(players.single.state.value.part, 1);
  });

  test('los subtítulos se iluminan por palabras enteras', () {
    const String text = 'Bienvenida a la plaza.';
    expect(guideSpokenUpTo(text, 0), 0);
    expect(guideSpokenUpTo(text, 1), text.length);
    // A mitad, nunca corta una palabra.
    final int cut = guideSpokenUpTo(text, 0.5);
    expect(text.substring(0, cut), 'Bienvenida a');
  });

  test('el tiempo del mapa sale del de verdad (MET Norway)', () {
    expect(mapWeatherFrom(0, 'clearsky_day'), MapWeather.sun);
    expect(mapWeatherFrom(0, 'partlycloudy_night'), MapWeather.clouds);
    expect(mapWeatherFrom(0, 'fog'), MapWeather.clouds);
    expect(mapWeatherFrom(0, 'lightrainshowers_day'), MapWeather.rain);
    expect(mapWeatherFrom(1.2, null), MapWeather.rain);
    expect(mapWeatherFrom(0, null), MapWeather.sun);
  });
}
