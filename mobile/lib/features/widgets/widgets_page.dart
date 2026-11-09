// Lo que la app le da a la página de "Widgets" (la maqueta, en
// assets/widgets/widgets.html).
//
// Dart puro: se prueba sin WebView.
import 'dart:convert';

/// Dónde está la página y la marca donde la app mete sus datos.
const String widgetsPage = 'assets/widgets/widgets.html';
const String widgetsMarker = '/*ECLIPTA*/{}';

/// La página lista para enseñar.
String widgetsPageWith(String page, Map<String, Object?> data) =>
    // "<" como \u003c: ningún dato puede cerrar el script.
    page.replaceFirst(
      widgetsMarker,
      jsonEncode(data).replaceAll('<', r'\u003c'),
    );

/// Lo que se le manda a la página sin recargarla.
String widgetsPushScript(Map<String, Object?> data) =>
    'window.ECLin&&window.ECLin(${jsonEncode(data).replaceAll('<', r'\u003c')})';
