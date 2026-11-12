// Tests del modo cámara: apuntar, "Reconocer", ver la ficha, escucharla,
// guardar el sello, elegir otro lugar y los avisos (sin cuenta, sin cámara,
// sin usos hoy). Cámara, brújula, GPS y servidor son falsos.
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
import 'package:eclipta/features/passport/passport_screen.dart';

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
    initialLocation: Routes.cameraScan,
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

/// La pantalla tiene animaciones sin fin (el escáner): no se puede esperar a
/// que "se calme", así que se avanza un rato fijo.
/// La cámara mira sola cada 3 s si el móvil está quieto: la primera vuelta
/// apunta hacia dónde miras y la segunda ya mira.
Future<void> detect(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 3));
  await tester.pump(const Duration(seconds: 3));
  await settle(tester);
}

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

  testWidgets('la cámara ve sola el monumento, Aceptar pone la audioguía', (
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
    // Buscando: sin botón de disparar, con las pistas que ya tiene.
    expect(find.text('Apunta a un monumento…'), findsOneWidget);
    expect(find.text('Buscando monumentos cerca…'), findsOneWidget);
    expect(find.text('🧭 Brújula: miras al sur'), findsOneWidget);
    expect(find.bySemanticsLabel('Reconocer'), findsNothing);

    await detect(tester);
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
    expect(find.text('¡Monumento detectado!'), findsOneWidget);
    expect(find.text('FLYRA · MONUMENTO DETECTADO'), findsOneWidget);
    expect(find.text('👁️ La forma coincide'), findsOneWidget);
    expect(find.text('Real Casa de Correos'), findsOneWidget); // el recuadro

    await tester.tap(find.text('Aceptar'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Abriendo la audioguía…'), findsOneWidget);
    expect(find.text('Real Casa de Correos · en español'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 900));
    await settle(tester);
    expect(find.text('Abriendo la audioguía…'), findsNothing);
    expect(find.text('Monumento reconocido'), findsOneWidget);
    expect(find.text('RECONOCIDO'), findsOneWidget);
    expect(find.text('1768'), findsOneWidget);
    expect(find.text('33 m'), findsOneWidget);
    expect(find.text('Raro'), findsOneWidget);
    expect(voice.said.single, contains('campanadas'));

    // Reconocido en la foto: el sello ya es tuyo (con dónde está).
    expect(StampBook(prefs).has('Q1503138'), isTrue);
    expect(StampBook(prefs).all().single.lat, isNotNull);
    await tester.tap(find.text('Ver mi sello'));
    await settle(tester);
    expect(find.byType(PassportScreen), findsOneWidget);
  });

  testWidgets('Cancelar enseña la ficha sin leerla y no vuelve a preguntar', (
    WidgetTester tester,
  ) async {
    final LandmarkBackend b = LandmarkBackend();
    final FakeSpeaker voice = FakeSpeaker();
    await pumpCamera(tester, b: b, camera: FakeCamera.new, speaker: voice);
    await settle(tester);
    await detect(tester);
    await tester.tap(find.text('Cancelar'));
    await settle(tester);
    expect(find.text('FLYRA · MONUMENTO DETECTADO'), findsNothing);
    expect(find.text('RECONOCIDO'), findsOneWidget);
    expect(voice.said, isEmpty);

    // "Escanear otra vez" mira ya mismo; por el mismo ya no pregunta.
    await tester.tap(find.byTooltip('Escanear otra vez'));
    await settle(tester);
    expect(b.sent, hasLength(2));
    expect(find.text('Apunta a un monumento…'), findsOneWidget);
    expect(find.text('FLYRA · MONUMENTO DETECTADO'), findsNothing);
  });

  testWidgets('si nadie contesta, el aviso se cierra y queda la ficha', (
    WidgetTester tester,
  ) async {
    final LandmarkBackend b = LandmarkBackend();
    final FakeSpeaker voice = FakeSpeaker();
    await pumpCamera(tester, b: b, camera: FakeCamera.new, speaker: voice);
    await settle(tester);
    await detect(tester);
    expect(find.text('FLYRA · MONUMENTO DETECTADO'), findsOneWidget);
    await tester.pump(const Duration(seconds: 9));
    await settle(tester);
    expect(find.text('FLYRA · MONUMENTO DETECTADO'), findsNothing);
    expect(find.text('RECONOCIDO'), findsOneWidget);
    expect(voice.said, isEmpty);
  });

  testWidgets('nada famoso cerca: sigue buscando', (WidgetTester tester) async {
    final LandmarkBackend b = LandmarkBackend()
      ..response = <String, Object?>{
        'status': 'none',
        'alternatives': <Object?>[],
        'attribution': 'Wikipedia',
      };
    await pumpCamera(tester, b: b, camera: FakeCamera.new);
    await settle(tester);
    await detect(tester);
    expect(b.sent, hasLength(1));
    expect(find.text('Apunta a un monumento…'), findsOneWidget);
    expect(find.text('FLYRA · MONUMENTO DETECTADO'), findsNothing);
  });

  testWidgets('sin usos hoy: lo dice y deja de mirar', (
    WidgetTester tester,
  ) async {
    final LandmarkBackend b = LandmarkBackend()..failWith = 429;
    await pumpCamera(tester, b: b, camera: FakeCamera.new);
    await settle(tester);
    await detect(tester);
    expect(find.textContaining('escaneos gratis de hoy'), findsOneWidget);
    await tester.tap(find.byTooltip('Escanear otra vez'));
    await detect(tester);
    expect(b.sent, hasLength(1));
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
    // A pantalla completa, sin la barra: se sale con la X.
    expect(find.text('Inicio'), findsNothing);
    await tester.tap(find.byTooltip('Cerrar la cámara'));
    await settle(tester);
    expect(made.single.disposed, isTrue);
    await tester.tap(find.byTooltip('Cámara'));
    await settle(tester);
    expect(made, hasLength(2));
    // El Mapa (debajo) empezó a mandar tu posición: se deja terminar el lote.
    await tester.pump(const Duration(seconds: 61));
  });
}
