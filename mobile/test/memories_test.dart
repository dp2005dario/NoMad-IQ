// Recuerdos: las cuentas de la historia, la lista guardada en el móvil, la
// cámara de viaje (foto con pegatina → guardada → compartir) y la historia.
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:eclipta/core/router.dart';
import 'package:eclipta/core/settings.dart';
import 'package:eclipta/features/camera/camera_device.dart' show CameraStart;
import 'package:eclipta/features/camera/stamps.dart';
import 'package:eclipta/features/memories/memories.dart';
import 'package:eclipta/features/memories/memories_page.dart';
import 'package:eclipta/features/memories/memories_screen.dart';
import 'package:eclipta/features/memories/travel_camera.dart';
import 'package:eclipta/features/memories/travel_camera_screen.dart';
import 'package:eclipta/features/camera/camera_screen.dart';

import 'package:eclipta/core/services.dart';
import 'package:eclipta/l10n/generated/app_localizations.dart';

import 'helpers.dart';
import 'money_test.dart' as m;

/// Una cámara falsa: "hace" fotos de 3 bytes y vídeos que no existen.
class FakeTravelCamera implements TravelCamera {
  CameraStart answer = CameraStart.ready;
  int photos = 0;
  bool recording = false;

  @override
  Future<CameraStart> start({required bool video}) async => answer;

  @override
  Widget preview() => const ColoredBox(color: Colors.black);

  @override
  Future<Uint8List> takePhoto() async {
    photos++;
    return Uint8List.fromList(<int>[1, 2, 3]);
  }

  @override
  Future<void> startVideo() async => recording = true;

  @override
  Future<String> stopVideo() async {
    recording = false;
    return '/tmp/video.mp4';
  }

  @override
  Future<void> flip() async {}

  @override
  Future<void> dispose() async {}
}

Memory photo(String file, DateTime at, {String? city}) =>
    Memory(file: file, kind: MemoryKind.photo, at: at, city: city);

void main() {
  test('día del viaje y parte del día', () {
    final DateTime start = DateTime(2026, 10, 22);
    expect(tripDay(start, DateTime(2026, 10, 22, 23)), 1);
    expect(tripDay(start, DateTime(2026, 10, 24, 1)), 3);
    expect(dayPartOf(DateTime(2026, 1, 1, 9)), DayPart.morning);
    expect(dayPartOf(DateTime(2026, 1, 1, 15)), DayPart.afternoon);
    expect(dayPartOf(DateTime(2026, 1, 1, 19)), DayPart.sunset);
    expect(dayPartOf(DateTime(2026, 1, 1, 2)), DayPart.night);
  });

  test('las cifras cuentan solo desde el inicio del viaje', () {
    final DateTime start = DateTime(2026, 10, 22);
    final List<Memory> all = <Memory>[
      photo('a.jpg', DateTime(2026, 10, 20), city: 'Roma'),
      photo('b.jpg', DateTime(2026, 10, 22, 10), city: 'Madrid'),
      photo('c.jpg', DateTime(2026, 10, 23, 10), city: 'Lisboa'),
      photo('d.jpg', DateTime(2026, 10, 23, 12), city: 'Madrid'),
    ];
    final TripStats s = statsOf(
      all,
      <Stamp>[
        Stamp(qid: 'Q1', name: 'Viejo', date: DateTime(2026, 10, 1)),
        Stamp(qid: 'Q2', name: 'Nuevo', date: DateTime(2026, 10, 23)),
      ],
      start,
      DateTime(2026, 10, 25, 9),
    );
    expect(s.days, 4);
    expect(s.cities, <String>['Madrid', 'Lisboa']);
    expect(s.media, 3);
    expect(s.stamps, 1);
  });

  test('la historia coge 6 recuerdos repartidos (vídeos también)', () {
    final DateTime start = DateTime(2026, 10, 1);
    final List<Memory> all = <Memory>[
      for (int i = 0; i < 11; i++)
        photo('p$i.jpg', DateTime(2026, 10, 1 + i, 12)),
      Memory(file: 'v.mp4', kind: MemoryKind.video, at: DateTime(2026, 10, 5)),
      // Una historia ya guardada no sale dentro de la nueva.
      Memory(
        file: 'story_1.mp4',
        kind: MemoryKind.video,
        at: DateTime(2026, 10, 6),
      ),
    ];
    expect(storyPhotos(all, start).map((Memory m) => m.file), <String>[
      'p0.jpg',
      'p2.jpg',
      'v.mp4',
      'p6.jpg',
      'p8.jpg',
      'p10.jpg',
    ]);
  });

  test('sin fotos desde el inicio del viaje, salen tus últimas fotos', () {
    final List<Memory> all = <Memory>[
      for (int i = 0; i < 8; i++)
        photo('p$i.jpg', DateTime(2026, 9, 1 + i, 12)),
    ];
    expect(
      storyPhotos(all, DateTime(2026, 11, 1)).map((Memory m) => m.file),
      <String>['p2.jpg', 'p3.jpg', 'p4.jpg', 'p5.jpg', 'p6.jpg', 'p7.jpg'],
    );
  });

  test('un nombre de archivo con "../" no se acepta', () {
    expect(
      Memory.parse(<String, Object?>{'file': '../x.jpg', 'at': '2026-10-22'}),
      isNull,
    );
    expect(
      Memory.parse(<String, Object?>{'file': 'a/b.jpg', 'at': '2026-10-22'}),
      isNull,
    );
    expect(
      Memory.parse(<String, Object?>{'file': 'm_1.jpg', 'at': '2026-10-22'}),
      isNotNull,
    );
  });

  test('guardar, borrar y vaciarlo todo', () async {
    final MemorySettingsStore store = MemorySettingsStore();
    final MemoryMemoryFiles files = MemoryMemoryFiles();
    final MemoryBook book = MemoryBook(store, files);
    await files.write('a.jpg', Uint8List(1));
    await files.write('b.jpg', Uint8List(1));
    await book.add(photo('a.jpg', DateTime(2026, 10, 22)));
    await book.add(photo('b.jpg', DateTime(2026, 10, 23)));
    await book.setTripStart(DateTime(2026, 10, 21, 15));
    expect(book.all().first.file, 'b.jpg');
    expect(book.tripStart(DateTime(2026, 10, 25)), DateTime(2026, 10, 21));

    await book.remove(book.all().first);
    expect(book.all().map((Memory m) => m.file), <String>['a.jpg']);
    expect(files.files.keys, <String>['a.jpg']);
    // Borrar uno no pierde el día de inicio.
    expect(book.tripStart(DateTime(2026, 10, 25)), DateTime(2026, 10, 21));

    await book.clear();
    expect(book.all(), isEmpty);
    expect(files.files, isEmpty);
  });

  test('a la página solo va lo que ha cambiado', () {
    expect(
      changedKeys(
        <String, Object?>{
          'a': 1,
          'b': <int>[1],
        },
        <String, Object?>{
          'a': 1,
          'b': <int>[2],
          'c': 'x',
        },
      ),
      <String, Object?>{
        'b': <int>[2],
        'c': 'x',
      },
    );
    expect(
      memoriesPushScript(<String, Object?>{'x': '<b>'}),
      isNot(contains('<b>')),
    );
  });

  testWidgets('foto con la cámara de viaje: se guarda y se comparte', (
    WidgetTester tester,
  ) async {
    final MemorySettingsStore store = MemorySettingsStore('es');
    final FakeTravelCamera camera = FakeTravelCamera();
    final MemoryMemoryFiles files = MemoryMemoryFiles();
    final List<List<String>> shared = <List<String>>[];
    final m.PageSpy spy = m.PageSpy();
    final session = newSession()..continueAsGuest();
    tester.view.physicalSize = const Size(1200, 3000);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    final AppServices app = fakeServices(
      session,
      prefs: store,
      newTravelCamera: () => camera,
      memoryFiles: files,
      webScene: spy.build,
      share: (List<String> paths, {String? text}) async => shared.add(paths),
    );
    await pumpApp(
      tester,
      locale: 'es',
      session: session,
      initialLocation: Routes.memories,
      services: app,
    );
    Map<String, Object?> data() => spy.data(MemoriesScreen.lastBridge!);
    await spy.wait(tester, () => spy.pages.isNotEmpty);
    expect(spy.pages.first, contains('ECLIPTA · Recuerdos'));
    expect(
      data()['emptyTxt'],
      'Aún no hay nada. Aquí salen las fotos y los vídeos '
      'que hagas con la cámara de viaje.',
    );
    expect(data()['grid'], isEmpty);

    spy.send!('camera');
    await tester.pumpAndSettle();
    await tester.tap(find.bySemanticsLabel('Hacer foto'));
    await tester.pump();
    await tester.pump();
    expect(camera.photos, 1);
    // Se queda en la cámara y lo dice un momento.
    expect(find.text('Guardado en Recuerdos'), findsOneWidget);
    await tester.pumpAndSettle(const Duration(seconds: 2));
    expect(find.text('Toca: foto · Mantén: vídeo'), findsOneWidget);
    // Desde Recuerdos no hay escáner al lado.
    expect(find.textContaining('escáner'), findsNothing);

    // Mantener pulsado = vídeo; al soltar se guarda.
    final TestGesture hold = await tester.startGesture(
      tester.getCenter(find.bySemanticsLabel('Hacer foto')),
    );
    await tester.pump(const Duration(milliseconds: 700));
    await tester.pump();
    expect(camera.recording, isTrue);
    await hold.up();
    await tester.pumpAndSettle(const Duration(seconds: 2));
    expect(camera.recording, isFalse);
    expect(files.files, hasLength(2));
    final String videoFile = files.files.keys.firstWhere(
      (String k) => k.endsWith('.mp4'),
    );

    // La miniatura de lo último (el vídeo) abre Compartir / Repetir.
    await tester.tap(find.bySemanticsLabel('Compartir'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Compartir'));
    await tester.pumpAndSettle();
    expect(shared.single.single, '/memories/$videoFile');
    // "Repetir" lo borra y vuelve a la cámara.
    await tester.tap(find.text('Repetir'));
    await tester.pumpAndSettle();
    expect(app.memories.all(), hasLength(1));
    // La foto, con la pegatina activada, se guarda como PNG.
    expect(app.memories.all().single.file, endsWith('.png'));

    expect(find.byType(BackButton), findsOneWidget);
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    await spy.wait(
      tester,
      () => (data()['grid']! as List<Object?>).length == 1,
    );
    expect(data()['listH'], 'Recuerdos · 1 de 300');
  });

  testWidgets('la historia: portada, foto con "DÍA N · CIUDAD" y cifras', (
    WidgetTester tester,
  ) async {
    final MemorySettingsStore store = MemorySettingsStore('es');
    final MemoryMemoryFiles files = MemoryMemoryFiles();
    final DateTime now = DateTime.now();
    final DateTime today = DateTime(now.year, now.month, now.day, 12);
    final List<List<String>> shared = <List<String>>[];
    final List<String?> texts = <String?>[];
    final m.PageSpy spy = m.PageSpy();
    final session = newSession()..continueAsGuest();
    final services = fakeServices(
      session,
      prefs: store,
      memoryFiles: files,
      webScene: spy.build,
      share: (List<String> paths, {String? text}) async {
        shared.add(paths);
        texts.add(text);
      },
    );
    await files.write('a.jpg', Uint8List.fromList(<int>[1, 2, 3]));
    await services.memories.add(photo('a.jpg', today, city: 'Madrid'));
    tester.view.physicalSize = const Size(1200, 3000);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await pumpApp(
      tester,
      locale: 'es',
      session: session,
      initialLocation: Routes.memories,
      services: services,
    );
    Map<String, Object?> data() => spy.data(MemoriesScreen.lastBridge!);
    await spy.wait(tester, () => spy.pages.isNotEmpty);
    expect(data()['route'], 'Madrid');
    expect(data()['from'], 'Madrid');
    expect(data()['to'], '');
    final List<Object?> stats = data()['stats']! as List<Object?>;
    expect((stats[2]! as Map<String, Object?>)['k'], 'fotos y vídeos');

    // El vídeo grabado por la página: "Guardar vídeo" lo deja en Recuerdos.
    spy.send!('video:save:mp4:${base64Encode(<int>[0, 0, 0, 24])}');
    await spy.wait(tester, () => services.memories.all().length == 2);
    final Memory video = services.memories.all().firstWhere(
      (Memory x) => x.kind == MemoryKind.video,
    );
    expect(video.file, endsWith('.mp4'));

    // "Crear historia" lo comparte (Instagram, WhatsApp... los elige el móvil).
    spy.send!('video:share:webm:${base64Encode(<int>[1, 2])}');
    await spy.wait(tester, () => shared.isNotEmpty);
    expect(shared.single.single, '/memories/story_share.webm');
    expect(texts.single, contains('Madrid'));

    // Si el móvil no sabe grabar: las fotos y el texto.
    spy.send!('novideo:group');
    await spy.wait(tester, () => shared.length == 2);
    expect(shared.last, <String>['/memories/a.jpg']);

    // Viñetas y a pantalla completa.
    spy.send!('style:1');
    await tester.pump();
    expect(data()['style'], 1);
    spy.send!('full');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.byType(StoryPlayer), findsOneWidget);

    // Pasa sola a la foto.
    await tester.pump(const Duration(seconds: 4));
    expect(find.text('DÍA 1 · MADRID'), findsOneWidget);

    // Y al final, las cifras; luego se cierra sola.
    await tester.pump(const Duration(seconds: 4));
    expect(find.text('fotos y vídeos'), findsWidgets);
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();
    expect(find.byType(StoryPlayer), findsNothing);
  });

  testWidgets('los vídeos salen en la historia y tus fotos en la portada', (
    WidgetTester tester,
  ) async {
    final MemoryMemoryFiles files = MemoryMemoryFiles();
    final m.PageSpy spy = m.PageSpy();
    final services = fakeServices(
      newSession()..continueAsGuest(),
      memoryFiles: files,
      webScene: spy.build,
    );
    final DateTime now = DateTime.now();
    final DateTime today = DateTime(now.year, now.month, now.day, 10);
    await files.write('a.jpg', Uint8List.fromList(<int>[1]));
    await files.write('b.mp4', Uint8List.fromList(<int>[2]));
    await services.memories.add(photo('a.jpg', today, city: 'Roma'));
    await services.memories.add(
      Memory(
        file: 'b.mp4',
        kind: MemoryKind.video,
        at: today.add(const Duration(hours: 1)),
      ),
    );
    final List<String> framed = <String>[];
    await tester.pumpWidget(
      ServicesScope(
        services: services,
        child: MaterialApp(
          locale: const Locale('es'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: MemoriesScreen(
            image: (Uint8List bytes, int width) async =>
                'data:image/png;base64,${bytes.first}-$width',
            frame: (String path) async {
              framed.add(path);
              return Uint8List.fromList(<int>[9]);
            },
          ),
        ),
      ),
    );
    Map<String, Object?> data() => spy.data(MemoriesScreen.lastBridge!);
    await spy.wait(tester, () {
      if (spy.pages.isEmpty) return false;
      return (data()['shots']! as List<Object?>).length == 2;
    });
    expect(framed, <String>['/memories/b.mp4']);
    final List<Object?> shots = data()['shots']! as List<Object?>;
    expect((shots[0]! as Map<String, Object?>)['video'], isNull);
    expect((shots[1]! as Map<String, Object?>)['video'], isTrue);
    expect((shots[1]! as Map<String, Object?>)['src'], endsWith('9-540'));
    expect(data()['cover'], <String>[
      'data:image/png;base64,1-540',
      'data:image/png;base64,9-540',
    ]);
    expect(data()['videoTxt'], 'VÍDEO');
    final List<Object?> grid = data()['grid']! as List<Object?>;
    final Map<String, Object?> vid =
        grid.firstWhere((Object? g) => (g! as Map)['video'] == true)!
            as Map<String, Object?>;
    expect(vid['thumb'], endsWith('9-200'));
  });

  testWidgets('botón verde: la cámara normal y, deslizando, el escáner', (
    WidgetTester tester,
  ) async {
    final FakeTravelCamera camera = FakeTravelCamera();
    final session = newSession()..continueAsGuest();
    tester.view.physicalSize = const Size(1200, 3000);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await pumpApp(
      tester,
      locale: 'es',
      session: session,
      initialLocation: Routes.camera,
      settle: false,
      services: fakeServices(session, newTravelCamera: () => camera),
    );
    for (int i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.byType(TravelCameraScreen), findsOneWidget);
    expect(find.bySemanticsLabel('Hacer foto'), findsOneWidget);
    await tester.fling(
      find.byType(TravelCameraScreen),
      const Offset(300, 0),
      1000,
    );
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(TravelCameraScreen), findsNothing);
    expect(find.byType(CameraScreen), findsOneWidget);
    await tester.tap(
      find.text('Desliza a la izquierda para volver a la cámara'),
    );
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(TravelCameraScreen), findsOneWidget);
  });
}
