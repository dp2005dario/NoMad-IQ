// Papeles y derechos: revisión de documentos y la norma europea EU261.
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:eclipta/core/router.dart';
import 'package:eclipta/features/papers/eu261.dart';
import 'package:eclipta/features/papers/trip_check.dart';
import 'package:eclipta/features/route/geo.dart';
import 'package:eclipta/features/route/world_data.dart';
import 'package:eclipta/features/vault/vault.dart';

import 'helpers.dart';
import 'vault_test.dart' show FakeUnlocker, newVault;

const LatLon mad = LatLon(40.47, -3.56);
const LatLon bcn = LatLon(41.30, 2.08);
const LatLon hnd = LatLon(35.55, 139.78);
const LatLon jfk = LatLon(40.64, -73.78);
const LatLon tfn = LatLon(28.48, -16.34); // Tenerife Norte
const LatLon hel = LatLon(60.32, 24.96);

VaultDoc doc(DocKind kind, DateTime? expires) => VaultDoc(
  id: '0' * 32,
  kind: kind,
  title: kind.name,
  mime: 'image/jpeg',
  added: DateTime(2026),
  expires: expires,
);

void main() {
  group('EU261', () {
    Eu261Result calc(
      String from,
      String to,
      LatLon a,
      LatLon b, {
      bool euAirline = true,
      Disruption what = Disruption.delay,
      int minutes = 300,
    }) => eu261(
      fromCountry: from,
      toCountry: to,
      from: a,
      to: b,
      euAirline: euAirline,
      what: what,
      delayMinutes: minutes,
    );

    test('las tres cantidades según la distancia', () {
      expect(calc('ES', 'ES', mad, bcn).euros, 250);
      expect(calc('ES', 'US', mad, jfk).euros, 600);
      expect(calc('ES', 'ES', mad, tfn).euros, 400); // 1.700 km
      // Dentro de la UE y más de 3.500 km sigue siendo 400.
      expect(calc('FI', 'ES', hel, tfn).euros, 400);
    });

    test('de 3 a 4 horas en un vuelo largo, la mitad', () {
      expect(calc('ES', 'JP', mad, hnd, minutes: 200).euros, 300);
      expect(calc('ES', 'JP', mad, hnd, minutes: 265).euros, 600);
      // La cancelación no tiene esa rebaja.
      expect(
        calc(
          'ES',
          'JP',
          mad,
          hnd,
          what: Disruption.cancelled,
          minutes: 0,
        ).euros,
        600,
      );
    });

    test('quién está cubierto', () {
      // Japón → España con aerolínea japonesa: no.
      expect(
        calc('JP', 'ES', hnd, mad, euAirline: false).reason,
        Eu261Reason.notEuRoute,
      );
      // ...con aerolínea europea: sí.
      expect(calc('JP', 'ES', hnd, mad).covered, isTrue);
      // Desde la UE, con cualquier aerolínea: sí.
      expect(calc('ES', 'JP', mad, hnd, euAirline: false).covered, isTrue);
      expect(
        calc('ES', 'ES', mad, bcn, minutes: 150).reason,
        Eu261Reason.shortDelay,
      );
    });

    test('la carta lleva todo y el correo va bien escrito', () {
      final ClaimDetails d = ClaimDetails(
        name: 'Ana Pérez',
        booking: 'ABC123',
        flight: 'IB6800',
        date: DateTime(2026, 3, 9),
        from: const Airport(
          iata: 'HND',
          position: hnd,
          city: 'Tokyo',
          country: 'Japan',
          timeZone: 'Asia/Tokyo',
        ),
        to: const Airport(
          iata: 'MAD',
          position: mad,
          city: 'Madrid',
          country: 'Spain',
          timeZone: 'Europe/Madrid',
        ),
        what: Disruption.delay,
        delayMinutes: 265,
        euros: 600,
      );
      final String letter = claimLetter(d);
      expect(letter, contains('Regulation (EC) No 261/2004'));
      expect(letter, contains('IB6800 on 2026-03-09'));
      expect(letter, contains('4 h 25 min late'));
      expect(letter, contains('EUR 600'));
      final Uri mail = claimEmail(d);
      expect(mail.scheme, 'mailto');
      expect(mail.toString(), isNot(contains('+')));
      expect(Uri.decodeComponent(mail.query), contains('Ana Pérez'));
    });
  });

  group('antes de salir', () {
    final DateTime back = DateTime(2027, 3, 20);

    test('pasaporte con 6 meses de margen y seguro vigente', () {
      final TripChecks ok = checkTrip(<VaultDoc>[
        doc(DocKind.passport, DateTime(2030)),
        doc(DocKind.insurance, DateTime(2027, 12)),
      ], back);
      expect(ok.issues, 0);
      final TripChecks bad = checkTrip(<VaultDoc>[
        doc(DocKind.passport, DateTime(2027, 6)),
        doc(DocKind.insurance, DateTime(2027, 3, 1)),
      ], back);
      expect(bad.passport, CheckState.warning);
      expect(bad.insurance, CheckState.warning);
      expect(checkTrip(<VaultDoc>[], back).passport, CheckState.missing);
      // Con dos pasaportes vale el que más dura.
      expect(
        checkTrip(<VaultDoc>[
          doc(DocKind.passport, DateTime(2027, 4)),
          doc(DocKind.passport, DateTime(2031)),
        ], back).passport,
        CheckState.ok,
      );
    });
  });

  testWidgets('pantalla: revisar con la Bóveda y calcular la reclamación', (
    WidgetTester tester,
  ) async {
    final FakeGateway g = FakeGateway();
    final session = await signedInSession(g);
    final FakeUnlocker unlocker = FakeUnlocker();
    final Vault vault = newVault(unlocker);
    await vault.open('x');
    await vault.add(
      kind: DocKind.passport,
      title: 'Pasaporte',
      mime: 'image/jpeg',
      bytes: Uint8List.fromList(<int>[1]),
      expires: DateTime(2027, 1, 1),
    );
    vault.close();
    final List<Uri> opened = <Uri>[];
    tester.view.physicalSize = const Size(1200, 5000);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await pumpApp(
      tester,
      locale: 'es',
      session: session,
      initialLocation: Routes.papers,
      services: fakeServices(
        session,
        gateway: g,
        vault: vault,
        openLink: (Uri u) async {
          opened.add(u);
          return true;
        },
      ),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(seconds: 2)),
    );
    await tester.pumpAndSettle();
    expect(find.text('Papeles y derechos'), findsOneWidget);

    // Reclamación: Tokio → Madrid con aerolínea europea, 5 horas tarde.
    await tester.enterText(
      find.widgetWithText(TextField, 'Desde (aeropuerto)'),
      'HND',
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Hasta (aeropuerto)'),
      'MAD',
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('600'), findsWidgets);
    await tester.tap(find.text('Preparar la reclamación'));
    await tester.pumpAndSettle();
    final Finder dialogFields = find.descendant(
      of: find.byType(AlertDialog),
      matching: find.byType(TextField),
    );
    await tester.enterText(dialogFields.at(0), 'Ana Pérez');
    await tester.enterText(dialogFields.at(1), 'abc123');
    await tester.enterText(dialogFields.at(2), 'ib6800');
    await tester.tap(find.text('Abrir el correo con la carta'));
    await tester.pumpAndSettle();
    expect(opened.single.scheme, 'mailto');
    expect(Uri.decodeComponent(opened.single.query), contains('ABC123'));

    // Antes de salir: Tokio, con un pasaporte que caduca muy pronto.
    await tester.enterText(
      find.widgetWithText(TextField, 'Aeropuerto de destino (p. ej. NRT)'),
      'NRT',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Elegir día de vuelta'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('ACEPTAR'));
    await tester.pumpAndSettle();
    final int before = unlocker.asked;
    await tester.tap(find.text('Revisar con la Bóveda'));
    await tester.pumpAndSettle();
    expect(unlocker.asked, before + 1);
    expect(find.textContaining('muchos países piden 6 meses'), findsOneWidget);
    expect(find.text('No hay seguro de viaje en la Bóveda'), findsOneWidget);
    vault.close(); // que no quede el reloj del cierre automático
  });
}
