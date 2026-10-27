// Mi pasaporte: páginas por país, rareza de los cromos y la ficha.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:eclipta/auth/session.dart';
import 'package:eclipta/core/router.dart';
import 'package:eclipta/core/settings.dart';
import 'package:eclipta/features/camera/stamps.dart';
import 'package:eclipta/features/passport/passport.dart';
import 'package:eclipta/features/route/flight3d.dart' show CountryCodes;
import 'package:eclipta/features/route/geo.dart';
import 'package:eclipta/features/route/world_data.dart';

import 'camera_test.dart' show FakeSpeaker;
import 'helpers.dart';

const List<Airport> airports = <Airport>[
  Airport(
    iata: 'HND',
    position: LatLon(35.55, 139.78),
    city: 'Tokyo',
    country: 'Japan',
    timeZone: 'Asia/Tokyo',
  ),
  Airport(
    iata: 'MAD',
    position: LatLon(40.47, -3.56),
    city: 'Madrid',
    country: 'Spain',
    timeZone: 'Europe/Madrid',
  ),
];

final CountryCodes codes = CountryCodes(<String, String>{
  'Japan': 'JP',
  'Spain': 'ES',
});

Stamp stamp(String qid, int day, {double? lat, double? lon, int? year}) =>
    Stamp(
      qid: qid,
      name: 'Monumento $qid',
      date: DateTime.utc(2026, 10, day),
      lat: lat,
      lon: lon,
      year: year,
      description: 'Una historia de $qid',
    );

void main() {
  test('la rareza depende de la edad', () {
    expect(rarityOf(80), Rarity.legendary);
    expect(rarityOf(1221), Rarity.epic);
    expect(rarityOf(1768), Rarity.rare);
    expect(rarityOf(1990), Rarity.common);
    expect(rarityOf(null), Rarity.common);
  });

  test('banderas sin imágenes', () {
    expect(flagOf('jp'), '🇯🇵');
    expect(flagOf('ES'), '🇪🇸');
    expect(flagOf('???'), '🏳️');
  });

  test('una página por país; el más nuevo primero; sin sitio al final', () {
    final List<PassportPage> pages = pagesOf(
      <Stamp>[
        stamp('Q1', 1, lat: 40.41, lon: -3.70), // Madrid
        stamp('Q2', 5, lat: 35.66, lon: 139.70), // Tokio
        stamp('Q3', 3), // un sello antiguo, sin coordenadas
        stamp('Q4', 4, lat: 40.42, lon: -3.71),
      ],
      airports: airports,
      codes: codes,
    );
    expect(pages.map((PassportPage p) => p.country), <String?>[
      'JP',
      'ES',
      null,
    ]);
    expect(pages[1].stamps.map((Stamp s) => s.qid), <String>['Q4', 'Q1']);
    expect(pages[1].cities, <String>['Madrid']);
    expect(pages[2].stamps.single.qid, 'Q3');
  });

  test('los sellos viejos (sin lugar) se siguen leyendo', () {
    final MemorySettingsStore prefs = MemorySettingsStore()
      ..stamps = jsonEncode(<Object?>[
        <String, Object?>{'qid': 'Q1', 'name': 'Uno', 'date': '2026-01-01'},
        <String, Object?>{
          'qid': 'Q2',
          'name': 'Dos',
          'date': '2026-01-02',
          'lat': 'x',
          'year': 1500,
        },
      ]);
    final List<Stamp> all = StampBook(prefs).all();
    expect(all, hasLength(2));
    expect(all.first.lat, isNull);
    expect(all.last.lat, isNull);
    expect(all.last.year, 1500);
  });

  test('ver en el mapa abre OpenStreetMap', () {
    expect(
      osmLink(40.4, -3.7).toString(),
      'https://www.openstreetmap.org/?mlat=40.4&mlon=-3.7#map=17/40.4/-3.7',
    );
  });

  group('pantalla', () {
    testWidgets('sin sellos invita a usar la cámara', (
      WidgetTester tester,
    ) async {
      final FakeGateway g = FakeGateway();
      final SessionController session = await signedInSession(g);
      await pumpApp(
        tester,
        locale: 'es',
        session: session,
        initialLocation: Routes.passport,
        services: fakeServices(session, gateway: g),
      );
      expect(find.text('Abrir la cámara'), findsOneWidget);
    });

    testWidgets('la tapa se abre; un cromo se escucha y se abre en el mapa', (
      WidgetTester tester,
    ) async {
      final FakeGateway g = FakeGateway();
      final SessionController session = await signedInSession(g);
      final MemorySettingsStore prefs = MemorySettingsStore();
      await StampBook(prefs)
          .add(stamp('Q9', 2, lat: 41.9, lon: 12.49, year: 80));
      final FakeSpeaker voice = FakeSpeaker();
      final List<Uri> opened = <Uri>[];
      tester.view.physicalSize = const Size(1200, 2600);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      await pumpApp(
        tester,
        locale: 'es',
        session: session,
        initialLocation: Routes.passport,
        services: fakeServices(
          session,
          gateway: g,
          prefs: prefs,
          speaker: voice,
          openLink: (Uri u) async {
            opened.add(u);
            return true;
          },
        ),
      );
      expect(find.text('PASAPORTE DE VIAJE'), findsOneWidget);
      expect(find.text('ANA'), findsOneWidget);
      await tester.tap(find.text('Toca para abrir'));
      await tester.pumpAndSettle();
      // El país llega cuando cargan los aeropuertos (puede tardar en tests).
      expect(find.textContaining('1 sello · '), findsOneWidget);
      expect(find.text('LEGENDARIA'), findsOneWidget);

      await tester.tap(find.text('Monumento Q9'));
      await tester.pumpAndSettle();
      expect(find.text('Una historia de Q9'), findsOneWidget);
      await tester.tap(find.text('Escuchar'));
      await tester.pumpAndSettle();
      expect(voice.said.single, 'Monumento Q9. Una historia de Q9');
      await tester.tap(find.text('Ver en el mapa'));
      await tester.pumpAndSettle();
      expect(opened.single.host, 'www.openstreetmap.org');
    });
  });
}
