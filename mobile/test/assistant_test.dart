// Asistente: el intérprete cara a cara (traductor y micro de mentira).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:eclipta/core/router.dart';
import 'package:eclipta/core/settings.dart';
import 'package:eclipta/features/assistant/interpreter.dart';

import 'helpers.dart';

class FakeTranslator implements PhraseTranslator {
  final Set<String> models = <String>{'es'};
  final List<String> downloads = <String>[];

  @override
  Future<bool> hasModel(String lang) async => models.contains(lang);

  @override
  Future<bool> download(String lang, {bool wifiOnly = true}) async {
    downloads.add(lang);
    models.add(lang);
    return true;
  }

  @override
  Future<String> translate(
    String text, {
    required String from,
    required String to,
  }) async {
    if (!models.contains(from) || !models.contains(to)) {
      throw const TranslationUnavailable();
    }
    return '[$to] $text';
  }
}

class FakeMic implements SpeechInput {
  final List<String> heard = <String>[];
  final List<String> langs = <String>[];

  @override
  Future<String?> listen(String lang) async {
    langs.add(lang);
    return heard.isEmpty ? null : heard.removeAt(0);
  }

  @override
  Future<void> stop() async {}
}

void main() {
  testWidgets('descargar idiomas, hablar cada uno y cambiar el idioma', (
    WidgetTester tester,
  ) async {
    final FakeTranslator translator = FakeTranslator();
    final FakeMic mic = FakeMic()
      ..heard.addAll(<String>[
        '¿Dónde está la estación?',
        '¿Dónde está la estación?',
        'まっすぐです',
      ]);
    final MemorySettingsStore prefs = MemorySettingsStore();
    await prefs.writeData(LocalData.interpreterLang, 'ja');
    final session = newSession()..continueAsGuest();
    tester.view.physicalSize = const Size(1200, 3000);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await pumpApp(
      tester,
      locale: 'es',
      session: session,
      initialLocation: Routes.assistant,
      services: fakeServices(
        session,
        prefs: prefs,
        translator: translator,
        speechInput: mic,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Español ⇄ 日本語'), findsOneWidget);
    // Falta el japonés: sin él no traduce.
    expect(find.textContaining('Descarga 日本語'), findsOneWidget);
    await tester.tap(find.byTooltip('Hablar'));
    await tester.pumpAndSettle();
    expect(find.text('Primero descarga los idiomas (arriba).'), findsOneWidget);
    // Que se vaya el aviso (tapa el micro).
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Descargar'));
    await tester.pumpAndSettle();
    expect(translator.downloads, <String>['ja']);
    expect(find.textContaining('Descarga'), findsNothing);

    // Yo hablo en español; la otra persona lo lee en japonés.
    await tester.tap(find.byTooltip('Hablar'));
    await tester.pumpAndSettle();
    expect(mic.langs, <String>['es', 'es']);
    expect(find.text('¿Dónde está la estación?'), findsOneWidget);
    expect(find.text('[ja] ¿Dónde está la estación?'), findsOneWidget);

    // La otra persona pulsa SU micro (el tooltip es el nombre de su idioma).
    await tester.tap(find.byTooltip('日本語'));
    await tester.pumpAndSettle();
    expect(mic.langs.last, 'ja');
    expect(find.text('[es] まっすぐです'), findsOneWidget);

    // Nada oído: lo dice.
    await tester.tap(find.byTooltip('Hablar'));
    await tester.pumpAndSettle();
    expect(
      find.text('No te he oído. Prueba otra vez o escríbelo.'),
      findsOneWidget,
    );
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();

    // Cambiar su idioma.
    await tester.tap(find.text('Su idioma'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('한국어'),
      200,
      scrollable: find.descendant(
        of: find.byType(BottomSheet),
        matching: find.byType(Scrollable),
      ),
    );
    await tester.tap(find.text('한국어'));
    await tester.pumpAndSettle();
    expect(prefs.readData(LocalData.interpreterLang), 'ko');
    expect(find.text('Español ⇄ 한국어'), findsOneWidget);

    // La pestaña Pregunta.
    await tester.tap(find.text('Pregunta'));
    await tester.pumpAndSettle();
    expect(find.text('Apuntar con la cámara'), findsOneWidget);
  });
}
