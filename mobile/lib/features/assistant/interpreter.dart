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

import 'package:flutter/foundation.dart';

import 'package:google_mlkit_language_id/google_mlkit_language_id.dart';
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
  /// [onPartial] recibe lo que va entendiendo mientras hablas (para
  /// enseñarlo en pantalla en directo).
  Future<String?> listen(String lang, {ValueChanged<String>? onPartial});

  /// "Ya he terminado": deja de escuchar y [listen] devuelve YA lo oído.
  Future<void> stop();

  /// Lo fuerte que hablas ahora (0 = silencio), para las ondas animadas.
  ValueListenable<double> get level;
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
  Future<String?> listen(
    String lang, {
    ValueChanged<String>? onPartial,
  }) async => null;

  @override
  Future<void> stop() async {}

  @override
  ValueListenable<double> get level => const _Silence();
}

class _Silence implements ValueListenable<double> {
  const _Silence();

  @override
  double get value => 0;

  @override
  void addListener(VoidCallback listener) {}

  @override
  void removeListener(VoidCallback listener) {}
}

/// Adivina el idioma de una frase escrita (o ya pasada a texto).
abstract interface class LanguageGuesser {
  /// El código ("it") si está bastante seguro y es uno de los del
  /// intérprete; null si no lo sabe.
  Future<String?> guess(String text);
}

/// Para los tests y los aparatos sin ML Kit: nunca adivina.
class NoLanguageGuesser implements LanguageGuesser {
  const NoLanguageGuesser();

  @override
  Future<String?> guess(String text) async => null;
}

/// ML Kit Language ID: funciona dentro del móvil, sin internet y gratis.
/// Con frases muy cortas ("ok", "taxi") no se fía: devuelve null.
class MlKitLanguageGuesser implements LanguageGuesser {
  final LanguageIdentifier _id = LanguageIdentifier(confidenceThreshold: 0.6);

  @override
  Future<String?> guess(String text) async {
    if (text.trim().length < 8) return null;
    try {
      final String code = await _id.identifyLanguage(text);
      // "zh-Latn" → "zh"; "und" = no lo sabe.
      final String base = code.split('-').first;
      return interpreterLanguages.containsKey(base) ? base : null;
    } on Object {
      return null;
    }
  }
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
///
/// Para que no tarde en darse cuenta de que has acabado:
///   - Se da por terminada la frase tras 1,5 s de silencio (antes, 3 s).
///   - Si el sistema dice "he terminado" sin resultado final, vale lo
///     último que entendió (antes se esperaban hasta 35 s).
///   - Volver a tocar el micro (= [stop]) devuelve lo oído al instante.
class DeviceSpeechInput implements SpeechInput {
  final SpeechToText _speech = SpeechToText();
  bool _ready = false;
  Completer<String?>? _done;
  String _last = '';
  final ValueNotifier<double> _level = ValueNotifier<double>(0);

  @override
  ValueListenable<double> get level => _level;

  @override
  Future<String?> listen(String lang, {ValueChanged<String>? onPartial}) async {
    _ready = _ready || await _speech.initialize(onStatus: _onStatus);
    if (!_ready) return null;
    final Completer<String?> done = _done = Completer<String?>();
    _last = '';
    await _speech.listen(
      onResult: (SpeechRecognitionResult r) {
        _last = r.recognizedWords;
        onPartial?.call(_last);
        if (r.finalResult) _finish();
      },
      // Android da de -2 a 10 (dB aproximados): se pasa a 0..1.
      onSoundLevelChange: (double db) =>
          _level.value = ((db + 2) / 12).clamp(0.0, 1.0),
      listenOptions: SpeechListenOptions(
        partialResults: true,
        // No se fuerza "solo en el móvil": si el idioma no está instalado,
        // Android usa su propio servicio de voz (no el nuestro). Con el
        // idioma instalado en el móvil, funciona sin internet.
        onDevice: false,
        localeId: lang,
        listenMode: ListenMode.dictation,
        listenFor: const Duration(seconds: 60),
        pauseFor: const Duration(milliseconds: 1500),
      ),
    );
    final String? heard = await done.future.timeout(
      const Duration(seconds: 65),
      onTimeout: () => _last,
    );
    _level.value = 0;
    _done = null;
    return heard == null || heard.trim().isEmpty ? null : heard.trim();
  }

  /// "done" = el sistema ha dejado de escuchar del todo.
  void _onStatus(String status) {
    if (status == 'done') _finish();
  }

  void _finish() {
    final Completer<String?>? c = _done;
    if (c != null && !c.isCompleted) c.complete(_last);
  }

  @override
  Future<void> stop() async {
    _finish();
    await _speech.stop();
  }
}
