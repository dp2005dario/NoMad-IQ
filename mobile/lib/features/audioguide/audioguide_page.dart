// Lo que la app le da a la página de la audioguía (la maqueta, en
// assets/audioguide/audioguia.html, hecha con tool/audioguia/build_page.py):
// las partes con su texto y lo que duran, la foto real, el "¿Sabías que…?"
// y por dónde va el audio.
//
// Dart puro: se prueba sin WebView.
import 'dart:convert';

/// Dónde está la página y la marca donde la app mete sus datos.
const String audioguidePage = 'assets/audioguide/audioguia.html';
const String audioguideMarker = '/*ECLIPTA*/{}';

/// Una parte para la página: su texto y cuántos segundos dura.
Map<String, Object?> guidePartJson(String text, Duration length) =>
    <String, Object?>{'text': text, 'dur': length.inMilliseconds / 1000};

/// Lo que dura leer un texto en voz alta, más o menos (unas 2,5 palabras
/// por segundo). Para cuando aún no hay audio.
Duration readingTime(String text) => Duration(
  milliseconds:
      (text.split(RegExp(r'\s+')).where((String w) => w.isNotEmpty).length /
              2.5 *
              1000)
          .round()
          .clamp(1000, 3600000),
);

/// La página lista para enseñar.
String audioguidePageWith(String page, Map<String, Object?> data) =>
    // "<" como \u003c: ningún dato puede cerrar el script.
    page.replaceFirst(
      audioguideMarker,
      jsonEncode(data).replaceAll('<', r'\u003c'),
    );

/// Lo que se le manda a la página sin recargarla.
String audioguidePushScript(Map<String, Object?> data) =>
    'window.ECLin&&window.ECLin(${jsonEncode(data).replaceAll('<', r'\u003c')})';
