// Tests de la cámara: al abrirla es normal (no busca nada), el botón verde
// hace la foto y deja guardarla o compartirla, y el botón de identificar
// monumento muestra la ficha, la escucha, el sello, elegir otro lugar y los
// avisos (sin cuenta, sin cámara, sin usos hoy, servidor sin IA).
// Cámara, brújula, GPS y servidor son falsos.
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:eclipta/auth/session.dart';
import 'package:eclipta/core/api_client.dart';
import 'package:eclipta/core/router.dart';
import 'package:eclipta/core/settings.dart';
import 'package:eclipta/features/camera/camera_device.dart';
import 'package:eclipta/features/camera/landmarks_api.dart';
import 'package:eclipta/features/camera/speaker.dart';
import 'package:eclipta/features/camera/stamps.dart';
import 'package:eclipta/features/map/geo.dart';
import 'package:eclipta/features/map/location.dart';

import 'helpers.dart';

class FakeCamera implements CameraDevice {
  FakeCamera([this.result = CameraStart.ready]);

  final CameraStart result;
  int photos = 0;
  bool disposed = false;

  @override
  Future<CameraStart> start() async => result;

  @override
  Widget preview() => const ColoredBox(color: Colors.blueGrey);

  @override
  Future<Uint8List> takePhoto() async {
    photos++;
    return Uint8List.fromList(<int>[0xff, 0xd8, 0xff, 0xe0, 1, 2, 3]);
  }

  @override
  Stream<double?> heading() => Stream<double?>.value(180);

  @override
  Future<void> dispose() async => disposed = true;
}

class FakeSpeaker implements Speaker {
  final List<String> said = <String>[];

  @override
  Future<void> speak(String text, String language) async => said.add(text);

  @override
  Future<void> stop() async {}
}

/// Un GPS que ya tiene permiso y da la Puerta del Sol.
class SolLocation extends FakeLocation {
  SolLocation() {
    access = LocationAccess.granted;
  }

  @override
  Stream<PositionFix> watch({TrackingNotice? background}) =>
      Stream<PositionFix>.value(
        PositionFix(
          point: const GeoPoint(40.4169, -3.7036),
          accuracyM: 12,
          recordedAt: DateTime.utc(2026, 10, 23),
        ),
      );
}

const Map<String, Object?> correos = <String, Object?>{
  'qid': 'Q1503138',
  'name': 'Real Casa de Correos',
  'description': 'edificio de Madrid',
  'lat': 40.4166,
  'lon': -3.7036,
  'year': 1768,
  'summary': 'Su reloj da las campanadas de Nochevieja.',
  'article_url': 'https://es.wikipedia.org/wiki/Real_Casa_de_Correos',
  'distance_m': 33,
};

class LandmarkBackend {
  LandmarkBackend() {
    g.services['/v1/landmarks/recognize'] = (http.Request r) {
      sent.add(jsonDecode(r.body) as Map<String, Object?>);
      if (failWith != null) return http.Response('{}', failWith!);
      return FakeGateway.json(response);
    };
    g.services['/v1/landmarks/Q2633064'] = (http.Request r) =>
        FakeGateway.json(<String, Object?>{
          'qid': 'Q2633064',
          'name': 'El Oso y el Madroño',
          'lat': 40.417,
          'lon': -3.7038,
          'year': 1967,
        });
  }

  final FakeGateway g = FakeGateway();
  final List<Map<String, Object?>> sent = <Map<String, Object?>>[];
  int? failWith;
  Map<String, Object?> response = <String, Object?>{
    'status': 'recognized',
    'landmark': correos,
    'alternatives': <Object?>[
      <String, Object?>{
        'qid': 'Q2633064',
        'name': 'El Oso y el Madroño',
        'distance_m': 20,
      },
    ],
    'attribution': 'Wikipedia',
  };
}

Future<void> pumpCamera(
  WidgetTester tester, {
  required LandmarkBackend b,
  CameraFactory? camera,
  Speaker? speaker,
  MemorySettingsStore? prefs,
  bool guest = false,
}) async {
  tester.view.physicalSize = const Size(1200, 3000);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  final SessionController s = guest
      ? (newSession(b.g)..continueAsGuest())
      : await signedInSession(b.g);
  await pumpApp(
    tester,
    locale: 'es',
    session: s,
    initialLocation: Routes.camera,
    settle: false,
    services: fakeServices(
      s,
      gateway: b.g,
      location: SolLocation(),
      prefs: prefs,
      newCamera: camera,
      speaker: speaker,
    ),
  );
}

/// Se avanza un rato fijo (más sencillo que esperar a que todo se calme).
Future<void> settle(WidgetTester tester) async {
  for (int i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  group('lo que llega del servidor', () {
    test('se rechaza lo raro', () {
      expect(
        () => Recognition.parse(<String, Object?>{'status': 'raro'}),
        throwsA(isA<ApiException>()),
      );
      expect(
        () => Recognition.parse(<String, Object?>{'status': 'guess'}),
        throwsA(isA<ApiException>()),
      );
      final Landmark l = Landmark.parse(<String, Object?>{
        ...correos,
        'article_url': 'https://malo.example/wiki/x',
      });
      expect(l.articleUrl, isNull); // solo enlaces de Wikipedia
      expect(l.year, 1768);
    });

    test('un sello por monumento', () async {
      final MemorySettingsStore prefs = MemorySettingsStore();
      final StampBook book = StampBook(prefs);
      final Stamp one = Stamp(qid: 'Q1', name: 'Uno', date: DateTime.utc(2026));
      expect(await book.add(one), isTrue);
      expect(await book.add(one), isFalse);
      expect(book.all().single.name, 'Uno');
    });
  });

  testWidgets('al abrir es una cámara normal: no envía nada al servidor', (
    WidgetTester tester,
  ) async {
    final LandmarkBackend b = LandmarkBackend();
    final FakeCamera cam = FakeCamera();
    await pumpCamera(tester, b: b, camera: () => cam);
    await settle(tester);
    expect(
      find.text('Toca el botón verde para hacer una foto'),
      findsOneWidget,
    );
    expect(find.text('Buscando…'), findsNothing);
    expect(cam.photos, 0);
    expect(b.sent, isEmpty);
  });

  testWidgets('el botón verde hace la foto y se guarda en Recuerdos', (
    WidgetTester tester,
  ) async {
    final LandmarkBackend b = LandmarkBackend();
    final FakeCamera cam = FakeCamera();
    await pumpCamera(tester, b: b, camera: () => cam);
    await settle(tester);

    await tester.tap(find.bySemanticsLabel('Hacer foto'));
    await settle(tester);
    expect(cam.photos, 1);
    expect(b.sent, isEmpty); // hacer una foto no identifica nada
    expect(find.text('Guardar en Recuerdos'), findsOneWidget);
    expect(find.text('Compartir'), findsOneWidget);

    await tester.tap(find.text('Guardar en Recuerdos'));
    await settle(tester);
    expect(find.text('Guardado en Recuerdos'), findsWidgets);

    await tester.tap(find.text('Repetir'));
    await settle(tester);
    expect(
      find.text('Toca el botón verde para hacer una foto'),
      findsOneWidget,
    );
  });

  testWidgets('apuntar, identificar, escuchar y guardar el sello', (
    WidgetTester tester,
  ) async {
    final LandmarkBackend b = LandmarkBackend();
    final FakeCamera cam = FakeCamera();
    final FakeSpeaker voice = FakeSpeaker();
    final MemorySettingsStore prefs = MemorySettingsStore('es');
    await pumpCamera(
      tester,
      b: b,
      camera: () => cam,
      speaker: voice,
      prefs: prefs,
    );
    await settle(tester);
    expect(b.sent, isEmpty);

    await tester.tap(find.byTooltip('Identificar monumento'));
    await settle(tester);

    expect(cam.photos, 1);
    final Map<String, Object?> body = b.sent.single;
    expect(body['heading'], 180);
    expect(body['language'], 'es');
    expect(body['lat'], 40.4169);
    expect(base64Decode(body['image']! as String).take(3), <int>[
      0xff,
      0xd8,
      0xff,
    ]);
    expect(find.text('RECONOCIDO'), findsOneWidget);
    expect(find.text('Real Casa de Correos'), findsWidgets);
    expect(find.text('1768'), findsOneWidget);
    expect(find.text('33 m'), findsOneWidget);

    await tester.tap(find.text('Escuchar'));
    await settle(tester);
    expect(voice.said.single, contains('campanadas'));

    await tester.tap(find.text('Mi sello'));
    await settle(tester);
    expect(find.text('Sello guardado'), findsOneWidget);
    expect(StampBook(prefs).has('Q1503138'), isTrue);
    // El sello guarda dónde está, para su página del Pasaporte.
    expect(StampBook(prefs).all().single.lat, isNotNull);

    // "¿No es este?": se elige el Oso y se ve su ficha.
    await tester.tap(find.textContaining('El Oso y el Madroño'));
    await settle(tester);
    expect(find.text('1967'), findsOneWidget);
    expect(find.text('¿ES ESTE?'), findsOneWidget);

    // "Escanear otra vez" vuelve a identificar.
    await tester.tap(find.byTooltip('Escanear otra vez'));
    await settle(tester);
    expect(b.sent, hasLength(2));

    // Apagar el modo identificar deja la cámara normal otra vez.
    await tester.tap(find.byTooltip('Identificar monumento'));
    await settle(tester);
    expect(find.text('RECONOCIDO'), findsNothing);
    expect(
      find.text('Toca el botón verde para hacer una foto'),
      findsOneWidget,
    );
  });

  testWidgets('nada famoso cerca', (WidgetTester tester) async {
    final LandmarkBackend b = LandmarkBackend()
      ..response = <String, Object?>{
        'status': 'none',
        'alternatives': <Object?>[],
        'attribution': 'Wikipedia',
      };
    await pumpCamera(tester, b: b, camera: FakeCamera.new);
    await settle(tester);
    await tester.tap(find.byTooltip('Identificar monumento'));
    await settle(tester);
    expect(find.textContaining('No reconozco ningún lugar'), findsOneWidget);
  });

  testWidgets('sin usos hoy: aviso y el botón se apaga', (
    WidgetTester tester,
  ) async {
    final LandmarkBackend b = LandmarkBackend()..failWith = 429;
    await pumpCamera(tester, b: b, camera: FakeCamera.new);
    await settle(tester);
    await tester.tap(find.byTooltip('Identificar monumento'));
    await settle(tester);
    expect(find.textContaining('escaneos gratis de hoy'), findsOneWidget);
    await tester.tap(find.byTooltip('Escanear otra vez'));
    await settle(tester);
    expect(b.sent, hasLength(1));
  });

  testWidgets('servidor sin IA (404): mensaje de "no activado"', (
    WidgetTester tester,
  ) async {
    final LandmarkBackend b = LandmarkBackend()..failWith = 404;
    await pumpCamera(tester, b: b, camera: FakeCamera.new);
    await settle(tester);
    await tester.tap(find.byTooltip('Identificar monumento'));
    await settle(tester);
    expect(find.textContaining('aún no está activada'), findsOneWidget);
  });

  testWidgets('sin permiso de cámara', (WidgetTester tester) async {
    final LandmarkBackend b = LandmarkBackend();
    await pumpCamera(
      tester,
      b: b,
      camera: () => FakeCamera(CameraStart.denied),
    );
    await settle(tester);
    expect(find.text('Permitir la cámara'), findsOneWidget);
  });

  testWidgets('invitado: pide iniciar sesión y no enciende la cámara', (
    WidgetTester tester,
  ) async {
    final LandmarkBackend b = LandmarkBackend();
    final FakeCamera cam = FakeCamera();
    bool made = false;
    await pumpCamera(
      tester,
      b: b,
      guest: true,
      camera: () {
        made = true;
        return cam;
      },
    );
    await settle(tester);
    expect(find.textContaining('Inicia sesión para usar'), findsOneWidget);
    expect(made, isFalse);
  });

  testWidgets('al cambiar de pestaña la cámara se apaga', (
    WidgetTester tester,
  ) async {
    final LandmarkBackend b = LandmarkBackend();
    final List<FakeCamera> made = <FakeCamera>[];
    await pumpCamera(
      tester,
      b: b,
      camera: () {
        final FakeCamera c = FakeCamera();
        made.add(c);
        return c;
      },
    );
    await settle(tester);
    expect(made, hasLength(1));
    await tester.tap(find.text('Inicio'));
    await settle(tester);
    expect(made.single.disposed, isTrue);
    await tester.tap(find.byTooltip('Cámara'));
    await settle(tester);
    expect(made, hasLength(2));
  });
}
