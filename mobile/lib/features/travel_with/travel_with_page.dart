// Lo que la app le da a la página de "Viajo con mi perro" (la maqueta, en
// assets/travel_with/viajocon.html).
//
// Dart puro: se prueba sin WebView.
import 'dart:convert';

/// Dónde está la página y la marca donde la app mete sus datos.
const String travelWithPage = 'assets/travel_with/viajocon.html';
const String travelWithMarker = '/*ECLIPTA*/{}';

/// "7,5": los kilos como se escriben en español (sin ",0").
String kgLabel(double kg) {
  final String s = kg.toStringAsFixed(1);
  return (s.endsWith('.0') ? s.substring(0, s.length - 2) : s).replaceAll(
    '.',
    ',',
  );
}

/// La página lista para enseñar.
String travelWithPageWith(String page, Map<String, Object?> data) =>
    // "<" como \u003c: ningún dato puede cerrar el script.
    page.replaceFirst(
      travelWithMarker,
      jsonEncode(data).replaceAll('<', r'\u003c'),
    );

/// Lo que se le manda a la página sin recargarla.
String travelWithPushScript(Map<String, Object?> data) =>
    'window.ECLin&&window.ECLin(${jsonEncode(data).replaceAll('<', r'\u003c')})';
