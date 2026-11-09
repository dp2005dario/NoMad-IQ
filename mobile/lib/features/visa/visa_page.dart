// Lo que la app le da a la página de "Visado" (la maqueta, en
// assets/visa/visado.html).
//
// Dart puro: se prueba sin WebView.
import 'dart:convert';

/// Dónde está la página y la marca donde la app mete sus datos.
const String visaPage = 'assets/visa/visado.html';
const String visaMarker = '/*ECLIPTA*/{}';

/// La página lista para enseñar.
String visaPageWith(String page, Map<String, Object?> data) =>
    // "<" como \u003c: ningún dato puede cerrar el script.
    page.replaceFirst(visaMarker, jsonEncode(data).replaceAll('<', r'\u003c'));

/// Lo que se le manda a la página sin recargarla.
String visaPushScript(Map<String, Object?> data) =>
    'window.ECLin&&window.ECLin(${jsonEncode(data).replaceAll('<', r'\u003c')})';
