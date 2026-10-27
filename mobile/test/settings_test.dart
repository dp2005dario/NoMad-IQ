// Ajustes: descargar mis datos y borrar la cuenta (lo que exige Google Play).
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:eclipta/auth/session.dart';
import 'package:eclipta/core/router.dart';
import 'package:eclipta/core/settings.dart';
import 'package:eclipta/features/family/family.dart';
import 'package:eclipta/features/push/notice_prefs.dart';
import 'package:eclipta/features/push/push_notice.dart';
import 'package:eclipta/features/settings/account_data.dart';
import 'package:eclipta/features/settings/settings_screen.dart';
import 'package:eclipta/features/vault/vault.dart';
import 'package:eclipta/features/vault/vault_store.dart';

import 'helpers.dart';
import 'vault_test.dart' show FakeUnlocker;

class MemorySaver implements DataSaver {
  final Map<String, Uint8List> saved = <String, Uint8List>{};

  @override
  Future<bool> save(String fileName, Uint8List bytes) async {
    saved[fileName] = bytes;
    return true;
  }
}

/// Los servicios de datos: cuentan las veces que se borra cada uno.
Map<String, int> serveMyData(FakeGateway g) {
  final Map<String, int> erased = <String, int>{};
  http.Response erase(http.Request r) {
    erased[r.url.path] = (erased[r.url.path] ?? 0) + 1;
    return http.Response('', 204);
  }

  g.services['/v1/me/data'] = erase;
  g.services['/v1/fares/me'] = erase;
  g.services['/v1/fares/watches'] = (_) => FakeGateway.json(<String, Object?>{
    'watches': <Object?>[
      <String, Object?>{'route_key': 'MAD-NRT:2026-12-01:ECONOMY'},
    ],
  });
  g.services['/v1/expense-groups'] = (_) => FakeGateway.json(<String, Object?>{
    'items': <Object?>[
      <String, Object?>{'group_id': 'g1', 'title': 'Tokio'},
    ],
  });
  g.services['/v1/expense-groups/g1'] = (_) =>
      FakeGateway.json(<String, Object?>{'group_id': 'g1', 'expenses': []});
  return erased;
}

void main() {
  group('datos', () {
    test(
      'la copia junta servidor y móvil, y no lleva los tipos de cambio',
      () async {
        final FakeGateway g = FakeGateway();
        serveMyData(g);
        final SessionController session = await signedInSession(g);
        final MemorySettingsStore prefs = MemorySettingsStore()
          ..groupName = 'Ana'
          ..flyraChat = '[{"me":true,"text":"hola"}]';
        prefs.data[LocalData.fxRates] = '{"EUR":1}';
        prefs.data[LocalData.travelCards] = '{"cards":[]}';
        final services = fakeServices(session, gateway: g, prefs: prefs);
        final Map<String, Object?> data = await collectMyData(
          api: services.api,
          session: session,
          prefs: prefs,
          now: () => DateTime.utc(2026, 10, 23),
        );
        final Map<String, Object?> server =
            data['server']! as Map<String, Object?>;
        expect(
          (server['fare_watches']! as Map<String, Object?>)['watches'],
          hasLength(1),
        );
        // El bote va entero (con sus gastos), no solo el resumen.
        expect(server['expense_groups'], <Object?>[
          <String, Object?>{'group_id': 'g1', 'expenses': <Object?>[]},
        ]);
        // Un servicio caído no rompe la copia: dice "no disponible".
        expect(server['recommendations'], <String, Object?>{
          'unavailable': 'notFound',
        });
        final Map<String, Object?> phone =
            data['this_phone']! as Map<String, Object?>;
        expect(phone['group_name'], 'Ana');
        expect(phone['flyra_chat'], isA<List<Object?>>());
        expect(phone.containsKey('fxRates'), isFalse);
        expect(phone['travelCards'], <String, Object?>{'cards': <Object?>[]});
        expect(
          (data['account']! as Map<String, Object?>)['email'],
          'ana@example.com',
        );
        expect(
          exportFileName(DateTime(2026, 10, 23)),
          'nomadiq-mis-datos-2026-10-23.json',
        );
        expect(
          jsonDecode(utf8.decode(encodeExport(data))),
          isA<Map<String, Object?>>(),
        );
      },
    );

    test(
      'borrar: contraseña mal no toca nada; bien lo borra todo en orden',
      () async {
        final FakeGateway g = FakeGateway();
        final Map<String, int> erased = serveMyData(g);
        final SessionController session = await signedInSession(g);
        final MemorySettingsStore prefs = MemorySettingsStore()
          ..groupName = 'Ana'
          ..stamps = '[]';
        prefs.data[LocalData.fxRates] = '{}';
        final Vault vault = Vault(
          keys: MemoryVaultKeyStore(),
          files: MemoryVaultFiles(),
          unlocker: FakeUnlocker(),
        );
        await vault.open('x');
        await vault.add(
          kind: DocKind.passport,
          title: 'Pasaporte',
          bytes: Uint8List.fromList(<int>[1, 2, 3]),
          mime: 'image/jpeg',
        );
        final services = fakeServices(
          session,
          gateway: g,
          prefs: prefs,
          vault: vault,
        );
        final MemoryFamilyStore family = MemoryFamilyStore();
        await family.save(<FamilyMember>[const FamilyMember(name: 'Leo')]);
        final AccountEraser eraser = AccountEraser(
          session: session,
          api: services.api,
          vault: vault,
          prefs: prefs,
          family: family,
        );

        await expectLater(
          eraser.erase('otra'),
          throwsA(
            isA<EraseFailed>().having(
              (EraseFailed e) => e.step,
              'step',
              EraseStep.password,
            ),
          ),
        );
        expect(erased, isEmpty);
        expect(session.status, SessionStatus.signedIn);

        g.calls.clear();
        await eraser.erase('una contraseña larga');
        expect(erased, <String, int>{'/v1/me/data': 1, '/v1/fares/me': 1});
        // Primero los datos (con pase), la cuenta la última.
        expect(
          g.calls.indexOf('DELETE /v1/me'),
          greaterThan(g.calls.indexOf('DELETE /v1/fares/me')),
        );
        expect(g.accounts, isEmpty);
        expect(session.status, SessionStatus.signedOut);
        expect(vault.isOpen, isFalse);
        expect(prefs.groupName, isNull);
        expect(prefs.stamps, isNull);
        expect(prefs.data.keys, <LocalData>[LocalData.fxRates]);
        expect(family.raw, isNull);
      },
    );

    test('si el servidor falla a mitad, la cuenta sigue viva', () async {
      final FakeGateway g = FakeGateway();
      serveMyData(g);
      g.services['/v1/fares/me'] = (_) => http.Response('', 503);
      final SessionController session = await signedInSession(g);
      final services = fakeServices(session, gateway: g);
      final AccountEraser eraser = AccountEraser(
        session: session,
        api: services.api,
        vault: services.vault,
        prefs: services.prefs,
      );
      await expectLater(
        eraser.erase('una contraseña larga'),
        throwsA(
          isA<EraseFailed>().having(
            (EraseFailed e) => e.step,
            'step',
            EraseStep.serverData,
          ),
        ),
      );
      expect(g.accounts, isNotEmpty);
      expect(session.status, SessionStatus.signedIn);
    });

    test('el ID corto', () {
      expect(
        SettingsScreenIds.short('3f2a9c1e-0000-4000-8000-000000000000'),
        '3F2A9C1E',
      );
    });
  });

  group('pantalla', () {
    Future<(FakeGateway, SessionController, MemorySaver)> open(
      WidgetTester tester,
    ) async {
      final FakeGateway g = FakeGateway();
      serveMyData(g);
      final SessionController session = await signedInSession(g);
      final MemorySaver saver = MemorySaver();
      tester.view.physicalSize = const Size(1200, 2600);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      await pumpApp(
        tester,
        locale: 'es',
        session: session,
        initialLocation: Routes.home,
        services: fakeServices(session, gateway: g),
      );
      await tester.tap(find.byTooltip('Cuenta'));
      await tester.pumpAndSettle();
      expect(find.text('Ajustes'), findsOneWidget);
      return (g, session, saver);
    }

    testWidgets('cambiar la contraseña: bien, mal y floja', (
      WidgetTester tester,
    ) async {
      final (FakeGateway g, _, _) = await open(tester);
      Future<void> change(String current, String next) async {
        await tester.tap(find.text('Cambiar contraseña'));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.widgetWithText(TextField, 'Contraseña actual'),
          current,
        );
        await tester.enterText(
          find.widgetWithText(
            TextField,
            'Contraseña nueva (12 caracteres o más)',
          ),
          next,
        );
        await tester.tap(
          find.widgetWithText(FilledButton, 'Cambiar contraseña'),
        );
        await tester.pumpAndSettle();
      }

      await change('no es esta', 'otra contraseña larga');
      expect(find.text('Esa contraseña no es correcta.'), findsOneWidget);
      expect(g.accounts['ana@example.com'], 'una contraseña larga');

      // El aviso anterior sigue en cola unos segundos.
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      await change('una contraseña larga', 'otra contraseña larga');
      expect(find.textContaining('Contraseña cambiada'), findsOneWidget);
      expect(g.accounts['ana@example.com'], 'otra contraseña larga');
    });

    testWidgets('desde Inicio se abre Ajustes con tu perfil', (
      WidgetTester tester,
    ) async {
      await open(tester);
      expect(find.text('Ana'), findsOneWidget);
      expect(find.text('ana@example.com'), findsOneWidget);
      expect(find.text('ID: U1 · copiar'), findsOneWidget);
      expect(find.text('Borrar mi cuenta y mis datos'), findsOneWidget);
      // Ajustes es una lista larga: la versión está al final.
      await tester.scrollUntilVisible(
        find.textContaining('ECLIPTA 1.0.0'),
        300,
      );
      expect(find.textContaining('ECLIPTA 1.0.0'), findsOneWidget);
    });

    testWidgets(
      'borrar la cuenta pide la contraseña y vuelve a la Bienvenida',
      (WidgetTester tester) async {
        final (FakeGateway g, SessionController session, _) = await open(
          tester,
        );
        await tester.scrollUntilVisible(
          find.text('Borrar mi cuenta y mis datos'),
          300,
        );
        // Al centro de la pantalla, que la barra de abajo no lo tape.
        await Scrollable.ensureVisible(
          tester.element(find.text('Borrar mi cuenta y mis datos')),
          alignment: 0.5,
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Borrar mi cuenta y mis datos'));
        await tester.pumpAndSettle();
        expect(find.text('¿Borrar tu cuenta?'), findsOneWidget);
        await tester.tap(find.text('Sí, borrar mi cuenta'));
        await tester.pumpAndSettle();

        // Contraseña mal: aviso y la cuenta sigue.
        await tester.enterText(find.byType(TextField), 'mala');
        await tester.tap(find.text('Borrar para siempre'));
        await tester.pumpAndSettle();
        expect(find.text('Esa contraseña no es correcta.'), findsOneWidget);
        expect(session.status, SessionStatus.signedIn);

        await tester.tap(find.text('Borrar mi cuenta y mis datos'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Sí, borrar mi cuenta'));
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField), 'una contraseña larga');
        await tester.tap(find.text('Borrar para siempre'));
        await tester.pumpAndSettle();
        expect(session.status, SessionStatus.signedOut);
        expect(g.accounts, isEmpty);
        expect(
          find.text('Tu cuenta se ha borrado. ¡Buen viaje!'),
          findsOneWidget,
        );
      },
    );
  });

  testWidgets('Privacidad: apagar los chollos se guarda; seguridad fija', (
    WidgetTester tester,
  ) async {
    final FakeGateway g = FakeGateway();
    final SessionController session = await signedInSession(g);
    final MemorySettingsStore prefs = MemorySettingsStore();
    tester.view.physicalSize = const Size(1200, 3000);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await pumpApp(
      tester,
      locale: 'es',
      session: session,
      initialLocation: Routes.settings,
      services: fakeServices(session, gateway: g, prefs: prefs),
    );
    await tester.tap(find.text('Privacidad y seguridad'));
    await tester.pumpAndSettle();
    expect(find.text('Este teléfono está protegido'), findsOneWidget);
    expect(find.text('Qué sabemos de ti'), findsOneWidget);
    await tester.tap(find.text('Chollos de vuelos'));
    await tester.pumpAndSettle();
    expect(mutedKinds(prefs), <PushKind>{PushKind.fareAlert});
    final SwitchListTile safety = tester.widget(
      find.widgetWithText(SwitchListTile, 'Avisos de seguridad'),
    );
    expect(safety.value, isTrue);
    expect(safety.onChanged, isNull);
    // Sin Firebase (tests) no hay "Olvidar este teléfono".
    expect(find.text('Olvidar este teléfono'), findsNothing);
  });
}
