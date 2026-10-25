// El intérprete de bolsillo del Asistente: oír, traducir y hablar, TODO
// dentro del móvil.
//
//   - Oír: el reconocimiento de voz de Android (speech_to_text). Con el
//     idioma descargado en el móvil funciona sin internet.
//   - Traducir: ML Kit de Google en el propio móvil
//     (google_mlkit_translation). Cada idioma es un modelo de ~30 MB que se
//     baja UNA vez (con wifi) y luego va en modo avión.
//   - Hablar: la voz del móvil (flutter_tts, ver camera/speaker.dart).
//
// 0 € y privado: lo que dices nunca pasa por nuestros servidores.
import 'dart:async';

import 'package:google_mlkit_translation/google_mlkit_translation.dart';
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text/speech_to_text.dart';

/// Los idiomas del intérprete: los 10 de la app y los más viajeros.
/// Cada uno con su nombre en su propio idioma (así lo reconoce la otra
/// persona aunque no sepa leer el tuyo).
const Map<String, String> interpreterLanguages = <String, String>{
  'en': 'English',
  'es': 'Español',
  'fr': 'Français',
  'de': 'Deutsch',
  'it': 'Italiano',
  'pt': 'Português',
  'ar': 'العربية',
  'zh': '中文',
  'ja': '日本語',
  'hi': 'हिन्दी',
  'ko': '한국어',
  'th': 'ไทย',
  'vi': 'Tiếng Việt',
  'id': 'Bahasa Indonesia',
  'ms': 'Bahasa Melayu',
  'tr': 'Türkçe',
  'ru': 'Русский',
  'uk': 'Українська',
  'pl': 'Polski',
  'nl': 'Nederlands',
  'el': 'Ελληνικά',
  'cs': 'Čeština',
  'ro': 'Română',
  'hu': 'Magyar',
  'sv': 'Svenska',
  'da': 'Dansk',
  'fi': 'Suomi',
  'no': 'Norsk',
  'he': 'עברית',
  'tl': 'Tagalog',
  'sw': 'Kiswahili',
  'bn': 'বাংলা',
  'ur': 'اردو',
  'fa': 'فارسی',
};

/// Idiomas que se escriben de derecha a izquierda.
const Set<String> rtlLanguages = <String>{'ar', 'he', 'ur', 'fa'};

abstract interface class PhraseTranslator {
  /// ¿Está ya el modelo de [lang] en el móvil?
  Future<bool> hasModel(String lang);

  /// Lo descarga (solo con wifi, por defecto). true = listo.
  Future<bool> download(String lang, {bool wifiOnly = true});

  Future<String> translate(
    String text, {
    required String from,
    required String to,
  });
}

abstract interface class SpeechInput {
  /// Escucha una frase en [lang] y devuelve lo que entendió (null = nada).
  Future<String?> listen(String lang);

  Future<void> stop();
}

/// Para los tests y los aparatos sin ML Kit: no traduce nada.
class NoTranslator implements PhraseTranslator {
  const NoTranslator();

  @override
  Future<bool> hasModel(String lang) async => false;

  @override
  Future<bool> download(String lang, {bool wifiOnly = true}) async => false;

  @override
  Future<String> translate(
    String text, {
    required String from,
    required String to,
  }) async => throw const TranslationUnavailable();
}

class NoSpeechInput implements SpeechInput {
  const NoSpeechInput();

  @override
  Future<String?> listen(String lang) async => null;

  @override
  Future<void> stop() async {}
}

class TranslationUnavailable implements Exception {
  const TranslationUnavailable();
}

class MlKitTranslator implements PhraseTranslator {
  final OnDeviceTranslatorModelManager _models =
      OnDeviceTranslatorModelManager();

  // Un traductor por pareja de idiomas, reutilizado (crearlo cuesta).
  final Map<String, OnDeviceTranslator> _open = <String, OnDeviceTranslator>{};

  static TranslateLanguage? _lang(String code) => TranslateLanguage.values
      .where((TranslateLanguage l) => l.bcpCode == code)
      .firstOrNull;

  @override
  Future<bool> hasModel(String lang) async {
    final TranslateLanguage? l = _lang(lang);
    return l != null && await _models.isModelDownloaded(l.bcpCode);
  }

  @override
  Future<bool> download(String lang, {bool wifiOnly = true}) async {
    final TranslateLanguage? l = _lang(lang);
    if (l == null) return false;
    return _models.downloadModel(l.bcpCode, isWifiRequired: wifiOnly);
  }

  @override
  Future<String> translate(
    String text, {
    required String from,
    required String to,
  }) async {
    if (from == to) return text;
    final TranslateLanguage? a = _lang(from);
    final TranslateLanguage? b = _lang(to);
    if (a == null || b == null) throw const TranslationUnavailable();
    final OnDeviceTranslator t = _open.putIfAbsent(
      '$from>$to',
      () => OnDeviceTranslator(sourceLanguage: a, targetLanguage: b),
    );
    try {
      return await t.translateText(text);
    } on Exception {
      throw const TranslationUnavailable();
    }
  }
}

/// El reconocimiento de voz del sistema (Android).
class DeviceSpeechInput implements SpeechInput {
  final SpeechToText _speech = SpeechToText();
  bool _ready = false;

  @override
  Future<String?> listen(String lang) async {
    _ready = _ready || await _speech.initialize();
    if (!_ready) return null;
    final Completer<String?> done = Completer<String?>();
    String last = '';
    await _speech.listen(
      onResult: (SpeechRecognitionResult r) {
        last = r.recognizedWords;
        if (r.finalResult && !done.isCompleted) done.complete(last);
      },
      listenOptions: SpeechListenOptions(
        partialResults: true,
        // No se fuerza "solo en el móvil": si el idioma no está instalado,
        // Android usa su propio servicio de voz (no el nuestro). Con el
        // idioma instalado en el móvil, funciona sin internet.
        onDevice: false,
        localeId: lang,
        listenFor: const Duration(seconds: 30),
        pauseFor: const Duration(seconds: 3),
      ),
    );
    // Si el sistema se calla sin "resultado final", vale lo último oído.
    final String? heard = await done.future.timeout(
      const Duration(seconds: 35),
      onTimeout: () => last,
    );
    return heard == null || heard.trim().isEmpty ? null : heard.trim();
  }

  @override
  Future<void> stop() => _speech.stop();
}
