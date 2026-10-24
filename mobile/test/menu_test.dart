// Menú: la carta se lee en el móvil y solo el texto va al servidor.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:nomadiq/auth/session.dart';
import 'package:nomadiq/core/router.dart';
import 'package:nomadiq/features/menu/menu_api.dart';
import 'package:nomadiq/features/menu/menu_screen.dart';
import 'package:nomadiq/features/money/receipt_scanner.dart';

import 'camera_test.dart' show FakeSpeaker;
import 'helpers.dart';
import 'money_test.dart' show FakeScanner;

const List<String> carta = <String>['お品書き', '親子丼 1.200円', 'うどん 800円'];

Map<String, Object?> dish(
  String original,
  String name, {
  String allergens = '',
  String phrase = '',
  String sounds = '',
  String price = '',
}) => <String, Object?>{
  'original': original,
  'name': name,
  'description': 'Algo rico',
  'allergens': allergens,
  'order_phrase': phrase,
  'order_sounds': sounds,
  'price': price,
};

/// Un servidor falso que apunta en [sent] lo que le mandan.
void serveMenu(
  FakeGateway g, {
  int status = 200,
  List<Map<String, Object?>>? sent,
}) {
  g.services['/v1/menu/translate'] = (http.Request r) {
    sent?.add(jsonDecode(r.body) as Map<String, Object?>);
    if (status != 200) return http.Response('{}', status);
    return FakeGateway.json(<String, Object?>{
      'dishes': <Object?>[
        dish(
          '親子丼',
          'Oyakodon: pollo con huevo',
          allergens: 'Lleva gluten: salsa de soja',
          phrase: '親子丼をお願いします',
          sounds: 'Oyakodon o onegaishimasu',
          price: '1.200円',
        ),
        dish('うどん', 'Udon: fideos gruesos'),
        <String, Object?>{'original': '', 'name': 'sin nombre'},
      ],
      'remaining_today': 19,
    });
  };
}

void main() {
  test('un plato sin nombre o sin original se descarta', () {
    expect(Dish.parse(dish('親子丼', 'Oyakodon'))!.name, 'Oyakodon');
    expect(Dish.parse(dish('', 'Oyakodon')), isNull);
    expect(Dish.parse(dish('親子丼', '')), isNull);
    expect(Dish.parse('nada'), isNull);
  });

  test('el nombre de cada idioma del sitio', () {
    expect(menuLanguageName('ja'), '日本語');
    expect(menuLanguageName('ko'), '한국어');
    expect(menuLanguageName('sw'), 'sw');
    expect(menuLanguages, contains('es'));
  });

  test('el alfabeto del lector sale del idioma del sitio', () {
    expect(scriptForLanguage('ja')?.name, 'japanese');
    expect(scriptForLanguage('zh-Hans')?.name, 'chinese');
    expect(scriptForLanguage('es'), isNull);
    expect(scriptForLanguage(null), isNull);
  });

  Future<void> open(
    WidgetTester tester, {
    required ReceiptScanner scanner,
    FakeSpeaker? speaker,
    bool guest = false,
    int status = 200,
    List<Map<String, Object?>>? sent,
  }) async {
    final FakeGateway g = FakeGateway();
    serveMenu(g, status: status, sent: sent);
    final SessionController session = guest
        ? (newSession(g)..continueAsGuest())
        : await signedInSession(g);
    tester.view.physicalSize = const Size(1200, 2600);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await pumpApp(
      tester,
      locale: 'es',
      session: session,
      initialLocation: Routes.menu,
      services: fakeServices(
        session,
        gateway: g,
        receipts: scanner,
        speaker: speaker,
      ),
    );
  }

  testWidgets('la foto se queda en el móvil y los platos salen con su frase', (
    WidgetTester tester,
  ) async {
    final FakeScanner scanner = FakeScanner(carta);
    final FakeSpeaker voice = FakeSpeaker();
    final List<Map<String, Object?>> sent = <Map<String, Object?>>[];
    await open(tester, scanner: scanner, speaker: voice, sent: sent);
    await tester.tap(find.text('Fotografiar la carta'));
    await tester.pumpAndSettle();

    // Al servidor solo van las líneas de texto, nunca la foto.
    expect(sent.single['lines'], carta);
    expect(sent.single['place_language'], 'ja');
    expect(scanner.asked.single, ReceiptSource.camera);

    expect(find.text('親子丼'), findsOneWidget);
    expect(find.text('Udon: fideos gruesos'), findsOneWidget);
    expect(find.textContaining('te quedan 19 cartas hoy'), findsOneWidget);

    // La ficha del plato: alérgenos y "pídelo así" con voz japonesa.
    await tester.tap(find.text('親子丼'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Lleva gluten'), findsOneWidget);
    expect(find.text('Oyakodon o onegaishimasu'), findsOneWidget);
    await tester.tap(find.text('Escuchar'));
    await tester.pumpAndSettle();
    expect(voice.said.single, '親子丼をお願いします');
  });

  testWidgets('sin texto en la foto y sin cartas hoy se explica', (
    WidgetTester tester,
  ) async {
    await open(tester, scanner: FakeScanner(<String>[]));
    await tester.tap(find.text('Fotografiar la carta'));
    await tester.pumpAndSettle();
    expect(find.textContaining('No hemos podido leer nada'), findsOneWidget);
  });

  testWidgets('cuando se acaba el cupo diario lo dice', (
    WidgetTester tester,
  ) async {
    await open(tester, scanner: FakeScanner(carta), status: 429);
    await tester.tap(find.text('Fotografiar la carta'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Has usado las cartas de hoy'), findsOneWidget);
  });

  testWidgets('un invitado tiene que entrar', (WidgetTester tester) async {
    await open(tester, scanner: FakeScanner(carta), guest: true);
    expect(find.textContaining('es para cuentas de NomadIQ'), findsOneWidget);
    expect(find.text('Fotografiar la carta'), findsNothing);
  });
}
