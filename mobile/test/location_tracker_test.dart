// Tests del rastreador de ubicación y del "modo viaje", con GPS falso.
import 'package:flutter_test/flutter_test.dart';
import 'package:eclipta/auth/session.dart';
import 'package:eclipta/core/settings.dart';
import 'package:eclipta/features/map/geo.dart';
import 'package:eclipta/features/map/location.dart';
import 'package:eclipta/features/map/location_tracker.dart';
import 'package:eclipta/features/map/position_reporter.dart';

import 'helpers.dart';

void main() {
  late FakeGateway g;
  late FakeLocation loc;
  late MemorySettingsStore prefs;
  late List<PositionFix> sent;

  setUp(() {
    g = FakeGateway();
    loc = FakeLocation()..access = LocationAccess.granted;
    prefs = MemorySettingsStore();
    sent = <PositionFix>[];
  });

  LocationTracker tracker(
    SessionController s, {
    Future<bool> Function()? ask,
  }) => fakeTracker(
    s,
    location: loc,
    gateway: g,
    prefs: prefs,
    askNotifications: ask,
    // Un cartero que solo apunta (lotes de 1 para verlo al momento).
    newReporter: (SendPositions send) => PositionReporter(
      send: (List<PositionFix> fixes) async {
        sent.addAll(fixes);
        return fixes.length;
      },
      batchSize: 1,
    ),
  );

  PositionFix fix() => PositionFix(
    point: const GeoPoint(40.4169, -3.7035),
    accuracyM: 8,
    recordedAt: DateTime.now(),
  );

  test(
    'sin modo viaje: al salir de la app se apaga y al volver se enciende',
    () async {
      final LocationTracker t = tracker(await signedInSession(g));
      await t.resume();
      expect(t.tracking, isTrue);
      expect(loc.watches, <bool>[false]); // GPS normal, sin notificación fija

      loc.fixes.add(fix());
      await pumpEventQueue();
      expect(t.me, isNotNull);
      expect(sent, hasLength(1)); // con cuenta, las posiciones se mandan

      await t.paused();
      expect(t.tracking, isFalse);
      await t.appResumed();
      expect(t.tracking, isTrue);
      t.dispose();
    },
  );

  test('abrir la app no enciende el GPS si no se usó antes', () async {
    final LocationTracker t = tracker(await signedInSession(g));
    await t.appResumed();
    expect(t.tracking, isFalse);
    expect(loc.watches, isEmpty);
    t.dispose();
  });

  test('modo viaje: sigue con la app cerrada y se recuerda', () async {
    int asked = 0;
    final LocationTracker t = tracker(
      await signedInSession(g),
      ask: () async {
        asked++;
        return true;
      },
    );
    await t.resume();
    expect(await t.setTravelMode(true), TravelModeResult.on);
    expect(asked, 1);
    expect(t.travelMode, isTrue);
    expect(prefs.travelMode, isTrue);
    expect(loc.watches.last, isTrue); // ahora con notificación fija

    await t.paused();
    expect(t.tracking, isTrue); // no se apaga al salir
    loc.fixes.add(fix());
    await pumpEventQueue();
    expect(sent, hasLength(1));

    // Al volver a abrir la app (otro día), arranca solo en modo viaje.
    final LocationTracker again = tracker(await signedInSession(g));
    expect(again.travelMode, isTrue);
    await again.appResumed();
    expect(loc.watches.last, isTrue);

    await t.setTravelMode(false);
    expect(prefs.travelMode, isFalse);
    t.dispose();
    again.dispose();
  });

  test('modo viaje: pide cuenta, ubicación y notificaciones', () async {
    final LocationTracker guest = tracker(newSession(g)..continueAsGuest());
    expect(await guest.setTravelMode(true), TravelModeResult.needsAccount);
    guest.dispose();

    final LocationTracker noNotices = tracker(
      await signedInSession(g),
      ask: () async => false,
    );
    expect(
      await noNotices.setTravelMode(true),
      TravelModeResult.needsNotifications,
    );
    expect(noNotices.travelMode, isFalse);
    noNotices.dispose();

    loc
      ..access = LocationAccess.denied
      ..onRequest = LocationAccess.deniedForever;
    final LocationTracker noGps = tracker(await signedInSession(g));
    expect(await noGps.setTravelMode(true), TravelModeResult.needsLocation);
    noGps.dispose();
  });

  test('al cerrar sesión, el modo viaje deja de funcionar', () async {
    final SessionController s = await signedInSession(g);
    final LocationTracker t = tracker(s);
    await t.resume();
    await t.setTravelMode(true);
    await s.signOut();
    await pumpEventQueue();
    expect(t.canTravel, isFalse);
    expect(loc.watches.last, isFalse); // vuelve al GPS normal
    loc.fixes.add(fix());
    await pumpEventQueue();
    expect(sent, isEmpty); // y ya no se manda nada al servidor
    t.dispose();
  });
}
