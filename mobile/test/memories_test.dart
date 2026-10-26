// Recuerdos: las cuentas de la historia, la lista guardada en el móvil, la
// cámara de viaje (foto con pegatina → guardada → compartir) y la historia.
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:eclipta/core/router.dart';
import 'package:eclipta/core/settings.dart';
import 'package:eclipta/features/camera/camera_device.dart' show CameraStart;
import 'package:eclipta/features/camera/stamps.dart';
import 'package:eclipta/features/memories/memories.dart';
import 'package:eclipta/features/memories/memories_screen.dart';
import 'package:eclipta/features/memories/travel_camera.dart';

import 'helpers.dart';

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

  test('la historia coge 6 fotos repartidas, no las 6 últimas', () {
    final DateTime start = DateTime(2026, 10, 1);
    final List<Memory> all = <Memory>[
      for (int i = 0; i < 11; i++)
        photo('p$i.jpg', DateTime(2026, 10, 1 + i, 12)),
      Memory(file: 'v.mp4', kind: MemoryKind.video, at: DateTime(2026, 10, 5)),
    ];
    expect(storyPhotos(all, start).map((Memory m) => m.file), <String>[
      'p0.jpg',
      'p2.jpg',
      'p4.jpg',
      'p6.jpg',
      'p8.jpg',
      'p10.jpg',
    ]);
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

  testWidgets('foto con la cámara de viaje: se guarda y se comparte', (
    WidgetTester tester,
  ) async {
    final MemorySettingsStore store = MemorySettingsStore('es');
    final FakeTravelCamera camera = FakeTravelCamera();
    final MemoryMemoryFiles files = MemoryMemoryFiles();
    final List<List<String>> shared = <List<String>>[];
    final session = newSession()..continueAsGuest();
    tester.view.physicalSize = const Size(1200, 3000);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await pumpApp(
      tester,
      locale: 'es',
      session: session,
      initialLocation: Routes.memories,
      services: fakeServices(
        session,
        prefs: store,
        newTravelCamera: () => camera,
        memoryFiles: files,
        share: (List<String> paths, {String? text}) async => shared.add(paths),
      ),
    );
    expect(
      find.text(
        'Aún no hay nada. Aquí salen las fotos y los vídeos '
        'que hagas con la cámara de viaje.',
      ),
      findsOneWidget,
    );

    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();
    await tester.tap(find.bySemanticsLabel('Hacer foto'));
    await tester.pumpAndSettle();
    expect(camera.photos, 1);
    expect(
      find.text('Guardado en tus Recuerdos, solo en este móvil.'),
      findsOneWidget,
    );
    expect(files.files, hasLength(1));
    // Con la pegatina activada se guarda como PNG.
    expect(files.files.keys.single, endsWith('.png'));

    await tester.tap(find.text('Compartir'));
    await tester.pumpAndSettle();
    expect(shared.single.single, '/memories/${files.files.keys.single}');

    expect(find.byType(BackButton), findsOneWidget);
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.text('Recuerdos · 1 de 300'), findsOneWidget);
  });

  testWidgets('la historia: portada, foto con "DÍA N · CIUDAD" y cifras', (
    WidgetTester tester,
  ) async {
    final MemorySettingsStore store = MemorySettingsStore('es');
    final MemoryMemoryFiles files = MemoryMemoryFiles();
    final DateTime now = DateTime.now();
    final DateTime today = DateTime(now.year, now.month, now.day);
    final session = newSession()..continueAsGuest();
    final services = fakeServices(session, prefs: store, memoryFiles: files);
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
    expect(find.text('Madrid'), findsOneWidget);

    await tester.tap(find.text('Viñetas'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Ver historia'));
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
}
