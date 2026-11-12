// Inicio: la maqueta dentro de un WebView. Aquí se prueba lo que la app
// hace con lo que manda la página: hablar a Flyra, los cuadrados del
// carrusel, el SOS (WhatsApp, SMS, llamar) y los contactos.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:eclipta/core/router.dart';
import 'package:eclipta/core/settings.dart';
import 'package:eclipta/features/assistant/interpreter.dart';
import 'package:eclipta/features/flights/explore_screen.dart';
import 'package:eclipta/features/home/home_screen.dart';
import 'package:eclipta/features/home/home_page.dart';
import 'package:eclipta/features/map/geo.dart';
import 'package:eclipta/features/sos/sos_store.dart';

import 'helpers.dart';
import 'money_test.dart' as m;

/// Un micro de mentira que "oye" una frase.
class HeardMic implements SpeechInput {
  final List<String> langs = <String>[];

  @override
  Future<String?> listen(String lang) async {
    langs.add(lang);
    return '¿Qué visito hoy?';
  }

  @override
  Future<void> stop() async {}
}

void main() {
  test('datos para la página', () {
    expect(rarityClass(null), 'm');
    expect(rarityClass(80), 'v');
    expect(rarityClass(1200), 'c');
    expect(
      coordsText(const GeoPoint(41.14961, -8.61099)),
      '41.14961 N, 8.61099 O',
    );
    expect(
      mrzLines('ESP', 'GARCIA LOPEZ', 'ANA').single,
      startsWith('P<ESPGARCIA<LOPEZ<<ANA<<<'),
    );
    final Uri wa = whatsappUri(
      const SosContact(name: 'Ana', phone: '+34 600 11 22 33'),
      '¡Ayuda!',
    );
    expect(wa.host, 'wa.me');
    expect(wa.path, '/34600112233');
    expect(wa.queryParameters['text'], '¡Ayuda!');
    // Ningún dato puede cerrar el script de la página.
    expect(
      homePageWith('<script>$homeMarker</script>', <String, Object?>{
        'x': '</script>',
      }),
      isNot(contains('</script></script>')),
    );
  });

  testWidgets('mantener pulsada a Flyra le habla y abre el chat', (
    WidgetTester tester,
  ) async {
    final HeardMic mic = HeardMic();
    final m.PageSpy spy = m.PageSpy();
    final session = await signedInSession(FakeGateway());
    await pumpApp(
      tester,
      locale: 'es',
      session: session,
      initialLocation: Routes.home,
      services: fakeServices(session, speechInput: mic, webScene: spy.build),
    );
    await spy.wait(tester, () => spy.pages.isNotEmpty);
    spy.send!('hold:1');
    await tester.pumpAndSettle();
    expect(mic.langs, <String>['es']);
    // La pregunta oída llega escrita a la caja del chat.
    expect(find.text('¿Qué visito hoy?'), findsOneWidget);
  });

  testWidgets('el cuadrado del centro abre su pantalla', (
    WidgetTester tester,
  ) async {
    final m.PageSpy spy = m.PageSpy();
    final session = await signedInSession(FakeGateway());
    await pumpApp(
      tester,
      locale: 'es',
      session: session,
      initialLocation: Routes.home,
      services: fakeServices(session, webScene: spy.build),
    );
    await spy.wait(tester, () => spy.pages.isNotEmpty);
    expect(homeTiles, hasLength(19));
    spy.send!('tile:0');
    await tester.pumpAndSettle();
    expect(find.byType(ExploreScreen), findsOneWidget);
  });

  testWidgets('SOS: WhatsApp, SMS y llamar; cambiar un contacto', (
    WidgetTester tester,
  ) async {
    final m.PageSpy spy = m.PageSpy();
    final session = await signedInSession(FakeGateway());
    final MemorySettingsStore prefs = MemorySettingsStore();
    await saveContacts(prefs, <SosContact>[
      const SosContact(name: 'Ana', phone: '+34600112233'),
    ]);
    final List<Uri> opened = <Uri>[];
    await pumpApp(
      tester,
      locale: 'es',
      session: session,
      initialLocation: Routes.home,
      services: fakeServices(
        session,
        prefs: prefs,
        webScene: spy.build,
        openLink: (Uri u) async {
          opened.add(u);
          return true;
        },
      ),
    );
    await spy.wait(tester, () => spy.pages.isNotEmpty);
    final Map<String, Object?> d = spy.data(HomeScreen.lastBridge!);
    expect((d['contacts']! as List<Object?>).single, <String, Object?>{
      'n': 'Ana',
      'p': '+34600112233',
    });
    expect((d['sos']! as Map<String, Object?>)['call'], '112');

    spy.send!('sos');
    await tester.pumpAndSettle();
    spy.send!('wa:0');
    spy.send!('sms:0');
    spy.send!('call');
    // Sin GPS en el test: se espera lo máximo (5 s + 8 s) y luego se manda.
    await tester.pump(const Duration(seconds: 14));
    await tester.pumpAndSettle();
    // WhatsApp y SMS esperan a saber dónde estás: pueden abrirse después.
    final Uri wa = opened.firstWhere((Uri u) => u.host == 'wa.me');
    expect(
      wa.queryParameters['text'],
      startsWith('🆘 EMERGENCIA: necesito ayuda urgente.'),
    );
    // Sin GPS no dice "Estoy aquí:" (haría creer que mandó la ubicación).
    expect(wa.queryParameters['text'], isNot(contains('Estoy aquí')));
    expect(opened.where((Uri u) => u.scheme == 'sms'), hasLength(1));
    expect(opened.map((Uri u) => u.toString()), contains('tel:112'));

    // "Añadir" en el segundo hueco: nombre y teléfono.
    spy.send!('pick:1');
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).at(0), 'Luis');
    await tester.enterText(find.byType(TextField).at(1), '+34 611 22 33 44');
    await tester.tap(find.text('Guardar'));
    await tester.pumpAndSettle();
    expect(loadContacts(prefs).map((SosContact c) => c.name), <String>[
      'Ana',
      'Luis',
    ]);
    expect(
      (spy.data(HomeScreen.lastBridge!)['contacts']! as List<Object?>).length,
      2,
    );
  });
}
