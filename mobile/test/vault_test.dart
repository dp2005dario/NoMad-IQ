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
import 'package:eclipta/features/vault/vault.dart';
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

  group('pantallas', () {
    testWidgets('abrir con huella, escanear el pasaporte y verlo', (
      WidgetTester tester,
    ) async {
      final FakeUnlocker u = FakeUnlocker();
      final Vault v = newVault(u);
      final FakeDocSource source = FakeDocSource(
        PickedDoc(bytes: bytes('foto'), mime: 'image/jpeg'),
      );
      final session = await signedInSession(FakeGateway());
      tester.view.physicalSize = const Size(1200, 4000);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      await pumpApp(
        tester,
        locale: 'es',
        session: session,
        initialLocation: Routes.vault,
        services: fakeServices(
          session,
          vault: v,
          docSource: source,
          docReader: FakeReader(<String>['P<ESP']),
        ),
      );
      expect(find.text('Toca para abrir con tu huella'), findsOneWidget);
      await tester.tap(find.byIcon(Icons.fingerprint_rounded));
      await tester.pumpAndSettle();
      expect(u.asked, 1);
      expect(find.textContaining('Aún no hay nada'), findsOneWidget);
      await tester.tap(find.text('Escanear documento'));
      await tester.pumpAndSettle();
      expect(source.asked, <DocOrigin>[DocOrigin.camera]);
      await tester.enterText(
        find
            .descendant(
              of: find.byType(AlertDialog),
              matching: find.byType(TextField),
            )
            .first,
        'Darío Pérez',
      );
      await tester.pump();
      await tester.tap(find.text('Guardar'));
      await tester.pumpAndSettle();
      expect(v.docs.single.kind, DocKind.passport);
      expect(find.text('PASAPORTE'), findsOneWidget);
      expect(find.text('Darío Pérez'), findsOneWidget);
      expect(find.textContaining('número oculto'), findsOneWidget);
      await tester.tap(find.text('Darío Pérez'));
      await tester.pumpAndSettle();
      expect(find.byType(Image), findsOneWidget);
      await tester.tap(find.byTooltip('Borrar'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Borrar'));
      await tester.pumpAndSettle();
      expect(v.docs, isEmpty);
      await tester.tap(find.text('Cerrar la Bóveda'));
      await tester.pumpAndSettle();
      expect(v.isOpen, isFalse);
      expect(find.text('Toca para abrir con tu huella'), findsOneWidget);
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
