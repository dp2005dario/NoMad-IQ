// Lo que la app le da a la página del "Radar local" (la maqueta, en
// assets/radar/radar.html).
//
// Dart puro: se prueba sin WebView.
import 'dart:convert';

import 'package:intl/intl.dart';

import 'radar_api.dart';

/// Dónde está la página y la marca donde la app mete sus datos.
const String radarPage = 'assets/radar/radar.html';
const String radarMarker = '/*ECLIPTA*/{}';

/// Lo de arriba de la tarjeta de la lluvia, como en la maqueta: "LLUEVE
/// AHORA", "LLUEVE EN 40 MIN" o, si falta más de hora y media, "LLUEVE A
/// LAS 17:00". La previsión es por horas: [first] es la hora en que empieza.
String rainLabel(RainHour first, DateTime now, String locale) {
  final int min = first.time.difference(now).inMinutes;
  if (min <= 0) return 'LLUEVE AHORA';
  if (min <= 90) return 'LLUEVE EN $min MIN';
  return 'LLUEVE A LAS ${DateFormat.Hm(locale).format(first.time)}';
}

/// La página lista para enseñar.
String radarPageWith(String page, Map<String, Object?> data) =>
    // "<" como \u003c: ningún dato puede cerrar el script.
    page.replaceFirst(radarMarker, jsonEncode(data).replaceAll('<', r'\u003c'));

/// Lo que se le manda a la página sin recargarla.
String radarPushScript(Map<String, Object?> data) =>
    'window.ECLin&&window.ECLin(${jsonEncode(data).replaceAll('<', r'\u003c')})';
