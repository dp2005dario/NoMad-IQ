// Lo que la app le da a la página de "Recuerdos" (la maqueta, en
// assets/memories/recuerdos.html).
//
// Dart puro: se prueba sin WebView.
import 'dart:convert';

/// Dónde está la página y la marca donde la app mete sus datos.
const String memoriesPage = 'assets/memories/recuerdos.html';
const String memoriesMarker = '/*ECLIPTA*/{}';

/// Los colores del "DÍA N · CIUDAD" de cada foto, por turnos (los de la
/// maqueta: rosa, azul y naranja).
const List<String> storyCaptionColors = <String>[
  '#F4A7BF',
  '#3DE0FF',
  '#FFB86B',
];

/// Lo que ha cambiado de [now] respecto a [before] (solo eso se le manda a
/// la página: las fotos pesan y no hace falta mandarlas cada vez).
Map<String, Object?> changedKeys(
  Map<String, Object?> before,
  Map<String, Object?> now,
) => <String, Object?>{
  for (final MapEntry<String, Object?> e in now.entries)
    if (!before.containsKey(e.key) ||
        jsonEncode(before[e.key]) != jsonEncode(e.value))
      e.key: e.value,
};

/// La página lista para enseñar.
String memoriesPageWith(String page, Map<String, Object?> data) =>
    // "<" como \u003c: ningún dato puede cerrar el script.
    page.replaceFirst(
      memoriesMarker,
      jsonEncode(data).replaceAll('<', r'\u003c'),
    );

/// Lo que se le manda a la página sin recargarla.
String memoriesPushScript(Map<String, Object?> data) =>
    'window.ECLin&&window.ECLin(${jsonEncode(data).replaceAll('<', r'\u003c')})';
