// Visado: la tabla de pasaportes, los nombres de países, la lectura de la
// zona MRZ del pasaporte y la pantalla (con una Bóveda de mentira).
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:eclipta/core/router.dart';
import 'package:eclipta/core/settings.dart';
import 'package:eclipta/features/vault/vault.dart';
import 'package:eclipta/features/visa/mrz.dart';
import 'package:eclipta/features/visa/visa_data.dart';

import 'helpers.dart';
import 'vault_test.dart' show FakeUnlocker, newVault;

// El ejemplo oficial de la norma OACI 9303 (país de mentira "Utopía").
const String icaoTop = 'P<UTOERIKSSON<<ANNA<MARIA<<<<<<<<<<<<<<<<<<<';
const String icaoLow = 'L898902C36UTO7408122F1204159ZE184226B<<<<<10';

void main() {
  test('dígitos de control de la norma', () {
    expect(mrzCheckDigit('L898902C3'), 6);
    expect(mrzCheckDigit('740812'), 2);
    expect(mrzCheckDigit('120415'), 9);
  });

  test('lee la MRZ aunque el OCR la lea con ruido', () {
    final MrzData m = parseMrz(<String>[
      'PASAPORTE\nNombre ERIKSSON\n'
          '${icaoTop.replaceAll('<<<<<<<<', 'KKKKKKKK')}\n'
          // Espacios, «, una O en vez de 0 en la fecha: lo arreglamos.
          '${icaoLow.substring(0, 13)} 74O8122F12O4159ZE184226B««««<10',
    ], now: DateTime(2026, 10, 25))!;
    expect(m.surname, 'ERIKSSON');
    expect(m.givenNames, 'ANNA MARIA');
    expect(m.number, 'L898902C3');
    expect(m.nationality, 'UTO');
    expect(m.birth, DateTime(1974, 8, 12));
    expect(m.expiry, DateTime(2012, 4, 15));
    expect(m.sex, 'F');
  });

  test('si un dígito de control no cuadra, no se rellena nada', () {
    final String bad = icaoLow.replaceFirst('7408122', '7408123');
    expect(parseMrz(<String>['$icaoTop\n$bad']), isNull);
    expect(parseMrz(<String>['hola\nadiós']), isNull);
  });

  test('tabla de visados y nombres de países (los archivos de verdad)', () {
    final VisaTable table = VisaTable.parse(
      File('assets/geo/visas.txt').readAsStringSync(),
    );
    expect(table.updated, '2026-02-17');
    expect(table.lookup('ES', 'US').rule, EntryRule.eta);
    expect(table.lookup('es', 'us').days, 90);
    expect(table.lookup('ES', 'FR').rule, EntryRule.free);
    expect(table.lookup('ES', 'IN').rule, EntryRule.eVisa);
    expect(table.lookup('ES', 'ZZ').rule, EntryRule.unknown);
    expect(table.lookup('ES', 'ES').rule, EntryRule.unknown);

    final CountryNames names = CountryNames.parse(
      File('assets/geo/country_names.txt').readAsStringSync(),
    );
    expect(names.name('US', 'es'), 'Estados Unidos');
    expect(names.name('JP', 'ja'), '日本');
    expect(names.name('JP', 'xx'), 'Japan');
    expect(names.fromIso3('ESP'), 'ES');
    expect(names.fromIso3('D'), 'DE');
  });

  testWidgets('pasaporte español a EE. UU.: ESTA con los datos de la Bóveda', (
    WidgetTester tester,
  ) async {
    // Un pasaporte español de mentira con su MRZ (dígitos de control bien).
    const String top = 'P<ESPPEREZ<GARCIA<<ANA<<<<<<<<<<<<<<<<<<<<<<';
    const String number = 'AB1234567';
    const String birth = '900115';
    final String expiry = '${(DateTime.now().year + 5) % 100}0101';
    final String low =
        '$number${mrzCheckDigit(number)}ESP$birth${mrzCheckDigit(birth)}F'
        '$expiry${mrzCheckDigit(expiry)}<<<<<<<<<<<<<<00';

    final FakeGateway g = FakeGateway();
    final session = newSession()..continueAsGuest();
    final FakeUnlocker unlocker = FakeUnlocker();
    final Vault vault = newVault(unlocker);
    await vault.open('x');
    await vault.add(
      kind: DocKind.passport,
      title: 'Pasaporte',
      mime: 'image/jpeg',
      bytes: Uint8List.fromList(<int>[1]),
      text: <String>['REINO DE ESPAÑA\n$top\n$low'],
    );
    vault.close();
    final MemorySettingsStore store = MemorySettingsStore('es');
    await store.writeData(LocalData.visaPassport, 'MX');
    final List<Uri> opened = <Uri>[];
    tester.view.physicalSize = const Size(1200, 5000);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await pumpApp(
      tester,
      locale: 'es',
      session: session,
      initialLocation: Routes.visa(to: 'US'),
      services: fakeServices(
        session,
        gateway: g,
        vault: vault,
        prefs: store,
        openLink: (Uri u) async {
          opened.add(u);
          return true;
        },
      ),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(seconds: 1)),
    );
    await tester.pumpAndSettle();

    // Con pasaporte mexicano (lo guardado), EE. UU. pide visado.
    expect(find.textContaining('México'), findsOneWidget);
    expect(find.textContaining('Estados Unidos'), findsOneWidget);
    expect(find.text('Necesitas visado de la embajada'), findsOneWidget);

    // Leer el pasaporte de la Bóveda: es español → ESTA, 90 días.
    await tester.tap(find.text('Leer mi pasaporte'));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 300)),
    );
    await tester.pumpAndSettle();
    expect(unlocker.asked, greaterThan(0));
    expect(find.textContaining('España'), findsWidgets);
    expect(find.text('Necesitas el ESTA'), findsOneWidget);
    expect(find.text('Hasta 90 días'), findsOneWidget);
    expect(find.text('PEREZ GARCIA'), findsOneWidget);
    expect(find.text('ANA'), findsOneWidget);
    expect(find.text(number), findsOneWidget);
    expect(store.readData(LocalData.visaPassport), 'ES');

    await tester.tap(find.text('Todo correcto, seguir'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Abrir la web oficial'));
    await tester.pumpAndSettle();
    expect(opened.single.host, 'esta.cbp.dhs.gov');
    vault.close();
  });
}
