// Habla con Flyra: las palabras clave en los 10 idiomas y la pantalla (con
// micro, voz y enlaces de mentira).
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:eclipta/core/router.dart';
import 'package:eclipta/core/settings.dart';
import 'package:eclipta/features/assistant/interpreter.dart';
import 'package:eclipta/features/camera/speaker.dart';
import 'package:eclipta/features/easy/easy_mode.dart';
import 'package:eclipta/features/voice/voice_intents.dart';

import 'helpers.dart';

class FakeMic implements SpeechInput {
  final List<String> heard = <String>[];

  @override
  Future<String?> listen(String lang) async =>
      heard.isEmpty ? null : heard.removeAt(0);

  @override
  Future<void> stop() async {}
}

class FakeSpeaker implements Speaker {
  final List<String> said = <String>[];

  @override
  Future<void> speak(String text, String language) async => said.add(text);

  @override
  Future<void> stop() async {}
}

void main() {
  test('las preguntas de ejemplo se entienden en los 10 idiomas', () {
    const Map<String, VoiceIntent> examples = <String, VoiceIntent>{
      'voiceExFlight': VoiceIntent.flight,
      'voiceExMoney': VoiceIntent.money,
      'voiceExHotel': VoiceIntent.hotel,
      'voiceExVisa': VoiceIntent.visa,
      'voiceExLanguage': VoiceIntent.language,
    };
    for (final String lang in <String>[
      'en', 'es', 'fr', 'de', 'it', 'pt', 'ar', 'zh', 'ja', 'hi', //
    ]) {
      final Map<String, Object?> arb = jsonDecode(
        File('lib/l10n/app_$lang.arb').readAsStringSync(),
      ) as Map<String, Object?>;
      for (final MapEntry<String, VoiceIntent> e in examples.entries) {
        expect(
          matchIntent(arb[e.key]! as String, lang),
          e.value,
          reason: '$lang ${e.key}: ${arb[e.key]}',
        );
      }
    }
  });

  test('palabras enteras, problemas antes que el vuelo y SOS primero', () {
    expect(normalizeSpeech('¿Cuánto?'), '¿cuanto?');
    // "vol" no está dentro de "volver".
    expect(matchIntent('quiero volver', 'fr'), isNull);
    expect(matchIntent('perdí el vuelo', 'es'), VoiceIntent.trouble);
    expect(matchIntent('I missed my flight', 'en'), VoiceIntent.trouble);
    expect(matchIntent('ambulancia para el hotel', 'es'), VoiceIntent.sos);
    // Mezclar inglés también vale.
    expect(matchIntent('dónde hay wifi', 'es'), VoiceIntent.nearby);
    expect(matchIntent('Reserva cena para dos a las 21', 'es'), isNull);
  });

  testWidgets('pregunta por voz, por chip y lo que no sabe va a Flyra', (
    WidgetTester tester,
  ) async {
    final FakeMic mic = FakeMic()
      ..heard.addAll(<String>[
        '¿A qué hora sale mi avión?',
        'Reserva cena para dos a las 21',
      ]);
    final FakeSpeaker speaker = FakeSpeaker();
    final List<Uri> opened = <Uri>[];
    final MemorySettingsStore prefs = MemorySettingsStore();
    await saveEasyTrip(
      prefs,
      EasyTrip(
        departure: DateTime(2026, 12, 15, 9, 30),
        from: 'MAD',
        to: 'LIS',
        gate: 'B12',
        hotelName: 'Hotel Sol',
        hotelAddress: 'Rua Augusta 1, Lisboa',
      ),
    );
    final session = newSession()..continueAsGuest();
    tester.view.physicalSize = const Size(1200, 3000);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await pumpApp(
      tester,
      locale: 'es',
      session: session,
      initialLocation: Routes.voice,
      services: fakeServices(
        session,
        prefs: prefs,
        speechInput: mic,
        speaker: speaker,
        openLink: (Uri u) async {
          opened.add(u);
          return true;
        },
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Toca el micro y pregunta'), findsOneWidget);

    // 1. Por voz: la hora del vuelo (y lo lee en alto).
    await tester.tap(find.byIcon(Icons.mic_rounded));
    await tester.pumpAndSettle();
    expect(find.textContaining('Tu vuelo MAD → LIS sale el'), findsOneWidget);
    expect(find.textContaining('9:30'), findsOneWidget);
    expect(find.textContaining('Puerta B12.'), findsOneWidget);
    expect(speaker.said.single, contains('MAD → LIS'));

    // 2. Con el chip: llévame al hotel → Maps.
    await tester.tap(find.text('Llévame al hotel'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Vamos a Hotel Sol'), findsOneWidget);
    await tester.tap(find.text('Llévame'));
    await tester.pumpAndSettle();
    expect(opened.single.host, 'www.google.com');
    expect(opened.single.queryParameters['destination'], contains('Augusta'));

    // 3. Lo que no sabe hacer: al chat de Flyra.
    await tester.tap(find.byIcon(Icons.mic_rounded));
    await tester.pumpAndSettle();
    expect(find.text('Preguntar a Flyra en el chat'), findsOneWidget);

    // 4. Sin oír nada: lo dice.
    await tester.tap(find.byIcon(Icons.mic_rounded));
    await tester.pumpAndSettle();
    expect(find.textContaining('No te he oído'), findsOneWidget);
  });
}
