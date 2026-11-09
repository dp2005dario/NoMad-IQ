// Sin conexión: el paquete de una ciudad, la descarga y la pantalla.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:eclipta/auth/session.dart';
import 'package:eclipta/core/api_client.dart';
import 'package:eclipta/core/router.dart';
import 'package:eclipta/core/services.dart';
import 'package:eclipta/core/settings.dart';
import 'package:eclipta/features/audioguide/audioguide_api.dart';
import 'package:eclipta/features/map/geo.dart';
import 'package:eclipta/features/map/geo_api.dart';
import 'package:eclipta/features/offline/city_downloader.dart';
import 'package:eclipta/features/offline/city_pack.dart';
import 'package:eclipta/features/offline/offline_auto.dart';
import 'package:eclipta/features/offline/offline_page.dart';
import 'package:eclipta/features/offline/offline_platform.dart';
import 'package:eclipta/features/offline/offline_screen.dart';
import 'package:eclipta/features/offline/saved_guides.dart';
import 'package:eclipta/features/route/flight3d.dart'
    show CountryCodes, WebSceneBuilder;
import 'package:eclipta/features/route/geo.dart' show LatLon;
import 'package:eclipta/features/route/world_data.dart';

import 'helpers.dart';
import 'money_test.dart' as m;
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

class FakeVersion implements MapVersionProbe {
  FakeVersion(this.value);

  String? value;

  @override
  Future<String?> latest() async => value;
}

class FakePower implements PowerProbe {
  FakePower(this.on);

  bool on;

  @override
  Future<bool> charging() async => on;
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
  MapVersionProbe? version,
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
    mapVersion: version ?? const NoMapVersion(),
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

/// Abre la pantalla con la página de mentira y espera a que salga.
Future<m.PageSpy> pumpOffline(
  WidgetTester tester,
  SessionController session,
  AppServices Function(WebSceneBuilder page) services,
) async {
  final m.PageSpy spy = m.PageSpy();
  // Lo que se carga una vez para toda la app: aquí, fuera del reloj de
  // mentira (si no, se quedaría colgado en la prueba siguiente).
  await tester.runAsync(() async {
    await CountryCodes.load();
    await WorldData.load();
  });
  await pumpApp(
    tester,
    locale: 'es',
    session: session,
    initialLocation: Routes.offline,
    services: services(spy.build),
  );
  await spy.wait(tester, () => spy.pages.isNotEmpty);
  // Los aeropuertos y los países ya están.
  await spy.wait(
    tester,
    () => spy.data(OfflineScreen.lastBridge!)['ready'] == true,
  );
  return spy;
}

/// La tarjeta de una ciudad en la página.
Map<String, Object?> item(Map<String, Object?> d, String id) =>
    (d['items']! as List<Object?>).cast<Map<String, Object?>>().firstWhere(
      (Map<String, Object?> i) => i['id'] == id,
      orElse: () => <String, Object?>{},
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

    test('solo el centro y sin voces: mapa pequeño y ningún audio', () async {
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
            area: OfflineArea.center,
            withAudio: false,
          );
      // El centro: 0,02 grados a cada lado (unos 2 km).
      expect(maps.asked!.maxLat - maps.asked!.minLat, closeTo(0.04, 1e-9));
      expect(files.written, isEmpty);
      expect(steps, isNot(contains(DownloadStep.audio)));
      // Los textos de las audioguías sí se guardan.
      expect(pack.zones.first.texts, isNotEmpty);
      final CityPack again = OfflineLibrary(store).of('MAD')!;
      expect(again.area, OfflineArea.center);
      expect(again.withAudio, isFalse);
    });

    test('"Parar descarga" corta a mitad y no guarda la ciudad', () async {
      final FakeGateway g = FakeGateway();
      serveCity(g);
      final SessionController session = await signedInSession(g);
      final MemorySettingsStore store = MemorySettingsStore();
      bool stop = false;
      await expectLater(
        downloaderFor(g, session, store, maps: FakeMaps()).run(
          iata: 'mad',
          city: 'Madrid',
          center: const LatLon(40.42, -3.70),
          language: 'es',
          wifiOnly: true,
          // En cuanto empieza a bajar audio, la persona toca "Parar".
          onProgress: (DownloadProgress p) {
            if (p.step == DownloadStep.audio) stop = true;
          },
          stopped: () => stop,
        ),
        throwsA(
          isA<DownloadException>().having(
            (DownloadException e) => e.error,
            'error',
            DownloadError.cancelled,
          ),
        ),
      );
      expect(OfflineLibrary(store).of('MAD'), isNull);
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

  testWidgets('pantalla: se busca, se descarga una ciudad y luego se borra', (
    WidgetTester tester,
  ) async {
    final FakeGateway g = FakeGateway();
    serveCity(g);
    final SessionController session = await signedInSession(g);
    final MemorySettingsStore store = MemorySettingsStore();
    final FakeMaps maps = FakeMaps();
    final StreamController<bool> online = StreamController<bool>.broadcast();
    addTearDown(online.close);
    final m.PageSpy spy = await pumpOffline(
      tester,
      session,
      (WebSceneBuilder page) => fakeServices(
        session,
        webScene: page,
        gateway: g,
        prefs: store,
        offlineMaps: maps,
        net: FakeNet(NetKind.wifi),
        onlineChanges: () => online.stream,
      ),
    );
    Map<String, Object?> data() => spy.data(OfflineScreen.lastBridge!);
    expect(spy.pages.first, contains('ECLIPTA · Zonas sin conexión'));
    expect(
      data()['subtitle'],
      'Aún no hay zonas listas para usar sin internet',
    );
    expect(data()['items'], isEmpty);
    expect(data()['canAdd'], isFalse);

    // Se busca por el aeropuerto (o por el nombre) y se elige.
    spy.send!('q:MAD');
    await tester.pump();
    final List<Object?> chips = data()['chips']! as List<Object?>;
    expect((chips.first! as Map<String, Object?>)['code'], 'MAD');
    spy.send!('pick:MAD');
    await tester.pump();
    expect(data()['zoneLabel'], 'Madrid · ciudad (8 km)');
    expect(data()['lat'], closeTo(40.47, 0.1));
    // Solo el centro de la ciudad.
    spy.send!('area:0');
    await tester.pump();
    expect(data()['addText'], 'Descargar Madrid');
    spy.send!('add');
    await spy.wait(
      tester,
      () =>
          (data()['items']! as List<Object?>).isNotEmpty &&
          item(data(), 'MAD')['st'] == 'done',
    );
    final Map<String, Object?> mad = item(data(), 'MAD');
    expect(mad['detail'], startsWith('Descargada · 20 MB · Centro'));
    expect(mad['feats'], contains('3 audioguías'));
    expect(data()['burst'], 'MAD');
    expect(store.readData(LocalData.offlineCities), contains('MAD'));
    expect(maps.asked!.maxLat - maps.asked!.minLat, closeTo(0.04, 1e-9));
    // La leyenda de la barra de espacio: la ciudad y lo que ocupa.
    expect(data()['legend'], <String>['Madrid 20 MB']);
    expect(data()['segs'], <double>[100]);
    expect(data()['subtitle'], '1 zona lista para usar sin internet');
    // Ya está: no se baja otra vez, y ahora hay tamaño aproximado.
    expect(data()['addText'], 'Madrid ya está en tus zonas');
    expect(data()['estTxt'], isNotEmpty);

    // Se va internet: qué sigue funcionando.
    online.add(false);
    await spy.wait(tester, () => data()['plane'] == true);
    expect(item(data(), 'MAD')['detail'], 'Funciona sin internet ✓');
    expect(data()['planeText'], 'Tu zona descargada sigue funcionando');
    online.add(true);
    await spy.wait(tester, () => data()['plane'] == false);

    // "Solo con wifi" se recuerda en el móvil.
    spy.send!('wifi');
    await spy.wait(tester, () => data()['wifi'] == false);
    expect(store.readData(LocalData.offlineWifiOnly), '0');

    // Borrar (la página pregunta antes).
    expect(item(data(), 'MAD')['askTxt'], '¿Borrar Madrid? Liberas 20 MB');
    spy.send!('del:MAD');
    await spy.wait(tester, () => (data()['items']! as List<Object?>).isEmpty);
    expect(maps.deleted, <String>['MAD']);
  });

  test('buscar: por aeropuerto, por nombre sin acentos, y la barra', () {
    final Airports all = Airports(<String, Airport>{
      for (final (String c, String n) in <(String, String)>[
        ('AGP', 'Málaga'),
        ('MAD', 'Madrid'),
        ('MLA', 'Malta'),
        ('ZAZ', 'Zaragoza'),
      ])
        c: Airport(
          iata: c,
          position: const LatLon(0, 0),
          city: n,
          country: 'Spain',
          timeZone: 'Europe/Madrid',
        ),
    });
    List<String> codes(String q) => <String>[
      for (final Airport a in searchAirports(all, q)) a.iata,
    ];
    expect(codes('mla'), <String>['MLA']);
    expect(codes('mala'), <String>['AGP']);
    expect(codes('ma'), <String>['MAD', 'AGP', 'MLA']);
    expect(codes('ragoz'), <String>['ZAZ']);
    expect(codes('z'), isEmpty);
    expect(spaceShares(<int>[1, 3]), <double>[25, 75]);
    expect(spaceShares(<int>[0]), isEmpty);
    expect(
      offlinePageWith('window.ECL=$offlineMarker;', <String, Object?>{
        'x': '</script>',
      }),
      isNot(contains('</script>')),
    );
    expect(
      offlinePushScript(<String, Object?>{'x': '<b>'}),
      isNot(contains('<b>')),
    );
  });

  group('lo que faltaba de la maqueta', () {
    test('el tamaño aproximado sale de lo que ocuparon tus ciudades', () {
      expect(
        estimateBytes(
          const <CityPack>[],
          area: OfflineArea.city,
          withAudio: true,
        ),
        isNull,
      );
      // Una ciudad de 14 MB de mapa en "la ciudad" (0,14° de lado).
      final CityPack mad = packOf('MAD', tiles: 14 * 1024 * 1024);
      final int city = estimateBytes(
        <CityPack>[mad],
        area: OfflineArea.city,
        withAudio: false,
      )!;
      expect(city, 14 * 1024 * 1024);
      // El centro (0,04° de lado) ocupa (0,04/0,14)² de eso.
      final int center = estimateBytes(
        <CityPack>[mad],
        area: OfflineArea.center,
        withAudio: false,
      )!;
      expect(center / city, closeTo(0.04 * 0.04 / (0.14 * 0.14), 1e-3));
      // Con voces: se suma lo que ocuparon las voces (2 kB de media).
      expect(
        estimateBytes(<CityPack>[mad], area: OfflineArea.city, withAudio: true),
        city + 2048,
      );
    });

    test('la versión del mapa sale de la ficha de OpenFreeMap', () {
      expect(
        TileJsonMapVersion.versionFromTileJson(
          '{"tiles":["https://tiles.openfreemap.org/planet/'
          '20261025_080012_pt/{z}/{x}/{y}.pbf"]}',
        ),
        '20261025_080012',
      );
      expect(
        TileJsonMapVersion.versionFromTileJson(
          '{"tiles":["https://otro.test/{z}/{x}/{y}.pbf"]}',
        ),
        isNull,
      );
      expect(TileJsonMapVersion.versionFromTileJson('roto'), isNull);
      final CityPack old = CityPack.parse(<String, Object?>{
        ...packOf('MAD').toJson(),
        'map_version': '20261001_000000',
      })!;
      expect(old.mapVersion, '20261001_000000');
      expect(hasNewerMap(old, '20261025_080012'), isTrue);
      expect(hasNewerMap(old, '20261001_000000'), isFalse);
      expect(hasNewerMap(old, null), isFalse);
      expect(hasNewerMap(packOf('MAD'), '20261025_080012'), isFalse);
      expect(mapVersionDay('20261025_080012'), DateTime(2026, 10, 25));
    });

    test('seguir una descarga parada no baja otra vez los audios', () async {
      final FakeGateway g = FakeGateway();
      serveCity(g);
      int opus = 0;
      for (final String key in g.services.keys.toList()) {
        if (!key.endsWith('.opus')) continue;
        final http.Response Function(http.Request) inner = g.services[key]!;
        g.services[key] = (http.Request r) {
          opus++;
          return inner(r);
        };
      }
      final SessionController session = await signedInSession(g);
      final MemorySettingsStore store = MemorySettingsStore();
      final MemoryOfflineFiles files = MemoryOfflineFiles();
      int audioSteps = 0;
      Future<CityPack> go({bool Function()? stopped}) =>
          downloaderFor(g, session, store, files: files).run(
            iata: 'mad',
            city: 'Madrid',
            center: const LatLon(40.42, -3.70),
            language: 'es',
            wifiOnly: true,
            onProgress: (DownloadProgress p) {
              if (p.step == DownloadStep.audio) audioSteps++;
            },
            stopped: stopped,
          );
      // Se para al empezar la tercera zona: ya hay 4 audios guardados.
      await expectLater(
        go(stopped: () => audioSteps >= 2),
        throwsA(isA<DownloadException>()),
      );
      expect(files.written.length, 4);
      expect(opus, 4);
      // "Seguir": solo faltan los 2 de la última zona.
      final CityPack pack = await go();
      expect(opus, 6);
      expect(pack.audioBytes, 6 * 1024);
    });

    test('la versión del mapa se guarda con la ciudad', () async {
      final FakeGateway g = FakeGateway();
      serveCity(g);
      final SessionController session = await signedInSession(g);
      final MemorySettingsStore store = MemorySettingsStore();
      await downloaderFor(
        g,
        session,
        store,
        version: FakeVersion('20261025_080012'),
      ).run(
        iata: 'mad',
        city: 'Madrid',
        center: const LatLon(40.42, -3.70),
        language: 'es',
        wifiOnly: true,
        onProgress: (_) {},
      );
      expect(OfflineLibrary(store).of('MAD')!.mapVersion, '20261025_080012');
    });

    test('las descargas paradas se recuerdan y se olvidan', () async {
      final OfflineLibrary lib = OfflineLibrary(MemorySettingsStore());
      await lib.pause(
        const PausedDownload(
          iata: 'mad',
          city: 'Madrid',
          area: OfflineArea.center,
          withAudio: false,
        ),
      );
      expect(lib.paused().single.iata, 'MAD');
      expect(lib.paused().single.area, OfflineArea.center);
      expect(lib.paused().single.withAudio, isFalse);
      await lib.unpause('MAD');
      expect(lib.paused(), isEmpty);
    });

    test('actualizar solas: solo con wifi, cargando y si hace falta', () async {
      final FakeGateway g = FakeGateway();
      serveCity(g);
      final SessionController session = await signedInSession(g);
      final MemorySettingsStore store = MemorySettingsStore();
      final FakeVersion version = FakeVersion('20261025_080012');
      final FakePower power = FakePower(false);
      final FakeNet net = FakeNet(NetKind.wifi);
      final AppServices s = fakeServices(
        session,
        gateway: g,
        prefs: store,
        offlineMaps: FakeMaps(),
        net: net,
        mapVersion: version,
        power: power,
      );
      final DateTime now = DateTime(2026, 11, 3, 10);
      // Madrid se bajó con el mapa del 1 de octubre.
      await OfflineLibrary(store).save(
        CityPack.parse(<String, Object?>{
          ...packOf('MAD').toJson(),
          'saved_at': now.subtract(const Duration(days: 2)).toIso8601String(),
          'map_version': '20261001_000000',
        })!,
      );
      final OfflineAutoUpdate auto = OfflineAutoUpdate(
        s,
        centerOf: (String iata) async => const LatLon(40.42, -3.70),
      );
      // Apagado: nada.
      expect(await auto.run(language: 'es', now: now), isEmpty);
      await auto.setEnabled(true);
      // Sin cargar: nada (y se volverá a mirar).
      expect(await auto.run(language: 'es', now: now), isEmpty);
      power.on = true;
      net.kind = NetKind.mobile;
      expect(await auto.run(language: 'es', now: now), isEmpty);
      net.kind = NetKind.wifi;
      final List<CityPack> done = await auto.run(language: 'es', now: now);
      expect(done.single.iata, 'MAD');
      expect(OfflineLibrary(store).of('MAD')!.mapVersion, '20261025_080012');
      // Ya miró hoy: hasta mañana no vuelve a mirar.
      version.value = '20261102_000000';
      expect(
        await auto.run(language: 'es', now: now.add(const Duration(hours: 2))),
        isEmpty,
      );
      expect(s.offlineBusy.value, isNull);
    });
  });

  testWidgets('pantalla: mapa nuevo, descarga parada, avión y Flyra', (
    WidgetTester tester,
  ) async {
    final FakeGateway g = FakeGateway();
    serveCity(g);
    final SessionController session = await signedInSession(g);
    final MemorySettingsStore store = MemorySettingsStore();
    await OfflineLibrary(store).save(
      CityPack.parse(<String, Object?>{
        ...packOf('LIS').toJson(),
        'city': 'Lisboa',
        'map_version': '20261001_000000',
      })!,
    );
    await OfflineLibrary(store).pause(
      const PausedDownload(
        iata: 'BCN',
        city: 'Barcelona',
        area: OfflineArea.city,
        withAudio: true,
      ),
    );
    await OfflineLibrary(store).pause(
      const PausedDownload(
        iata: 'MAD',
        city: 'Madrid',
        area: OfflineArea.city,
        withAudio: true,
      ),
    );
    final FakeNet net = FakeNet(NetKind.mobile);
    final m.PageSpy spy = await pumpOffline(
      tester,
      session,
      (WebSceneBuilder page) => fakeServices(
        session,
        webScene: page,
        gateway: g,
        prefs: store,
        offlineMaps: FakeMaps(),
        net: net,
        mapVersion: FakeVersion('20261025_080012'),
      ),
    );
    Map<String, Object?> data() => spy.data(OfflineScreen.lastBridge!);
    await spy.wait(tester, () => item(data(), 'LIS')['updTxt'] != null);
    // El tamaño aproximado sale de Lisboa.
    expect(data()['note'], contains('Ocupará unos'));
    expect(item(data(), 'LIS')['updTxt'], contains('Hay un mapa más nuevo'));
    expect(item(data(), 'LIS')['code'], 'PT');
    expect(item(data(), 'BCN')['st'], 'paused');
    expect(item(data(), 'BCN')['btnText'], 'Seguir');
    // Sin buscar, salen tus ciudades para elegir.
    expect(<Object?>[
      for (final Object? c in data()['chips']! as List<Object?>)
        (c! as Map<String, Object?>)['code'],
    ], containsAll(<String>['LIS', 'BCN']));

    // El avión: así se ve sin internet.
    spy.send!('plane');
    await tester.pump();
    expect(data()['plane'], isTrue);
    expect(data()['planeH'], 'Modo avión · sin internet');
    expect(item(data(), 'LIS')['detail'], 'Funciona sin internet ✓');
    expect(item(data(), 'BCN')['detail'], 'Necesita internet para seguir');
    spy.send!('plane');
    await tester.pump();

    // Borrar una parada: se olvida.
    expect(item(data(), 'MAD')['askTxt'], '¿Borrar lo bajado de Madrid?');
    spy.send!('del:MAD');
    await spy.wait(tester, () => item(data(), 'MAD').isEmpty);
    expect(
      OfflineLibrary(store).paused().map((PausedDownload p) => p.iata),
      <String>['BCN'],
    );

    // "Actualizar solas" se recuerda.
    spy.send!('auto');
    await spy.wait(tester, () => data()['auto'] == true);
    expect(store.readData(LocalData.offlineAutoUpdate), '1');

    // "Seguir" con datos del móvil y "solo con wifi": Flyra lo dice, y
    // "Usar datos" quita "solo con wifi" y vuelve a intentarlo.
    spy.send!('act:BCN');
    await spy.wait(tester, () => data()['fly'] != null);
    final Map<String, Object?> fly = data()['fly']! as Map<String, Object?>;
    expect(fly['title'], 'Descarga en pausa');
    expect(fly['main'], 'Usar datos');
    spy.send!('flyMain');
    await spy.wait(tester, () => item(data(), 'BCN')['st'] == 'done');
    expect(store.readData(LocalData.offlineWifiOnly), '0');
    expect(data()['fly'], isNull);
    expect(OfflineLibrary(store).paused(), isEmpty);
  });
}
