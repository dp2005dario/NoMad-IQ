// Lo que la app le da a la página de "Privacidad" (la maqueta, en
// assets/settings/privacidad.html).
//
// Dart puro: se prueba sin WebView.
import 'dart:convert';

/// Dónde está la página y la marca donde la app mete sus datos.
const String privacyPage = 'assets/settings/privacidad.html';
const String privacyMarker = '/*ECLIPTA*/{}';

/// "1 descargada", "3 descargadas" o "Ninguna".
String offlineCount(int n) => switch (n) {
  0 => 'Ninguna',
  1 => '1 descargada',
  _ => '$n descargadas',
};

/// La página lista para enseñar.
String privacyPageWith(String page, Map<String, Object?> data) =>
    // "<" como <: ningún dato puede cerrar el script.
    page.replaceFirst(privacyMarker, jsonEncode(data).replaceAll('<', r'<'));

/// Lo que se le manda a la página sin recargarla.
String privacyPushScript(Map<String, Object?> data) =>
    'window.ECLin&&window.ECLin(${jsonEncode(data).replaceAll('<', r'<')})';
