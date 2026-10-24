// Sin conexión: el paquete de una ciudad, la descarga y la pantalla.
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:nomadiq/auth/session.dart';
import 'package:nomadiq/core/api_client.dart';
import 'package:nomadiq/core/router.dart';
import 'package:nomadiq/core/settings.dart';
import 'package:nomadiq/features/audioguide/audioguide_api.dart';
import 'package:nomadiq/features/map/geo.dart';
import 'package:nomadiq/features/map/geo_api.dart';
import 'package:nomadiq/features/offline/city_downloader.dart';
import 'package:nomadiq/features/offline/city_pack.dart';
import 'package:nomadiq/features/offline/saved_guides.dart';
import 'package:nomadiq/features/route/geo.dart' show LatLon;

import 'helpers.dart';
import 'zones_fixture.dart';

/// Un mapa descargable de mentira: dice cuántos bytes ocupó.
class FakeMaps implements OfflineMaps {
  FakeMaps({this.bytes = 20 * 1024 * 1024, this.fail = false});

  final int bytes;
  final bool fail;
  final List<String> deleted = <String>[];
  GeoBox? asked;

  @override
  Future<int> download({
    required String iata,
    required GeoBox box,
    required void Function(double fraction) onProgress,
  }) async {
    asked = box;
    if (fail) throw Exception('sin sitio');
    onProgress(0.5);
    onProgress(1);
    return bytes;
  }

  @override
  Future<void> delete(String iata) async => deleted.add(iata);
}

class FakeNet implements NetProbe {
  FakeNet(this.kind);

  NetKind kind;

  @override
  Future<NetKind> now() async => kind;
}

/// El servidor: zonas, guiones, manifiestos y los .opus.
void serveCity(FakeGateway g, {bool audio = true, bool anyZone = true}) {
  g.services['/v1/zones'] = (_) => FakeGateway.json(
    anyZone
        ? zonesCollection()
        : <String, Object?>{
            'type': 'FeatureCollection',
            'features': <Object?>[],
            'truncated': false,
          },
  );
  for (final Zone zone in <Zone>[madridZone(), solZone(), airportZone()]) {
    g.services['/v1/audioguides/${zone.id}'] = (_) =>
        FakeGateway.json(<String, Object?>{
          'zone_name': zone.name,
          'title': 'Paseo por ${zone.name}',
          'content_language': 'es',
          'segments': <Object?>[
            <String, Object?>{'text': 'Primera parte de ${zone.name}.'},
            <String, Object?>{'text': 'Segunda parte.'},
          ],
        });
    g.services['/v1/audioguides/${zone.id}/audio'] = (_) => audio
        ? FakeGateway.json(<String, Object?>{
            'content_language': 'es',
            'stale': false,
            'parts': <Object?>[
              for (int i = 0; i < 2; i++)
                <String, Object?>{
                  'index': i,
                  'url': '/v1/audio/${zone.id}-$i.opus',
                  'duration_seconds': 30,
                  'text': 'parte $i',
                },
            ],
          })
        : http.Response('{}', 404);
    for (int i = 0; i < 2; i++) {
      g.services['/v1/audio/${zone.id}-$i.opus'] = (_) =>
          http.Response.bytes(List<int>.filled(1024, 7), 200);
    }
  }
}

CityDownloader downloaderFor(
  FakeGateway g,
  SessionController session,
  SettingsStore store, {
  OfflineMaps? maps,
  NetProbe? net,
  OfflineFiles? files,
}) {
  final ApiClient api = ApiClient(
    baseUrl: Uri.parse('http://gateway.test'),
    session: session,
    client: g.client,
  );
  return CityDownloader(
    api: api,
    geo: GeoApi(api),
    guides: AudioguideApi(api),
    files: files ?? MemoryOfflineFiles(),
    maps: maps ?? FakeMaps(),
    net: net ?? FakeNet(NetKind.wifi),
    cities: OfflineLibrary(store),
  );
}

CityPack packOf(String iata, {String language = 'es', int tiles = 1024}) =>
    CityPack(
      iata: iata,
      city: 'Ciudad $iata',
      language: language,
      zones: <PackZone>[
        PackZone(
          id: 'z-$iata',
          name: 'Centro',
          title: 'Paseo',
          texts: const <String>['uno', 'dos'],
          audio: <PackAudio>[
            PackAudio(
              index: 0,
              file: '${cityFolder(iata)}/z-0.opus',
              bytes: 2048,
              seconds: 30,
            ),
          ],
        ),
      ],
      tileBytes: tiles,
      savedAt: DateTime(2026, 10, 24),
    );

void main() {
  group('cuentas', () {
    test('los tamaños se dicen como una persona', () {
      expect(sizeLabel(512), '512 B');
      expect(sizeLabel(4096), '4 kB');
      expect(sizeLabel(48 * 1024 * 1024), '48 MB');
      expect(sizeLabel(3 * 1024 * 1024 * 1024), '3.0 GB');
    });

    test('con "solo wifi" los datos del móvil esperan', () {
      expect(mayDownload(wifiOnly: true, net: NetKind.wifi), isTrue);
      expect(mayDownload(wifiOnly: true, net: NetKind.mobile), isFalse);
      expect(mayDownload(wifiOnly: false, net: NetKind.mobile), isTrue);
      expect(mayDownload(wifiOnly: false, net: NetKind.none), isFalse);
    });

    test('la barra avanza por pasos y nunca retrocede', () {
      const DownloadProgress zones = DownloadProgress(DownloadStep.zones);
      final DownloadProgress audio = const DownloadProgress(
        DownloadStep.audio,
        done: 5,
        total: 10,
      );
      final DownloadProgress map = const DownloadProgress(
        DownloadStep.map,
        done: 100,
        total: 100,
      );
      expect(zones.fraction, 0);
      expect(audio.fraction, closeTo(0.55, 0.001));
      expect(map.fraction, 1);
      // Un total de 0 no divide por cero.
      expect(const DownloadProgress(DownloadStep.guides).fraction, 0.1);
    });
  });

  group('el paquete de la ciudad', () {
    test('se guarda y se vuelve a leer igual', () {
      final CityPack pack = packOf('MAD');
      final CityPack? back = CityPack.parse(
        jsonDecode(jsonEncode(pack.toJson())),
      );
      expect(back!.iata, 'MAD');
      expect(back.zones.single.texts, <String>['uno', 'dos']);
      expect(back.bytes, 2048 + 1024);
      expect(back.guides, 1);
      expect(back.savedAt, pack.savedAt);
    });

    test('lo que viene raro se descarta', () {
      expect(CityPack.parse('nada'), isNull);
      expect(CityPack.parse(<String, Object?>{'iata': 'MADRID'}), isNull);
      // Una ruta de archivo con ".." no se acepta (no vale para salirse de
      // la carpeta de la app).
      expect(
        PackAudio.parse(<String, Object?>{
          'index': 0,
          'file': '../../robado.opus',
          'bytes': 1,
        }),
        isNull,
      );
      expect(PackZone.parse(<String, Object?>{'id': '', 'name': 'x'}), isNull);
    });

    test('la biblioteca guarda, sustituye y tira la más vieja', () async {
      final MemorySettingsStore store = MemorySettingsStore();
      final OfflineLibrary library = OfflineLibrary(store);
      expect(library.all(), isEmpty);
      await library.save(packOf('MAD'));
      await library.save(packOf('NRT', tiles: 2048));
      expect(library.all().length, 2);
      expect(library.of('nrt')!.tileBytes, 2048);
      expect(library.totalBytes, 2048 + 2048 + 2048 + 1024);
      // La misma ciudad otra vez no se duplica: se sustituye.
      await library.save(packOf('MAD', tiles: 99));
      expect(library.all().length, 2);
      expect(library.of('MAD')!.tileBytes, 99);
      await library.remove('MAD');
      expect(library.of('MAD'), isNull);
      // Más de 10 ciudades: solo se quedan las 10 últimas.
      for (int i = 0; i < 12; i++) {
        await library.save(packOf('C$i'.padRight(3, 'X')));
      }
      expect(library.all().length, OfflineLibrary.maxCities);
    });

    test('una lista guardada rota no rompe nada', () async {
      final MemorySettingsStore store = MemorySettingsStore();
      await store.writeData(LocalData.offlineCities, 'no es json');
      expect(OfflineLibrary(store).all(), isEmpty);
    });
  });

  group('la descarga', () {
    test('baja zonas, guiones, audios y mapa', () async {
      final FakeGateway g = FakeGateway();
      serveCity(g);
      final SessionController session = await signedInSession(g);
      final MemorySettingsStore store = MemorySettingsStore();
      final MemoryOfflineFiles files = MemoryOfflineFiles();
      final FakeMaps maps = FakeMaps();
      final List<DownloadStep> steps = <DownloadStep>[];
      final CityPack pack =
          await downloaderFor(g, session, store, maps: maps, files: files).run(
            iata: 'mad',
            city: 'Madrid',
            center: const LatLon(40.42, -3.70),
            language: 'es',
            wifiOnly: true,
            onProgress: (DownloadProgress p) => steps.add(p.step),
          );
      expect(pack.iata, 'MAD');
      expect(pack.zones.length, 3);
      expect(pack.guides, 3);
      // Dos .opus de 1 kB por zona.
      expect(files.written.length, 6);
      expect(files.written.keys.first, startsWith('offline/MAD/'));
      expect(pack.audioBytes, 6 * 1024);
      expect(pack.tileBytes, maps.bytes);
      expect(pack.mapFailed, isFalse);
      expect(steps, contains(DownloadStep.audio));
      expect(steps.last, DownloadStep.map);
      // El trozo de mapa va alrededor del centro que se pidió.
      expect(maps.asked!.contains(const GeoPoint(40.42, -3.70)), isTrue);
      // Y queda guardada en la biblioteca de este móvil.
      expect(OfflineLibrary(store).of('MAD')!.city, 'Madrid');
    });

    test('si el mapa falla, las audioguías se guardan igual', () async {
      final FakeGateway g = FakeGateway();
      serveCity(g);
      final SessionController session = await signedInSession(g);
      final MemorySettingsStore store = MemorySettingsStore();
      final CityPack pack =
          await downloaderFor(
            g,
            session,
            store,
            maps: FakeMaps(fail: true),
          ).run(
            iata: 'MAD',
            city: 'Madrid',
            center: const LatLon(40.42, -3.70),
            language: 'es',
            wifiOnly: false,
            onProgress: (_) {},
          );
      expect(pack.mapFailed, isTrue);
      expect(pack.tileBytes, 0);
      expect(pack.guides, 3);
    });

    test('sin audio grabado se guarda el texto', () async {
      final FakeGateway g = FakeGateway();
      serveCity(g, audio: false);
      final SessionController session = await signedInSession(g);
      final CityPack pack =
          await downloaderFor(g, session, MemorySettingsStore()).run(
            iata: 'MAD',
            city: 'Madrid',
            center: const LatLon(40.42, -3.70),
            language: 'es',
            wifiOnly: false,
            onProgress: (_) {},
          );
      expect(pack.guides, 0);
      expect(pack.zones.first.texts.length, 2);
      expect(pack.audioBytes, 0);
    });

    test('con datos del móvil y "solo wifi" se espera', () async {
      final FakeGateway g = FakeGateway();
      serveCity(g);
      final SessionController session = await signedInSession(g);
      final CityDownloader d = downloaderFor(
        g,
        session,
        MemorySettingsStore(),
        net: FakeNet(NetKind.mobile),
      );
      await expectLater(
        d.run(
          iata: 'MAD',
          city: 'Madrid',
          center: const LatLon(40.42, -3.70),
          language: 'es',
          wifiOnly: true,
          onProgress: (_) {},
        ),
        throwsA(
          isA<DownloadException>().having(
            (DownloadException e) => e.error,
            'error',
            DownloadError.waitingForWifi,
          ),
        ),
      );
    });

    test('una ciudad sin zonas lo dice', () async {
      final FakeGateway g = FakeGateway();
      serveCity(g, anyZone: false);
      final SessionController session = await signedInSession(g);
      await expectLater(
        downloaderFor(g, session, MemorySettingsStore()).run(
          iata: 'XXX',
          city: 'Nada',
          center: const LatLon(0.5, 0.5),
          language: 'es',
          wifiOnly: false,
          onProgress: (_) {},
        ),
        throwsA(
          isA<DownloadException>().having(
            (DownloadException e) => e.error,
            'error',
            DownloadError.nothingThere,
          ),
        ),
      );
    });

    test('borrar una ciudad quita mapa, audios y ficha', () async {
      final MemorySettingsStore store = MemorySettingsStore();
      final FakeGateway g = FakeGateway();
      final SessionController session = await signedInSession(g);
      final MemoryOfflineFiles files = MemoryOfflineFiles();
      await files.write('offline/MAD/z-0.opus', Uint8List(10));
      final FakeMaps maps = FakeMaps();
      await OfflineLibrary(store).save(packOf('MAD'));
      await downloaderFor(
        g,
        session,
        store,
        maps: maps,
        files: files,
      ).forget('mad');
      expect(maps.deleted, <String>['MAD']);
      expect(files.written, isEmpty);
      expect(OfflineLibrary(store).all(), isEmpty);
    });
  });

  group('las audioguías guardadas', () {
    test('se encuentran por su zona y traen los archivos', () async {
      final MemorySettingsStore store = MemorySettingsStore();
      await OfflineLibrary(store).save(packOf('MAD'));
      final SavedGuides saved = OfflineSavedGuides(
        library: OfflineLibrary(store),
        fileUri: (String path) async => Uri.file('/datos/$path'),
      );
      final SavedGuide? guide = await saved.of('z-MAD', 'es');
      expect(guide!.script.title, 'Paseo');
      expect(guide.script.segments.length, 2);
      expect(guide.audio!.parts.single.url.path, contains('offline/MAD'));
      expect(guide.audio!.total, const Duration(seconds: 30));
      // Una zona que no se descargó: no hay nada.
      expect(await saved.of('otra', 'es'), isNull);
      expect(await const NoSavedGuides().of('z-MAD', 'es'), isNull);
    });
  });

  testWidgets('pantalla: se descarga una ciudad y luego se borra', (
    WidgetTester tester,
  ) async {
    final FakeGateway g = FakeGateway();
    serveCity(g);
    final SessionController session = await signedInSession(g);
    final MemorySettingsStore store = MemorySettingsStore();
    final FakeMaps maps = FakeMaps();
    tester.view.physicalSize = const Size(1200, 4000);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await pumpApp(
      tester,
      locale: 'es',
      session: session,
      initialLocation: Routes.offline,
      services: fakeServices(
        session,
        gateway: g,
        prefs: store,
        offlineMaps: maps,
        net: FakeNet(NetKind.wifi),
      ),
    );
    // Los aeropuertos de verdad (assets/geo) tardan un poco.
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(seconds: 2)),
    );
    await tester.pumpAndSettle();
    expect(find.text('Sin conexión'), findsOneWidget);
    expect(find.textContaining('Todavía no has descargado'), findsOneWidget);

    // Un código que no existe lo avisa.
    await tester.enterText(find.byType(TextField), 'ZZZ');
    await tester.pumpAndSettle();
    expect(find.text('No conocemos ese aeropuerto.'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'MAD');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Descargar'));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(seconds: 1)),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('3 audioguías'), findsOneWidget);
    expect(find.textContaining('MB'), findsWidgets);
    expect(store.readData(LocalData.offlineCities), contains('MAD'));

    // "Solo con wifi" se recuerda en el móvil.
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect(store.readData(LocalData.offlineWifiOnly), '0');

    await tester.tap(find.text('Borrar'));
    await tester.pumpAndSettle();
    expect(maps.deleted, <String>['MAD']);
    expect(find.textContaining('Todavía no has descargado'), findsOneWidget);
  });
}
