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

  @override
  Future<void> speak(String text, String language) async {
    await _tts.setLanguage(language);
    await _tts.speak(text);
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
