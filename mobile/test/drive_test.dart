// Modo coche: gasolinera más cercana, cargadores, aparcar y zonas ZTL.
// GPS de mentira en Positano; se pide una casilla de ~5 km y no se repite
// mientras sigues dentro.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:eclipta/core/router.dart';
import 'package:eclipta/features/camera/speaker.dart';
import 'package:eclipta/features/drive/drive_api.dart';
import 'package:eclipta/features/map/geo.dart';
import 'package:eclipta/features/map/location.dart';

import 'helpers.dart';

const GeoPoint positano = GeoPoint(40.6281, 14.4850);

PositionFix fix(GeoPoint p) => PositionFix(
  point: p,
  accuracyM: 10,
  recordedAt: DateTime.utc(2026, 10, 25),
);

/// Dos posiciones seguidas: Positano y 1 km más allá (misma casilla).
class DrivingLocation extends FakeLocation {
  DrivingLocation() {
    access = LocationAccess.granted;
  }

  @override
  Stream<PositionFix> watch({TrackingNotice? background}) =>
      Stream<PositionFix>.fromIterable(<PositionFix>[
        fix(positano),
        fix(const GeoPoint(40.635, 14.49)),
      ]);
}

class FakeSpeaker implements Speaker {
  final List<String> said = <String>[];

  @override
  Future<void> speak(String text, String language) async => said.add(text);

  @override
  Future<void> stop() async {}
}

const Map<String, Object?> driveJson = <String, Object?>{
  'lat': 40.65,
  'lon': 14.5,
  'attribution': '© OpenStreetMap contributors (ODbL)',
  'spots': <Object?>[
    // ~1,8 km al este.
    <String, Object?>{
      'id': 'n1',
      'kind': 'fuel',
      'lat': 40.6281,
      'lon': 14.5063,
      'brand': 'Esso',
      'opening_hours': '24/7',
    },
    // Más lejos: sale segunda.
    <String, Object?>{
      'id': 'n2',
      'kind': 'fuel',
      'lat': 40.66,
      'lon': 14.55,
      'brand': 'Q8',
    },
    <String, Object?>{
      'id': 'n3',
      'kind': 'ev',
      'lat': 40.629,
      'lon': 14.486,
      'brand': 'Enel X',
    },
    <String, Object?>{
      'id': 'w4',
      'kind': 'parking',
      'lat': 40.6285,
      'lon': 14.4870,
      'name': 'Parking Mandara',
      'fee': true,
      'capacity': 120,
    },
    <String, Object?>{
      'id': 'r5',
      'kind': 'lez',
      'lat': 40.628,
      'lon': 14.482,
      'name': 'ZTL Positano',
      'website': 'https://comune.positano.sa.it/ztl',
    },
  ],
};

void main() {
  test('la casilla de ~5 km', () {
    expect(driveCellOf(positano), const GeoPoint(40.65, 14.5));
    final DriveSpot? bad = DriveSpot.parse(<String, Object?>{
      'id': 'r1',
      'kind': 'lez',
      'lat': 1,
      'lon': 1,
      'website': 'javascript:alert(1)',
    });
    expect(bad!.website, isNull);
  });

  testWidgets('gasolina, eléctrico, aparcar y ZTL', (
    WidgetTester tester,
  ) async {
    final FakeGateway g = FakeGateway()..publicPrefixes.add('/v1/drive');
    final List<Uri> sent = <Uri>[];
    g.services['/v1/drive'] = (http.Request r) {
      sent.add(r.url);
      return FakeGateway.json(driveJson);
    };
    final List<Uri> opened = <Uri>[];
    final FakeSpeaker speaker = FakeSpeaker();
    final DrivingLocation gps = DrivingLocation();
    final session = newSession()..continueAsGuest();
    tester.view.physicalSize = const Size(1200, 4000);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await pumpApp(
      tester,
      locale: 'es',
      session: session,
      initialLocation: Routes.drive,
      services: fakeServices(
        session,
        gateway: g,
        location: gps,
        speaker: speaker,
        openBooking: (Uri u) async {
          opened.add(u);
          return true;
        },
      ),
    );
    await tester.pumpAndSettle();
    // Dos posiciones en la misma casilla: una sola pregunta.

    expect(sent.single.queryParameters, <String, String>{
      'lat': '40.65',
      'lon': '14.50',
    });
    expect(
      find.textContaining(RegExp(r'^Gasolinera a \d,\d km$')),
      findsOneWidget,
    );
    expect(find.text('Esso · Abierto 24 h'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Ir'));
    expect(opened.single.queryParameters['travelmode'], 'driving');
    expect(opened.single.queryParameters['destination'], '40.62810,14.50630');

    await tester.tap(find.text('Eléctrico'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Cargador a'), findsOneWidget);

    await tester.tap(find.text('Aparcar'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Parking Mandara a'), findsOneWidget);
    expect(find.text('de pago · 120 plazas'), findsOneWidget);
    // Se lee en voz alta al cambiar de modo.
    expect(speaker.said.last, contains('Parking Mandara'));

    await tester.tap(find.text('Zona ZTL'));
    await tester.pumpAndSettle();
    expect(find.textContaining('ZTL Positano a'), findsOneWidget);
    await tester.tap(find.text('Web oficial'));
    expect(opened.last.host, 'comune.positano.sa.it');
    await tester.tap(find.text('Ver las zonas de Europa'));
    expect(opened.last.host, 'urbanaccessregulations.eu');

    await tester.tap(find.text('Audioguía'));
    await tester.pumpAndSettle();
    expect(find.text('Audioguías mientras conduces'), findsWidgets);
  });
}
