// Tests de la lógica del mapa (sin pantallas): geometría, histéresis de
// zonas, el cartero de posiciones, el estilo y las llamadas al servidor.
import 'dart:convert';
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:eclipta/auth/session.dart';
import 'package:eclipta/core/api_client.dart';
import 'package:eclipta/features/map/geo.dart';
import 'package:eclipta/features/map/geo_api.dart';
import 'package:eclipta/features/map/location.dart';
import 'package:eclipta/features/map/map_model.dart';
import 'package:eclipta/features/map/map_patterns.dart';
import 'package:eclipta/features/map/map_style.dart';
import 'package:eclipta/features/map/position_reporter.dart';
import 'package:eclipta/features/map/zone_watcher.dart';

import 'helpers.dart';
import 'zones_fixture.dart';

void main() {
  group('geometría', () {
    test('lee zonas del GeoJSON y descarta las rotas', () {
      final Zone? sol = Zone.fromFeature(solFeature);
      expect(sol, isNotNull);
      expect(sol!.name, 'Puerta del Sol');
      expect(sol.kind, ZoneKind.touristArea);
      expect(sol.kind.hasAudioguide, isTrue);

      expect(Zone.fromFeature(<String, Object?>{'id': 'x'}), isNull);
      expect(
        Zone.fromFeature(<String, Object?>{
          ...solFeature,
          'properties': <String, Object?>{
            'slug': 's',
            'name': 'n',
            'kind': 'volcano', // tipo desconocido
          },
        }),
        isNull,
      );
      expect(ZoneKind.airport.hasAudioguide, isFalse);
    });

    test('dentro, fuera y en un agujero', () {
      final Zone donut = Zone.fromFeature(
        square('d', 'Donut', 'city_center', 40.0, -3.0, 0.01, hole: 0.002),
      )!;
      expect(donut.contains(const GeoPoint(40.005, -3.005)), isTrue);
      expect(donut.contains(const GeoPoint(40.02, -3.0)), isFalse);
      expect(donut.contains(const GeoPoint(40.0, -3.0)), isFalse); // agujero
    });

    test('la caja respeta el límite del servidor', () {
      const GeoBox box = GeoBox(
        minLon: -3.72,
        minLat: 40.40,
        maxLon: -3.69,
        maxLat: 40.43,
      );
      expect(box.fitsServerLimit, isTrue);
      expect(box.toQuery(), '-3.72000,40.40000,-3.69000,40.43000');
      final GeoBox big = box.grow(1000);
      expect(big.lonSpan, closeTo(GeoBox.maxSpanDeg, 1e-9));
      expect(big.fitsServerLimit, isTrue);
      expect(big.containsBox(box), isTrue);
      const GeoBox world = GeoBox(
        minLon: -10,
        minLat: 30,
        maxLon: 10,
        maxLat: 50,
      );
      expect(world.fitsServerLimit, isFalse);
    });

    test('distancia aproximada', () {
      // De la Puerta del Sol a la Plaza Mayor: unos 400 m.
      const GeoPoint sol = GeoPoint(40.41694, -3.70361);
      const GeoPoint mayor = GeoPoint(40.41553, -3.70742);
      expect(sol.distanceTo(mayor), inInclusiveRange(300, 450));
    });
  });

  group('aviso al entrar en una zona', () {
    final List<Zone> zones = <Zone>[madridZone(), solZone(), airportZone()];
    PositionFix at(GeoPoint p, int second, {double accuracy = 8}) =>
        PositionFix(
          point: p,
          accuracyM: accuracy,
          recordedAt: DateTime.utc(2026, 10, 23, 10, 0, second),
        );

    test('hay que llevar 15 s dentro, y gana la zona más concreta', () {
      final ZoneWatcher w = ZoneWatcher();
      expect(w.update(at(solCenter, 0), zones), isNull);
      expect(w.update(at(solCenter, 10), zones), isNull);
      final Zone? entered = w.update(at(solCenter, 16), zones);
      expect(entered?.name, 'Puerta del Sol'); // y no "Centro de Madrid"
      // Ya dentro: no se repite el aviso.
      expect(w.update(at(solCenter, 30), zones), isNull);
      expect(w.current?.name, 'Puerta del Sol');
    });

    test('el GPS que tiembla en el borde no hace entrar y salir', () {
      final ZoneWatcher w = ZoneWatcher();
      const GeoPoint outside = GeoPoint(40.5, -3.5);
      for (int s = 0; s < 60; s += 5) {
        expect(w.update(at(s.isEven ? solCenter : outside, s), zones), isNull);
      }
    });

    test('un GPS impreciso no cuenta y los aeropuertos no avisan', () {
      final ZoneWatcher w = ZoneWatcher(dwell: Duration.zero);
      expect(w.update(at(solCenter, 0, accuracy: 500), zones), isNull);
      expect(w.update(at(airportCenter, 1), zones), isNull);
    });

    test('se sale tras 15 s fuera y se puede volver a entrar', () {
      final ZoneWatcher w = ZoneWatcher();
      const GeoPoint away = GeoPoint(41.0, -4.0);
      w.update(at(solCenter, 0), zones);
      expect(w.update(at(solCenter, 15), zones)?.name, 'Puerta del Sol');
      w.update(at(away, 20), zones);
      expect(w.current, isNotNull); // aún no: 15 s de margen
      w.update(at(away, 36), zones);
      expect(w.current, isNull);
      w.update(at(solCenter, 40), zones);
      expect(w.update(at(solCenter, 55), zones)?.name, 'Puerta del Sol');
    });
  });

  group('cartero de posiciones', () {
    PositionFix fix(int i, DateTime now) => PositionFix(
      point: GeoPoint(40.4 + i / 1000, -3.7),
      accuracyM: 5,
      recordedAt: now,
    );

    test('agrupa de 10 en 10 o espera como mucho 1 minuto', () {
      fakeAsync((FakeAsync async) {
        final List<int> batches = <int>[];
        final PositionReporter r = PositionReporter(
          send: (List<PositionFix> f) async {
            batches.add(f.length);
            return f.length;
          },
          clock: () => DateTime.now(),
        );
        for (int i = 0; i < 12; i++) {
          r.add(fix(i, DateTime.now()));
        }
        async.flushMicrotasks();
        expect(batches, <int>[10]);
        expect(r.pending, 2);
        async.elapse(const Duration(seconds: 61));
        expect(batches, <int>[10, 2]);
        expect(r.pending, 0);
        r.dispose();
      });
    });

    test('sin red reintenta más tarde; un lote inválido se tira', () {
      fakeAsync((FakeAsync async) {
        int calls = 0;
        ApiError? failWith = ApiError.network;
        final PositionReporter r = PositionReporter(
          send: (List<PositionFix> f) async {
            calls++;
            final ApiError? e = failWith;
            if (e != null) throw ApiException(e);
            return f.length;
          },
          batchSize: 1,
        );
        r.add(fix(0, DateTime.now()));
        async.flushMicrotasks();
        expect(calls, 1);
        expect(r.pending, 1); // se guarda para después
        failWith = null;
        async.elapse(const Duration(seconds: 16));
        expect(calls, 2);
        expect(r.pending, 0);

        failWith = ApiError.invalidInput;
        r.add(fix(1, DateTime.now()));
        async.flushMicrotasks();
        expect(r.pending, 0); // el servidor nunca lo aceptaría

        failWith = ApiError.signedOut;
        r.add(fix(2, DateTime.now()));
        async.flushMicrotasks();
        r.add(fix(3, DateTime.now()));
        async.flushMicrotasks();
        expect(r.pending, 0); // sin cuenta se olvida todo y se para
        r.dispose();
      });
    });

    test('las posiciones de hace más de 23 h no se mandan', () async {
      final List<PositionFix> sent = <PositionFix>[];
      final DateTime now = DateTime.utc(2026, 10, 23, 12);
      final PositionReporter r = PositionReporter(
        send: (List<PositionFix> f) async {
          sent.addAll(f);
          return f.length;
        },
        clock: () => now,
      );
      r.add(fix(0, now.subtract(const Duration(hours: 30))));
      r.add(fix(1, now.subtract(const Duration(minutes: 1))));
      await r.flush();
      expect(sent, hasLength(1));
      r.dispose();
    });
  });

  group('estilo del mapa', () {
    test('día, atardecer y noche según la hora', () {
      expect(resolveLook(MapLook.auto, DateTime(2026, 1, 1, 12)), MapLook.day);
      expect(resolveLook(MapLook.auto, DateTime(2026, 1, 1, 19)), MapLook.dusk);
      expect(
        resolveLook(MapLook.auto, DateTime(2026, 1, 1, 23)),
        MapLook.night,
      );
      expect(
        resolveLook(MapLook.night, DateTime(2026, 1, 1, 12)),
        MapLook.night,
      );
    });

    test('rotula en tu idioma y trae las capas de ECLIPTA', () {
      final Map<String, Object?> style = buildMapStyle(
        look: MapLook.night,
        language: 'ja',
        tilesUrl: Uri.parse('https://tiles.test/planet'),
        glyphsUrl: 'https://tiles.test/fonts/{fontstack}/{range}.pbf',
      );
      final String json = jsonEncode(style);
      expect(json, contains('"name:ja"'));
      expect(json, contains('#0b1217')); // el fondo de la app
      final List<Object?> layers = style['layers']! as List<Object?>;
      final List<Object?> ids = <Object?>[
        for (final Object? l in layers) (l! as Map<String, Object?>)['id'],
      ];
      expect(
        ids,
        containsAll(<String>[
          MapIds.zonesFill,
          MapIds.zonesLine,
          MapIds.zonesLabel,
          'building-3d',
        ]),
      );
      // Tu posición se dibuja encima de las zonas.
      expect(ids.last, 'nomad-me-dot');
      final Map<String, Object?> sources =
          style['sources']! as Map<String, Object?>;
      expect(sources.keys, contains(MapIds.zonesSource));
      final String day = jsonEncode(
        buildMapStyle(
          look: MapLook.day,
          language: 'ja',
          tilesUrl: Uri.parse('https://tiles.test/planet'),
          glyphsUrl: 'https://tiles.test/fonts/{fontstack}/{range}.pbf',
        ),
      );
      expect(day, isNot(json));
    });

    test('calles de verdad de cerca: bordillo, acera, asfalto y adoquín', () {
      final Map<String, Object?> style = buildMapStyle(
        look: MapLook.day,
        language: 'es',
        tilesUrl: Uri.parse('https://tiles.test/planet'),
        glyphsUrl: 'https://tiles.test/fonts/{fontstack}/{range}.pbf',
      );
      final List<String> ids = <String>[
        for (final Object? l in style['layers']! as List<Object?>)
          (l! as Map<String, Object?>)['id']! as String,
      ];
      // Las capas van de abajo arriba: bordillo y acera antes que el asfalto,
      // y la tapa del tejado encima de la fachada.
      expect(
        ids.indexOf('road-major-curb'),
        lessThan(ids.indexOf('road-major-sidewalk')),
      );
      expect(
        ids.indexOf('road-major-sidewalk'),
        lessThan(ids.indexOf('road-major')),
      );
      expect(
        ids.indexOf('road-major'),
        lessThan(ids.indexOf('road-major-texture')),
      );
      expect(
        ids.indexOf('building-facade'),
        lessThan(ids.indexOf('building-roof')),
      );
      final String json = jsonEncode(style);
      expect(json, contains(MapIds.cobblePattern));
      expect(json, contains(MapIds.facade(Facade.brick)));
      expect(
        (style['metadata']! as Map<String, Object?>)['nomadiq:look'],
        'day',
      );
    });

    testWidgets('las texturas se pintan como PNG de 64 px', (
      WidgetTester tester,
    ) async {
      final Map<String, Uint8List> night = (await tester.runAsync(
        () => mapPatterns(MapLook.night),
      ))!;
      expect(
        night.keys,
        containsAll(<String>[
          MapIds.cobblePattern,
          MapIds.facade(Facade.brick),
        ]),
      );
      // Cada imagen que nombra el estilo (calles, árboles, coches...) existe:
      // si faltara una, MapLibre dejaría ese hueco vacío.
      final String nightStyle = jsonEncode(
        buildMapStyle(
          look: MapLook.night,
          language: 'es',
          tilesUrl: Uri.parse('https://tiles.test/planet'),
          glyphsUrl: 'https://tiles.test/fonts/{fontstack}/{range}.pbf',
        ),
      );
      final Set<String> named = RegExp(r'"(nq-[a-z0-9-]+)"')
          .allMatches(nightStyle)
          .map((RegExpMatch m) => m.group(1)!)
          .toSet();
      expect(named, containsAll(<String>[MapIds.roadMajorPattern]));
      expect(night.keys, containsAll(named));
      for (final Uint8List png in night.values) {
        // Firma de un PNG: 0x89 'P' 'N' 'G'.
        expect(png.sublist(0, 4), <int>[0x89, 0x50, 0x4E, 0x47]);
      }
      // De día y de noche las fachadas son distintas (ventanas encendidas).
      final Map<String, Uint8List> day = (await tester.runAsync(
        () => mapPatterns(MapLook.day),
      ))!;
      expect(
        day[MapIds.facade(Facade.brick)],
        isNot(night[MapIds.facade(Facade.brick)]),
      );
    });
  });

  group('servidor', () {
    test(
      'pide zonas con el pase y renueva si el servidor lo rechaza',
      () async {
        final FakeGateway g = FakeGateway();
        final List<String> seen = <String>[];
        bool rejectOnce = true;
        g.services['/v1/zones'] = (http.Request r) {
          seen.add('${r.headers['Authorization']} ${r.url.query}');
          if (rejectOnce) {
            rejectOnce = false;
            return http.Response('', 401);
          }
          return FakeGateway.json(zonesCollection());
        };
        final GeoApi geo = GeoApi(await apiFor(g));
        final ZonePage page = await geo.zones(
          const GeoBox(
            minLon: -3.72,
            minLat: 40.40,
            maxLon: -3.69,
            maxLat: 40.43,
          ),
        );
        expect(page.zones.map((Zone z) => z.name), contains('Puerta del Sol'));
        expect(page.truncated, isFalse);
        expect(seen, hasLength(2));
        expect(seen.first, contains('bbox=-3.72000%2C40.40000'));
        // Segundo intento con un pase NUEVO (renovado).
        expect(seen[0].split(' ')[1], isNot(seen[1].split(' ')[1]));
        expect(g.calls, contains('POST /v1/auth/refresh'));
      },
    );

    test('manda posiciones en el formato del geo-engine', () async {
      final FakeGateway g = FakeGateway();
      Map<String, Object?>? body;
      g.services['/v1/positions'] = (http.Request r) {
        body = jsonDecode(r.body) as Map<String, Object?>;
        return FakeGateway.json(<String, Object?>{'accepted': 1}, 202);
      };
      final GeoApi geo = GeoApi(await apiFor(g));
      final int n = await geo.sendPositions('es', <PositionFix>[
        PositionFix(
          point: solCenter,
          accuracyM: 8,
          recordedAt: DateTime.fromMillisecondsSinceEpoch(1792000000000),
        ),
      ]);
      expect(n, 1);
      expect(body!['language'], 'es');
      expect((body!['positions']! as List<Object?>).single, <String, Object?>{
        'lat': solCenter.lat,
        'lon': solCenter.lon,
        'accuracy_m': 8.0,
        'recorded_at_ms': 1792000000000,
      });
    });

    test('un invitado ni siquiera llama al servidor', () async {
      final FakeGateway g = FakeGateway();
      final ApiClient api = ApiClient(
        baseUrl: Uri.parse('http://gateway.test'),
        session: newSession(g)..continueAsGuest(),
        client: g.client,
      );
      await expectLater(
        api.getJson('/v1/zones'),
        throwsA(
          isA<ApiException>().having(
            (ApiException e) => e.error,
            'error',
            ApiError.signedOut,
          ),
        ),
      );
      expect(g.calls, isEmpty);
    });
  });

  group('modelo del mapa', () {
    test('no vuelve a pedir lo que ya tiene y avisa si está lejos', () async {
      final FakeGateway g = FakeGateway();
      int requests = 0;
      g.services['/v1/zones'] = (http.Request r) {
        requests++;
        return FakeGateway.json(zonesCollection());
      };
      final SessionController session = await signedInSession(g);
      final MapModel m = MapModel(
        geo: GeoApi(
          ApiClient(
            baseUrl: Uri.parse('http://gateway.test'),
            session: session,
            client: g.client,
          ),
        ),
        tracker: fakeTracker(session, gateway: g),
      );
      const GeoBox view = GeoBox(
        minLon: -3.71,
        minLat: 40.41,
        maxLon: -3.70,
        maxLat: 40.42,
      );
      await m.onViewChanged(view);
      expect(m.status, ZonesStatus.ready);
      expect(m.zones, hasLength(3));
      await m.onViewChanged(view); // lo mismo: ya lo tiene
      expect(requests, 1);

      await m.onViewChanged(
        const GeoBox(minLon: -10, minLat: 30, maxLon: 10, maxLat: 50),
      );
      expect(m.status, ZonesStatus.tooFar);

      m.tapAt(solCenter);
      expect(m.selected?.name, 'Puerta del Sol'); // la más pequeña
      m.tapAt(const GeoPoint(10, 10));
      expect(m.selected, isNull);
      expect(m.search('sol').single.name, 'Puerta del Sol');
      m.dispose();
    });

    test('sin cuenta no pide zonas', () async {
      final MapModel m = MapModel(
        geo: null,
        tracker: fakeTracker(newSession()..continueAsGuest()),
      );
      await m.onViewChanged(
        const GeoBox(
          minLon: -3.71,
          minLat: 40.41,
          maxLon: -3.70,
          maxLat: 40.42,
        ),
      );
      expect(m.status, ZonesStatus.signedOut);
      m.dispose();
    });

    test('pide permiso solo cuando se pulsa el botón', () async {
      final FakeLocation loc = FakeLocation();
      final MapModel m = MapModel(
        geo: null,
        tracker: fakeTracker(newSession()..continueAsGuest(), location: loc),
      );
      await m.resumeLocation();
      expect(loc.requests, 0);
      expect(m.tracking, isFalse);
      loc.onRequest = LocationAccess.deniedForever;
      expect(await m.enableLocation(), LocationAccess.deniedForever);
      expect(m.tracking, isFalse);
      loc.access = LocationAccess.denied;
      loc.onRequest = LocationAccess.granted;
      expect(await m.enableLocation(), LocationAccess.granted);
      expect(m.tracking, isTrue);
      m.dispose();
    });
  });
}
