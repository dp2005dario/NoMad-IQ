// Lo que la app le da a la página del Modo fácil (la maqueta, en
// assets/easy/facil.html): el día, tu vuelo, tu hotel, tu familia y lo que
// contesta Flyra.
//
// Dart puro: se prueba sin WebView.
import 'dart:convert';

import 'package:intl/intl.dart';

import '../../l10n/generated/app_localizations.dart';
import 'easy_mode.dart';

/// Dónde está la página y la marca donde la app mete sus datos.
const String easyPage = 'assets/easy/facil.html';
const String easyMarker = '/*ECLIPTA*/{}';

/// Los colores de cada persona de la familia (como los círculos de la
/// maqueta): se reparten por orden.
const List<String> easyFamilyColors = <String>[
  '#3DDC97',
  '#FF8FB1',
  '#6CA8FF',
  '#FFB86B',
  '#B69CFF',
];

/// El nombre de cada tipo de ayuda del aeropuerto.
String easyHelpLabel(AppLocalizations t, int i) => switch (i) {
  0 => t.easyHelpWheelchair,
  1 => t.easyHelpWalk,
  _ => t.easyHelpBag,
};

/// "Jueves 23 de octubre" (en tu idioma, con mayúscula y sin coma).
String easyDay(DateTime now, String tag) {
  final String s = DateFormat.MMMMEEEEd(tag).format(now).replaceFirst(',', '');
  return s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);
}

/// La tarjeta del vuelo: "TU VUELO · MAÑANA", la hora, "Madrid → Lisboa",
/// la puerta y a qué hora salir de casa. Sin vuelo, solo "TU VUELO".
Map<String, Object?> easyFlightJson(
  EasyTrip trip,
  AppLocalizations t,
  String tag,
  DateTime now, {
  required String from,
  required String to,
}) {
  final DateTime? dep = trip.departure;
  if (!trip.hasFlight || dep == null) {
    return <String, Object?>{'k': t.easyYourFlight};
  }
  final DateFormat hour = DateFormat.Hm(tag);
  final int days = DateTime(
    dep.year,
    dep.month,
    dep.day,
  ).difference(DateTime(now.year, now.month, now.day)).inDays;
  final String when = switch (days) {
    0 => t.easyToday,
    1 => t.easyTomorrow,
    _ => DateFormat.MMMEd(tag).format(dep).toUpperCase(),
  };
  final String leave = hour.format(leaveHomeAt(dep));
  final String? gate = trip.gate;
  final bool hasGate = gate != null && gate.isNotEmpty;
  return <String, Object?>{
    'k': '${t.easyYourFlight} · $when',
    'time': hour.format(dep),
    'route': '$from → $to',
    'gateLbl': hasGate ? '${t.easyGate} ' : '',
    'gate': hasGate ? gate : '',
    'leave': hasGate ? ' ${t.easyLeaveLower(leave)}' : t.easyLeaveAt(leave),
  };
}

/// La página lista para enseñar.
String easyPageWith(String page, Map<String, Object?> data) =>
    // "<" como \u003c: ningún dato puede cerrar el script.
    page.replaceFirst(easyMarker, jsonEncode(data).replaceAll('<', r'\u003c'));

/// Lo que se le manda a la página sin recargarla.
String easyPushScript(Map<String, Object?> data) =>
    'window.ECLin&&window.ECLin(${jsonEncode(data).replaceAll('<', r'\u003c')})';
