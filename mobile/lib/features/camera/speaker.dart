// La voz del móvil (texto a voz): lee en alto la ficha del monumento.
// Es la del propio sistema (Google en Android): gratis, sin red y en
// muchísimos idiomas. En los tests se usa una que solo apunta lo que "dice".
import 'package:flutter_tts/flutter_tts.dart';

abstract interface class Speaker {
  /// Lee [text] en el idioma [language] ("es", "ja"...). Termina al acabar.
  Future<void> speak(String text, String language);
  Future<void> stop();
}

class DeviceSpeaker implements Speaker {
  DeviceSpeaker() {
    // Que "speak" espere a que termine de hablar (así el botón vuelve a
    // "Escuchar" justo al acabar).
    _tts.awaitSpeakCompletion(true);
  }

  final FlutterTts _tts = FlutterTts();

  /// La mejor voz encontrada para cada idioma (se busca una vez).
  final Map<String, Map<String, String>?> _best =
      <String, Map<String, String>?>{};

  @override
  Future<void> speak(String text, String language) async {
    await _tts.setLanguage(language);
    final Map<String, String>? voice = _best.containsKey(language)
        ? _best[language]
        : _best[language] = await _bestVoice(language);
    if (voice != null) {
      try {
        await _tts.setVoice(voice);
      } on Object {
        // Si no la acepta, la de siempre.
      }
    }
    await _tts.speak(text);
  }

  /// La voz más natural del móvil para ese idioma: las "neuronales" de
  /// Google tienen calidad 400-500 (las normales, 300). Se prefieren las
  /// que funcionan sin internet.
  Future<Map<String, String>?> _bestVoice(String language) async {
    try {
      final Object? raw = await _tts.getVoices;
      if (raw is! List) return null;
      Map<String, String>? best;
      int bestScore = -1;
      for (final Object? v in raw) {
        if (v is! Map) continue;
        final String name = '${v['name'] ?? ''}';
        final String locale = '${v['locale'] ?? ''}'.replaceAll('_', '-');
        if (name.isEmpty || !locale.toLowerCase().startsWith(language)) {
          continue;
        }
        final int quality = int.tryParse('${v['quality'] ?? ''}') ?? 300;
        final bool network =
            '${v['network_required'] ?? ''}' == '1' ||
            name.toLowerCase().contains('network');
        final int score = quality + (network ? 0 : 50);
        if (score > bestScore) {
          bestScore = score;
          best = <String, String>{'name': name, 'locale': locale};
        }
      }
      return best;
    } on Object {
      return null;
    }
  }

  @override
  Future<void> stop() async {
    await _tts.stop();
  }
}

/// Sin voz (tests y aparatos sin motor de voz).
class SilentSpeaker implements Speaker {
  const SilentSpeaker();

  @override
  Future<void> speak(String text, String language) async {}

  @override
  Future<void> stop() async {}
}
