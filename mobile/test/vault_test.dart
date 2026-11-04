// Tests de la Bóveda: el cifrado, abrir y cerrar con "huella" falsa,
// guardar documentos, la pantalla y preguntar a la póliza del seguro.
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:eclipta/core/router.dart';
import 'package:eclipta/features/money/money_screen.dart';
import 'package:eclipta/features/vault/doc_source.dart';
import 'package:eclipta/features/vault/policy_search.dart';
import 'package:eclipta/features/route/web_scene.dart';
import 'package:eclipta/features/vault/vault.dart';
import 'package:eclipta/features/vault/vault_fields.dart';
import 'package:eclipta/features/vault/vault_page.dart';
import 'package:eclipta/features/vault/vault_store.dart';

import 'helpers.dart';
import 'money_test.dart' show pumpMoney;

/// Una "huella" que dice lo que el test quiera.
class FakeUnlocker implements Unlocker {
  UnlockResult answer = UnlockResult.ok;
  int asked = 0;

  @override
  Future<UnlockResult> unlock(String reason) async {
    asked++;
    return answer;
  }
}

/// La cámara "hace" esta foto.
class FakeDocSource implements DocSource {
  FakeDocSource(this.doc);

  final PickedDoc? doc;
  final List<DocOrigin> asked = <DocOrigin>[];

  @override
  Future<PickedDoc?> pick(DocOrigin origin) async {
    asked.add(origin);
    return doc;
  }
}

/// El "OCR" devuelve un texto fijo.
class FakeReader implements DocTextReader {
  FakeReader(this.text);

  final List<String> text;

  @override
  Future<List<String>> read(PickedDoc doc) async => text;

  @override
  Future<int> pages(PickedDoc doc) async => text.length;

  @override
  Future<List<Uint8List>> render(Uint8List pdf) async => const <Uint8List>[];
}

/// Una póliza de ejemplo (3 páginas) como la de la maqueta.
const List<String> policy = <String>[
  'SEGURO VIAJE PLUS. Condiciones generales. Asistencia 24 horas.',
  'Artículo 6. Asistencia médica. Gastos médicos, quirúrgicos y de '
      'hospitalización sin límite en Asia.\n\nArtículo 14. Equipajes. Se '
      'indemnizará hasta 1.200 € por la pérdida definitiva del equipaje '
      'facturado.',
  'Artículo 22. Exclusiones. Quedan excluidos los deportes de invierno, '
      'como el esquí o el snowboard, salvo contratación expresa.',
];

Uint8List bytes(String s) => Uint8List.fromList(utf8.encode(s));

Vault newVault(
  FakeUnlocker u, {
  MemoryVaultFiles? files,
  MemoryVaultKeyStore? keys,
  Duration autoLock = const Duration(minutes: 2),
}) => Vault(
  keys: keys ?? MemoryVaultKeyStore(),
  files: files ?? MemoryVaultFiles(),
  unlocker: u,
  autoLock: autoLock,
);

void main() {
  group('cifrado', () {
    test('se abre con la misma llave y el mismo nombre', () async {
      final VaultCipher c = VaultCipher(await VaultCipher.newKey());
      final Uint8List sealed = await c.seal('a.bin', bytes('pasaporte'));
      expect(utf8.decode(await c.open('a.bin', sealed)), 'pasaporte');
      // Cambiado de nombre (de sitio): se rechaza.
      expect(() => c.open('b.bin', sealed), throwsA(isA<VaultCorrupt>()));
      // Tocado un byte: se rechaza.
      final Uint8List bad = Uint8List.fromList(sealed)..[20] ^= 1;
      expect(() => c.open('a.bin', bad), throwsA(isA<VaultCorrupt>()));
      // Con otra llave: se rechaza.
      final VaultCipher other = VaultCipher(await VaultCipher.newKey());
      expect(() => other.open('a.bin', sealed), throwsA(isA<VaultCorrupt>()));
    });
  });

  group('bóveda', () {
    test('guardar, cerrar, volver a abrir y borrar', () async {
      final FakeUnlocker u = FakeUnlocker();
      final MemoryVaultFiles files = MemoryVaultFiles();
      final MemoryVaultKeyStore keys = MemoryVaultKeyStore();
      final Vault v = newVault(u, files: files, keys: keys);
      expect(v.isOpen, isFalse);
      expect(await v.open('x'), UnlockResult.ok);
      final VaultDoc doc = await v.add(
        kind: DocKind.insurance,
        title: 'Seguro Viaje Plus',
        mime: 'application/pdf',
        bytes: bytes('%PDF secreto'),
        text: policy,
        pages: 3,
      );
      // Nada en claro en los ficheros.
      for (final Uint8List f in files.files.values) {
        expect(
          utf8.decode(f, allowMalformed: true),
          isNot(contains('secreto')),
        );
        expect(utf8.decode(f, allowMalformed: true), isNot(contains('Seguro')));
      }
      v.close();
      expect(v.docs, isEmpty);
      expect(() => v.content(doc.id), throwsStateError);

      final Vault again = newVault(u, files: files, keys: keys);
      await again.open('x');
      expect(again.docs.single.title, 'Seguro Viaje Plus');
      expect(utf8.decode(await again.content(doc.id)), '%PDF secreto');
      expect(await again.text(doc.id), policy);
      await again.delete(doc.id);
      expect(again.docs, isEmpty);
      expect(files.files.keys, <String>['index']);
    });

    test('sin huella no se abre; y se cierra sola', () async {
      final FakeUnlocker u = FakeUnlocker()..answer = UnlockResult.cancelled;
      final Vault v = newVault(u, autoLock: const Duration(milliseconds: 20));
      expect(await v.open('x'), UnlockResult.cancelled);
      expect(v.isOpen, isFalse);
      u.answer = UnlockResult.ok;
      await v.open('x');
      expect(v.isOpen, isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(v.isOpen, isFalse);
    });

    test('olvidar borra todo y la llave', () async {
      final FakeUnlocker u = FakeUnlocker();
      final MemoryVaultFiles files = MemoryVaultFiles();
      final MemoryVaultKeyStore keys = MemoryVaultKeyStore();
      final Vault v = newVault(u, files: files, keys: keys);
      await v.open('x');
      await v.add(
        kind: DocKind.other,
        title: 'x',
        mime: 'image/jpeg',
        bytes: bytes('x'),
      );
      await v.forget();
      expect(files.files, isEmpty);
      expect(keys.key, isNull);
    });

    test('rechaza documentos vacíos o enormes', () async {
      final Vault v = newVault(FakeUnlocker());
      await v.open('x');
      expect(
        () => v.add(
          kind: DocKind.other,
          title: 'x',
          mime: 'image/jpeg',
          bytes: Uint8List(0),
        ),
        throwsA(isA<DocTooBig>()),
      );
    });
  });

  group('póliza', () {
    test('la maleta perdida: página 2 con el importe', () {
      final List<PolicyHit> hits = searchPolicy(
        policy,
        topicWords[PolicyTopic.luggage]!,
      );
      expect(hits.first.page, 2);
      expect(hits.first.text, contains('1.200 €'));
      expect(hits.first.exclusion, isFalse);
    });

    test('el esquí sale como exclusión', () {
      final List<PolicyHit> hits = searchPolicy(
        policy,
        topicWords[PolicyTopic.sports]!,
      );
      expect(hits.first.page, 3);
      expect(hits.first.exclusion, isTrue);
    });

    test('pregunta libre', () {
      expect(questionWords('¿Me cubre la hospitalización?'), <String>[
        'hospit',
      ]);
      final List<PolicyHit> hits = searchPolicy(
        policy,
        questionWords('¿hospitalización?'),
      );
      expect(hits.single.page, 2);
      expect(searchPolicy(policy, questionWords('¿mascotas?')), isEmpty);
    });
  });

  group('datos de las tarjetas', () {
    test('pasaporte por la zona de lectura automática', () {
      expect(
        readFields(1, <String>[
          'PASAPORTE\nP<ESPPEREZ<GARCIA<<DARIO<<<<<<<<<<<<<<<<<<<<<\n'
              'PAA1234567ESP9001014M3003125<<<<<<<<<<<<<<04',
        ]),
        <String>['DARIO PEREZ GARCIA', 'PAA123456', '12/03/2030'],
      );
    });

    test('tarjeta de embarque, seguro y hotel', () {
      expect(
        readFields(2, <String>['IBERIA  Flight IB 6800\nMAD → NRT\nSeat 23A']),
        <String>['IB 6800', 'MAD → NRT', '23A'],
      );
      expect(
        readFields(3, <String>[
          'SEGURO VIAJE PLUS\nNº de póliza: 4471-2026-88\n'
              'Válido hasta 30/04/2027\nAsistencia 24 h: +34 910 000 000',
        ]),
        <String>['4471-2026-88', '30/04/2027', '+34 910 000 000'],
      );
      expect(
        readFields(6, <String>[
          'Hotel: Gracery Shinjuku\nEntrada 03/03/2027 Salida 10/03/2027\n'
              'Confirmación: 58213377',
        ]),
        <String>['Gracery Shinjuku', '03/03/2027 – 10/03/2027', '58213377'],
      );
    });

    test('sin datos no se inventa nada', () {
      expect(readFields(5, <String>['hola']), <String>['', '', '']);
      expect(readFields(8, <String>[]), <String>['', '', '']);
    });

    test('la página: cerrada no enseña nada; abierta, cada tarjeta', () {
      final VaultDoc photo = VaultDoc(
        id: 'a' * 32,
        kind: DocKind.passport,
        title: 'Pasaporte',
        mime: 'image/jpeg',
        added: DateTime(2026),
        slot: 1,
        fields: const <String>['Darío', 'PAA123456', '12/03/2030'],
      );
      final VaultDoc data = VaultDoc(
        id: 'b' * 32,
        kind: DocKind.other,
        title: 'eSIM',
        mime: dataMime,
        added: DateTime(2026),
        slot: 13,
        fields: const <String>['10 GB', 'Japón'],
      );
      final Map<String, Object?> locked = vaultPageData(
        phase: VaultPhase.locked,
        docs: <VaultDoc>[photo],
      );
      expect(locked['slots'], isEmpty);
      final Map<String, Object?> open = vaultPageData(
        phase: VaultPhase.open,
        docs: <VaultDoc>[photo, data],
        thumbs: <String, String>{photo.id: 'data:image/png;base64,AA'},
      );
      final Map<String, Object?> slots = open['slots']! as Map<String, Object?>;
      expect(slots['1'], containsPair('g', true));
      expect(slots['13'], containsPair('f', true));
      expect((slots['13']! as Map<String, Object?>)['v'], <String>[
        '10 GB',
        'Japón',
        '',
      ]);
      final String html = vaultPageWith(
        'x$vaultMarker;',
        vaultPageData(phase: VaultPhase.open, found: <String>['</script>']),
      );
      expect(html, isNot(contains('</script>')));
      expect(unpackFields('WyJFRS4gVVUuIiwiIiwiQTEiXQ'), <String>[
        'EE. UU.',
        '',
        'A1',
      ]);
      expect(unpackFields('%%%'), isNull);
      expect(
        webSceneMessage.hasMatch('save:5:WyJFRS4gVVUuIiwiIiwiQTEiXQ'),
        isTrue,
      );
      expect(webSceneMessage.hasMatch('save:5:<script>'), isFalse);
    });
  });

  group('pantallas', () {
    testWidgets('huella, foto del pasaporte, PDF del seguro y a mano', (
      WidgetTester tester,
    ) async {
      final FakeUnlocker u = FakeUnlocker();
      final Vault v = newVault(u);
      final FakeDocSource source = FakeDocSource(
        PickedDoc(bytes: bytes('foto'), mime: 'image/jpeg'),
      );
      final List<String> pages = <String>[];
      void Function(String)? send;
      final session = await signedInSession(FakeGateway());
      await pumpApp(
        tester,
        locale: 'es',
        session: session,
        initialLocation: Routes.vault,
        services: fakeServices(
          session,
          vault: v,
          docSource: source,
          docReader: FakeReader(<String>[
            'P<ESPPEREZ<<DARIO<<<<<<<<<<<<<<<<<<<<<<<<<<<<<\n'
                'PAA1234567ESP9001014M3003125<<<<<<<<<<<<<<04',
          ]),
          webScene: (String html, void Function(String) onMessage) {
            pages.add(html);
            send = onMessage;
            return const SizedBox.expand();
          },
        ),
      );
      Future<void> wait(bool Function() done) async {
        for (int i = 0; i < 50 && !done(); i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)),
          );
          await tester.pump(const Duration(milliseconds: 20));
        }
        expect(done(), isTrue);
      }

      await wait(() => pages.isNotEmpty);
      expect(vaultData(pages.last)['phase'], 'locked');
      expect(pages.last, isNot(contains('ejemplo')));

      send!('unlock');
      await wait(() => vaultData(pages.last)['phase'] == 'opening');
      expect(u.asked, 1);

      // Foto con la cámara en la tarjeta 1: se leen sus datos y se guarda.
      send!('cam:1');
      await wait(() => v.docs.isNotEmpty);
      await wait(() => vaultData(pages.last)['msg'] != '');
      expect(source.asked, <DocOrigin>[DocOrigin.camera]);
      expect(v.docs.single.slot, 1);
      expect(v.docs.single.kind, DocKind.passport);
      expect(v.docs.single.fields, <String>[
        'DARIO PEREZ',
        'PAA123456',
        '12/03/2030',
      ]);
      final Map<String, Object?> slot1 =
          (vaultData(pages.last)['slots']! as Map<String, Object?>)['1']!
              as Map<String, Object?>;
      expect(slot1['v'], v.docs.single.fields);

      // A mano en la tarjeta 13 (eSIM).
      final int before = pages.length;
      send!('save:13:WyIxMCBHQiIsIkphcMOzbiIsIiJd');
      await wait(() => v.docs.length == 2 && pages.length > before);
      expect(v.docs.last.isData, isTrue);
      expect(v.docs.last.fields, <String>['10 GB', 'Japón', '']);
      expect(v.docs.last.title, 'eSIM');
      // Abrirla otra vez enseña su formulario.
      send!('view:13');
      await wait(() => vaultData(pages.last)['scan'] == 'form');
      expect(vaultData(pages.last)['sd'], 13);

      send!('lock');
      await wait(() => vaultData(pages.last)['phase'] == 'locked');
      expect(v.isOpen, isFalse);
      expect(vaultData(pages.last)['slots'], isEmpty);
    });

    testWidgets('PDF: leer, enseñar lo encontrado y guardar', (
      WidgetTester tester,
    ) async {
      final FakeUnlocker u = FakeUnlocker();
      final Vault v = newVault(u);
      final List<String> pages = <String>[];
      void Function(String)? send;
      final session = await signedInSession(FakeGateway());
      await pumpApp(
        tester,
        locale: 'es',
        session: session,
        initialLocation: Routes.vault,
        services: fakeServices(
          session,
          vault: v,
          docSource: FakeDocSource(
            PickedDoc(
              bytes: bytes('%PDF'),
              mime: 'application/pdf',
              name: 'poliza.pdf',
            ),
          ),
          docReader: FakeReader(<String>[
            'Nº de póliza: 4471-2026-88\nVálido hasta 30/04/2027',
          ]),
          webScene: (String html, void Function(String) onMessage) {
            pages.add(html);
            send = onMessage;
            return const SizedBox.expand();
          },
        ),
      );
      Future<void> wait(bool Function() done) async {
        for (int i = 0; i < 100 && !done(); i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)),
          );
          await tester.pump(const Duration(milliseconds: 20));
        }
        expect(done(), isTrue);
      }

      await wait(() => pages.isNotEmpty);
      send!('unlock');
      await wait(() => v.isOpen);
      send!('pdf:3');
      await wait(() => vaultData(pages.last)['scan'] == 'pdfok');
      final Map<String, Object?> d = vaultData(pages.last);
      expect(d['file'], 'poliza.pdf');
      expect(d['found'], <String>['4471-2026-88', '30/04/2027', '']);
      expect(v.docs, isEmpty); // aún no: falta "Guardar en la tarjeta"
      // "Guardar" con lo que confirmaste (aquí, con el teléfono añadido).
      send!('save:3:WyI0NDcxLTIwMjYtODgiLCIzMC8wNC8yMDI3IiwiOTEwMDAwMDAwIl0');
      await wait(() => v.docs.isNotEmpty);
      expect(v.docs.single.isPdf, isTrue);
      expect(v.docs.single.kind, DocKind.insurance);
      expect(v.docs.single.fields.last, '910000000');
      expect(await v.text(v.docs.single.id), hasLength(1));
      v.close();
    });

    testWidgets('Seguro: abrir la Bóveda y preguntar por la maleta', (
      WidgetTester tester,
    ) async {
      final FakeUnlocker u = FakeUnlocker();
      final Vault v = newVault(u);
      await v.open('x');
      await v.add(
        kind: DocKind.insurance,
        title: 'Seguro Viaje Plus',
        mime: 'application/pdf',
        bytes: bytes('%PDF'),
        text: policy,
        pages: 3,
      );
      v.close();
      await pumpMoney(
        tester,
        vault: v,
        initialLocation: Routes.money(tab: MoneyTab.abroad),
      );
      await tester.tap(find.text('Seguro'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Abrir la Bóveda'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Seguro Viaje Plus'));
      await tester.pumpAndSettle();
      expect(find.textContaining('3 páginas'), findsOneWidget);
      await tester.tap(find.text('¿Cubre la maleta perdida?'));
      await tester.pumpAndSettle();
      expect(find.text('Página 2'), findsOneWidget);
      expect(find.textContaining('1.200 €'), findsOneWidget);
      await tester.tap(find.text('¿Esquí y deportes?'));
      await tester.pumpAndSettle();
      expect(find.text('Parece una exclusión'), findsOneWidget);
      v.close();
    });
  });
}

/// Los datos que la app metió en la página.
Map<String, Object?> vaultData(String html) {
  const String start = 'window.ECL=';
  final int a = html.indexOf(start) + start.length;
  return jsonDecode(html.substring(a, html.indexOf(';</script>', a)))
      as Map<String, Object?>;
}
