// "Mi pasaporte" de Inicio: leer la MRZ del DNI (formato TD1), escanear
// pasaporte y DNI con cámara y lector falsos, y que solo se guarden las 3
// últimas cifras de los números.
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:eclipta/core/router.dart';
import 'package:eclipta/core/settings.dart';
import 'package:eclipta/features/home/home_screen.dart';
import 'package:eclipta/features/home/my_passport.dart';
import 'package:eclipta/features/vault/doc_source.dart';
import 'package:eclipta/features/visa/mrz.dart';

import 'camera_test.dart' show FakeCamera;
import 'helpers.dart';
import 'money_test.dart' as m;

/// Pone el dígito de control al final de [s].
String withCheck(String s) => '$s${mrzCheckDigit(s)}';

/// Un pasaporte español de prueba (TD3, 2 líneas de 44).
List<String> passportMrz() {
  final String l2 =
      '${withCheck('XDE482916')}ESP${withCheck('960314')}F${withCheck('310902')}'
          .padRight(44, '<');
  return <String>['P<ESPEJEMPLO<<LUNA'.padRight(44, '<'), l2];
}

/// Un DNI español de prueba (TD1, 3 líneas de 30).
List<String> idMrz() {
  final String l1 = 'IDESP${withCheck('BAA000589')}12345678Z'.padRight(30, '<');
  final String l2 = '${withCheck('960314')}F${withCheck('320610')}ESP'.padRight(
    30,
    '<',
  );
  return <String>[l1, l2, 'EJEMPLO<DEMO<<LUNA'.padRight(30, '<')];
}

class FakeCam implements DocSource {
  int shots = 0;

  @override
  Future<PickedDoc?> pick(DocOrigin origin) async {
    shots++;
    return PickedDoc(
      bytes: Uint8List.fromList(<int>[1, 2, 3]),
      mime: 'image/jpeg',
    );
  }
}

/// Devuelve, foto a foto, el texto que "lee" el móvil.
class FakeReader implements DocTextReader {
  FakeReader(this.shots);

  final List<List<String>> shots;

  @override
  Future<List<String>> read(PickedDoc doc) async =>
      shots.isEmpty ? const <String>[] : <String>[shots.removeAt(0).join('\n')];

  @override
  Future<int> pages(PickedDoc doc) async => 1;

  @override
  Future<List<Uint8List>> render(Uint8List pdf) async => const <Uint8List>[];
}

void main() {
  test('el DNI se lee de sus 3 líneas y el número sale entero', () {
    final MrzData? d = parseIdMrz(<String>[idMrz().join('\n')]);
    expect(d, isNotNull);
    expect(d!.surname, 'EJEMPLO DEMO');
    expect(d.givenNames, 'LUNA');
    expect(d.number, '12345678Z');
    expect(d.nationality, 'ESP');
    expect(d.birth, DateTime(1996, 3, 14));
    expect(d.expiry, DateTime(2032, 6, 10));
  });

  test('si un dígito de control no cuadra, no se rellena nada', () {
    final List<String> bad = idMrz();
    bad[1] = bad[1].replaceFirst('960314', '960315');
    expect(parseIdMrz(<String>[bad.join('\n')]), isNull);
  });

  test('se lee aunque el móvil parta las líneas en trozos y meta ruido', () {
    final List<String> p = passportMrz();
    // El OCR de verdad: la línea 1 en dos trozos, la 2 cortada a la mitad,
    // espacios y texto del pasaporte alrededor.
    final String messy = <String>[
      'REINO DE ESPAÑA',
      'PASAPORTE',
      p[0].substring(0, 22),
      p[0].substring(22),
      '${p[1].substring(0, 15)} ${p[1].substring(15, 20)}',
      p[1].substring(20),
      'Firma del titular',
    ].join('\n');
    final MrzData? d = parseMrz(<String>[messy]);
    expect(d, isNotNull);
    expect(d!.surname, 'EJEMPLO');
    expect(d.givenNames, 'LUNA');
    expect(d.birth, DateTime(1996, 3, 14));

    final List<String> id = idMrz();
    final String idMessy = <String>[
      'Domicilio CALLE FALSA 1',
      id[0].substring(0, 14),
      id[0].substring(14),
      id[1],
      id[2],
    ].join('\n');
    final MrzData? i = parseIdMrz(<String>[idMessy]);
    expect(i, isNotNull);
    expect(i!.number, '12345678Z');
    expect(i.givenNames, 'LUNA');
  });

  test('del número solo quedan las 3 últimas cifras', () {
    expect(maskNumber('XDE482916'), '••••••916');
    expect(maskNumber('12'), '12');
  });

  testWidgets('escanear pasaporte y DNI rellena la tarjeta', (
    WidgetTester tester,
  ) async {
    final MemorySettingsStore prefs = MemorySettingsStore();
    final FakeCam cam = FakeCam();
    // La primera foto del pasaporte sale mal; la segunda, bien.
    final FakeReader reader = FakeReader(<List<String>>[
      <String>['borroso'],
      passportMrz(),
      idMrz(),
    ]);
    final m.PageSpy spy = m.PageSpy();
    final session = newSession()..continueAsGuest();
    tester.view.physicalSize = const Size(1200, 3000);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await pumpApp(
      tester,
      locale: 'es',
      session: session,
      initialLocation: Routes.home,
      services: fakeServices(
        session,
        prefs: prefs,
        docSource: cam,
        docReader: reader,
        webScene: spy.build,
      ),
    );
    await spy.wait(tester, () => spy.pages.isNotEmpty);
    Map<String, Object?> pass() =>
        spy.data(HomeScreen.lastBridge!)['pass']! as Map<String, Object?>;
    expect(pass()['done'], isFalse);
    expect(pass()['cta'], 'Toca para escanear pasaporte y DNI');
    // Tocar el pasaporte de la página abre la cámara.
    spy.send!('scan');
    await tester.pumpAndSettle();
    expect(find.text('Foto 1 de 2 · Pasaporte'), findsOneWidget);

    // Foto mala: lo dice y no avanza.
    await tester.tap(find.bySemanticsLabel('Hacer foto'));
    await tester.pumpAndSettle();
    expect(find.textContaining('No he podido leer'), findsOneWidget);
    expect(find.text('Foto 1 de 2 · Pasaporte'), findsOneWidget);

    // Foto buena: enseña lo leído y pasa al DNI.
    await tester.tap(find.bySemanticsLabel('Hacer foto'));
    await tester.pump();
    await tester.pump();
    expect(find.text('Pasaporte leído'), findsOneWidget);
    expect(find.text('••••••916'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 1400));
    await tester.pumpAndSettle();
    expect(find.text('Foto 2 de 2 · DNI'), findsOneWidget);

    await tester.tap(find.bySemanticsLabel('Hacer foto'));
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1400));
    await tester.pumpAndSettle();
    expect(find.text('Documentos añadidos'), findsOneWidget);
    expect(find.text('DNI · DNI'), findsOneWidget);
    expect(find.text('España'), findsWidgets);
    await tester.ensureVisible(find.text('Listo'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Listo'));
    await tester.pumpAndSettle();

    // La tarjeta de la página, rellena. El número entero no está guardado
    // en ningún sitio.
    await spy.wait(tester, () => pass()['done'] == true);
    expect(pass()['cta'], 'Pasaporte y DNI añadidos');
    expect(pass()['ape'], 'EJEMPLO');
    expect(pass()['nom'], 'LUNA');
    expect(pass()['num'], '••••••916');
    expect(pass()['dni'], '••••••78Z');
    expect(pass()['exp'], '02 SEPT 2031');
    expect(pass()['val'], '10 JUN 2032');
    final String saved = prefs.readData(LocalData.myDocs)!;
    expect(saved, isNot(contains('XDE482916')));
    expect(saved, isNot(contains('12345678Z')));
    expect(cam.shots, 3);
  });

  testWidgets('el escáner enseña la cámara en el marco y hace la foto ahí', (
    WidgetTester tester,
  ) async {
    final FakeCam system = FakeCam();
    final FakeCamera live = FakeCamera();
    final session = newSession()..continueAsGuest();
    final m.PageSpy spy = m.PageSpy();
    await pumpApp(
      tester,
      locale: 'es',
      session: session,
      initialLocation: Routes.home,
      services: fakeServices(
        session,
        docSource: system,
        docReader: FakeReader(<List<String>>[passportMrz()]),
        newDocCamera: () => live,
        webScene: spy.build,
      ),
    );
    await spy.wait(tester, () => spy.pages.isNotEmpty);
    spy.send!('scan');
    await tester.pumpAndSettle();
    // Lo que ve la cámara, dentro del marco (y no un fondo vacío).
    expect(
      find.byWidgetPredicate(
        (Widget w) => w is ColoredBox && w.color == Colors.blueGrey,
      ),
      findsOneWidget,
    );
    await tester.tap(find.bySemanticsLabel('Hacer foto'));
    await tester.pump();
    await tester.pump();
    expect(find.text('Pasaporte leído'), findsOneWidget);
    expect(live.photos, 1);
    expect(system.shots, 0);
    await tester.pump(const Duration(milliseconds: 1400));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Cerrar'));
    await tester.pumpAndSettle();
    expect(live.disposed, isTrue);
  });
}
