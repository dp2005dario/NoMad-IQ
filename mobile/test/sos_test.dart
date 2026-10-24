// SOS: números del país, el SMS con la ubicación, contactos y ficha médica.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nomadiq/core/router.dart';
import 'package:nomadiq/core/settings.dart';
import 'package:nomadiq/features/map/geo.dart';
import 'package:nomadiq/features/map/location.dart';
import 'package:nomadiq/features/route/geo.dart';
import 'package:nomadiq/features/route/world_data.dart';
import 'package:nomadiq/features/sos/emergency_data.dart';
import 'package:nomadiq/features/sos/sos_store.dart';
import 'package:nomadiq/features/sos/where_am_i.dart';

import 'helpers.dart';

void main() {
  group('datos', () {
    test('cada país su número; si no se sabe, el 112', () {
      expect(numbersFor('JP').ambulance, '119');
      expect(numbersFor('US').general, '911');
      expect(numbersFor('ES').general, '112');
      expect(numbersFor(null).general, '112');
      expect(numbersFor('XX').general, '112');
      expect(phraseFor('JP')?.text, '助けて！');
      expect(phraseFor('JP')?.sounds, 'Tasukete!');
      expect(phraseFor('MX')?.text, '¡Ayuda!');
      expect(phraseFor(null), isNull);
    });

    test('el aeropuerto más cercano dice el país (y en alta mar, nada)', () {
      final List<Airport> airports = <Airport>[
        const Airport(
          iata: 'HND',
          position: LatLon(35.55, 139.78),
          city: 'Tokyo',
          country: 'Japan',
          timeZone: 'Asia/Tokyo',
        ),
        const Airport(
          iata: 'MAD',
          position: LatLon(40.47, -3.56),
          city: 'Madrid',
          country: 'Spain',
          timeZone: 'Europe/Madrid',
        ),
      ];
      expect(
        nearestAirport(airports, const LatLon(35.66, 139.70))?.iata,
        'HND',
      );
      expect(nearestAirport(airports, const LatLon(0, -30)), isNull);
    });

    test('teléfonos, SMS y ficha médica', () {
      expect(SosContact.isPhone('+34 600 11 22 33'), isTrue);
      expect(SosContact.isPhone('12'), isFalse);
      expect(SosContact.isPhone('llámame'), isFalse);
      const SosContact ana = SosContact(name: 'Ana', phone: '+34 600-11-22-33');
      expect(ana.dial, '+34600112233');
      final Uri sms = smsUri(<SosContact>[
        ana,
      ], sosMessage('¡Ayuda!', const GeoPoint(35.65, 139.7)));
      expect(sms.scheme, 'sms');
      expect(sms.path, '+34600112233');
      expect(
        sms.queryParameters['body'],
        contains('openstreetmap.org/?mlat=35.65000&mlon=139.70000'),
      );
      expect(telUri('112').toString(), 'tel:112');

      const MedicalCard card = MedicalCard(blood: '0+', conditions: 'celíaco');
      expect(card.summary(), '0+ · celíaco');
      expect(const MedicalCard().isEmpty, isTrue);
    });

    test('se guardan en el móvil y lo roto se ignora', () async {
      final MemorySettingsStore prefs = MemorySettingsStore();
      await saveContacts(prefs, <SosContact>[
        const SosContact(name: 'Ana', phone: '600112233'),
      ]);
      expect(loadContacts(prefs).single.name, 'Ana');
      await const MedicalCard(
        blood: 'AB-',
        allergies: 'penicilina',
      ).save(prefs);
      expect(MedicalCard.load(prefs).allergies, 'penicilina');
      prefs.data[LocalData.medicalCard] = '{"blood":"Z+"}';
      expect(MedicalCard.load(prefs).blood, isNull);
      prefs.data[LocalData.sosContacts] = 'roto';
      expect(loadContacts(prefs), isEmpty);
    });
  });

  testWidgets('mantener 3 s activa el SOS: llamar y avisar por SMS', (
    WidgetTester tester,
  ) async {
    final FakeGateway g = FakeGateway();
    final session = await signedInSession(g);
    final FakeLocation gps = FakeLocation()..access = LocationAccess.granted;
    final MemorySettingsStore prefs = MemorySettingsStore();
    await saveContacts(prefs, <SosContact>[
      const SosContact(name: 'Ana', phone: '+34600112233'),
    ]);
    final List<Uri> opened = <Uri>[];
    tester.view.physicalSize = const Size(1200, 4000);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await pumpApp(
      tester,
      locale: 'es',
      session: session,
      initialLocation: Routes.home,
      services: fakeServices(
        session,
        gateway: g,
        location: gps,
        prefs: prefs,
        openLink: (Uri u) async {
          opened.add(u);
          return true;
        },
      ),
    );
    await tester.tap(find.text('SOS'));
    await tester.pumpAndSettle();
    expect(find.text('¿Necesitas ayuda?'), findsOneWidget);
    gps.fixes.add(
      PositionFix(
        point: const GeoPoint(35.6595, 139.7005),
        accuracyM: 8,
        recordedAt: DateTime.utc(2026, 10, 23),
      ),
    );
    // Los datos del mundo se cargan de verdad (assets): se deja tiempo.
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(seconds: 2)),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('GPS ±8 m'), findsOneWidget);
    expect(find.text('助けて！'), findsOneWidget);
    expect(find.text('Ambulancia · 119'), findsOneWidget);

    // Soltar antes de tiempo no hace nada.
    final TestGesture press = await tester.startGesture(
      tester.getCenter(find.byKey(const ValueKey<String>('sos-hold'))),
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await press.up();
    await tester.pumpAndSettle();
    expect(find.text('Pide ayuda ya'), findsNothing);

    final TestGesture hold = await tester.startGesture(
      tester.getCenter(find.byKey(const ValueKey<String>('sos-hold'))),
    );
    await tester.pump(); // el primer fotograma arranca el reloj
    await tester.pump(const Duration(milliseconds: 3100));
    await hold.up();
    await tester.pumpAndSettle();
    expect(find.text('Pide ayuda ya'), findsOneWidget);
    await tester.tap(find.text('Llamar al 110'));
    await tester.tap(find.text('Mandar mi ubicación a mis contactos'));
    await tester.pumpAndSettle();
    expect(opened.first.toString(), 'tel:110');
    expect(opened.last.scheme, 'sms');
    expect(opened.last.queryParameters['body'], startsWith('¡Necesito ayuda!'));
  });
}
