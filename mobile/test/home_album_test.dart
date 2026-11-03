// "Mi álbum de cromos" de Inicio: el reparto en páginas de 4 huecos y el
// libro que se abre, pasa página y se cierra.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:eclipta/core/router.dart';
import 'package:eclipta/core/settings.dart';
import 'package:eclipta/features/camera/stamps.dart';
import 'package:eclipta/features/home/home_album.dart';
import 'package:eclipta/features/passport/passport.dart';

import 'helpers.dart';

Stamp stamp(int i) => Stamp(
  qid: 'Q$i',
  name: 'Monumento $i',
  date: DateTime.utc(2026, 10, 1 + i),
);

void main() {
  test('4 huecos por página, "?" en los que faltan y páginas pares', () {
    final List<AlbumPage> pages = albumPagesOf(<PassportPage>[
      PassportPage(
        country: 'PT',
        cities: const <String>['Lisboa'],
        stamps: <Stamp>[for (int i = 0; i < 5; i++) stamp(i)],
      ),
      PassportPage(cities: const <String>[], stamps: <Stamp>[stamp(9)]),
    ], titleOf: (PassportPage p) => p.country ?? 'Otros');
    expect(pages.map((AlbumPage p) => p.title), <String>[
      'PT',
      'PT',
      'Otros',
      '',
    ]);
    expect(pages[1].cards.whereType<Stamp>(), hasLength(1));
    expect(pages[1].cards.where((Stamp? s) => s == null), hasLength(3));
    // Sin cromos: dos páginas vacías (el libro abierto enseña dos).
    expect(
      albumPagesOf(const <PassportPage>[], titleOf: (_) => ''),
      hasLength(2),
    );
  });

  testWidgets('abrir el libro, pasar página y cerrarlo', (
    WidgetTester tester,
  ) async {
    final MemorySettingsStore prefs = MemorySettingsStore();
    await prefs.writeStamps(
      jsonEncode(<Object?>[for (int i = 0; i < 9; i++) stamp(i).toJson()]),
    );
    final session = newSession()..continueAsGuest();
    tester.view.physicalSize = const Size(1200, 3000);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await pumpApp(
      tester,
      locale: 'es',
      session: session,
      initialLocation: Routes.home,
      services: fakeServices(session, prefs: prefs),
    );
    await tester.pumpAndSettle();
    final Finder hint = find.text('Toca el libro para abrirlo · 9 cromos');
    await tester.scrollUntilVisible(
      hint,
      300,
      scrollable: find.byType(Scrollable).first,
    );
    // Los aeropuertos se cargan de verdad (assets) para saber el país.
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(seconds: 2)),
    );
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('CROMOS'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('CROMOS'));
    await tester.pumpAndSettle();
    // 9 sellos sin sitio → "Otros lugares": 3 páginas (+1 vacía) = 4.
    expect(find.text('Páginas 1–2 de 4'), findsOneWidget);
    expect(find.text('Desliza para pasar página'), findsOneWidget);
    expect(find.text('Monumento 8'), findsOneWidget); // el más nuevo, primero

    await tester.ensureVisible(find.byTooltip('Página siguiente'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Página siguiente'));
    await tester.pumpAndSettle();
    expect(find.text('Páginas 3–4 de 4'), findsOneWidget);
    expect(find.text('Desliza para pasar página'), findsNothing);
    expect(find.text('Monumento 0'), findsOneWidget);

    await tester.ensureVisible(find.text('Cerrar libro'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cerrar libro'));
    await tester.pumpAndSettle();
    expect(hint, findsOneWidget);
  });
}
