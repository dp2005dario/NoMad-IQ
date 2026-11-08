// "Mi álbum de cromos" de Inicio: el reparto en páginas de 4 huecos y el
// libro que recibe la página (con tus cromos y tus amigos).
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:eclipta/core/router.dart';
import 'package:eclipta/core/settings.dart';
import 'package:eclipta/features/camera/stamps.dart';
import 'package:eclipta/features/home/home_album.dart';
import 'package:eclipta/features/home/home_page.dart';
import 'package:eclipta/features/home/home_screen.dart';
import 'package:eclipta/features/passport/passport.dart';

import 'helpers.dart';
import 'money_test.dart' as m;

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

  test('la página recibe cada hueco con su color', () {
    final List<AlbumPage> pages = albumPagesOf(<PassportPage>[
      PassportPage(
        country: 'PT',
        cities: const <String>['Lisboa'],
        stamps: <Stamp>[stamp(1)],
      ),
    ], titleOf: (PassportPage p) => p.country ?? '');
    final List<Map<String, Object?>> json = albumJson(pages);
    expect(json.first['t'], 'PT');
    final List<Object?> cards = json.first['c']! as List<Object?>;
    expect(cards.first, <String, Object?>{'n': 'Monumento 1', 'cl': 'm'});
    expect(cards.skip(1), everyElement(isNull));
  });

  testWidgets('tus cromos llegan al libro de la página', (
    WidgetTester tester,
  ) async {
    final MemorySettingsStore prefs = MemorySettingsStore();
    await prefs.writeStamps(
      jsonEncode(<Object?>[for (int i = 0; i < 9; i++) stamp(i).toJson()]),
    );
    final m.PageSpy spy = m.PageSpy();
    final session = newSession()..continueAsGuest();
    await pumpApp(
      tester,
      locale: 'es',
      session: session,
      initialLocation: Routes.home,
      services: fakeServices(session, prefs: prefs, webScene: spy.build),
    );
    await spy.wait(tester, () => spy.pages.isNotEmpty);
    // Los aeropuertos se cargan de verdad (assets) para saber el país.
    await spy.wait(tester, () {
      final Object? a = spy.data(HomeScreen.lastBridge!)['album'];
      return a is Map && (a['pages']! as List<Object?>).isNotEmpty;
    });
    final Map<String, Object?> album =
        spy.data(HomeScreen.lastBridge!)['album']! as Map<String, Object?>;
    // 9 sellos sin sitio → "Otros lugares": 3 páginas (+1 vacía) = 4.
    expect(album['pages'], hasLength(4));
    expect(album['tap'], 'Toca el libro para abrirlo · 9 cromos');
    final List<Object?> first =
        ((album['pages']! as List<Object?>).first!
                as Map<String, Object?>)['c']!
            as List<Object?>;
    expect((first.first! as Map<String, Object?>)['n'], 'Monumento 8');
  });

  testWidgets('con cuenta: las caras de los amigos con cromos que te faltan', (
    WidgetTester tester,
  ) async {
    final FakeGateway g = FakeGateway();
    g.services['/v1/leagues'] = (http.Request r) =>
        FakeGateway.json(<String, Object?>{
          'items': <Object?>[],
          'friends_with_missing': <String>['Noelia', 'Óscar'],
        });
    final m.PageSpy spy = m.PageSpy();
    final session = await signedInSession(g);
    await pumpApp(
      tester,
      locale: 'es',
      session: session,
      initialLocation: Routes.home,
      services: fakeServices(session, gateway: g, webScene: spy.build),
    );
    await spy.wait(tester, () => HomeScreen.lastBridge!.sent.isNotEmpty);
    final Map<String, Object?> album =
        spy.data(HomeScreen.lastBridge!)['album']! as Map<String, Object?>;
    expect(album['friends'], '2 amigos tienen cromos que te faltan');
    // Sin fotos en el servidor: la inicial de cada uno.
    expect(album['faces'], <String>['N', 'Ó']);
    // El botón de los amigos abre los cromos.
    spy.send!('cards');
    await tester.pumpAndSettle();
    expect(find.byType(HomeScreen), findsNothing);
  });
}
