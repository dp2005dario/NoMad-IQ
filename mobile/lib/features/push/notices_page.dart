// Lo que la app le da a la página de "Avisos" (la maqueta, en
// assets/push/avisos.html): tu historial de avisos y los textos en tu idioma.
//
// Dart puro: se prueba sin WebView.
import 'dart:convert';

import 'notice_log.dart';
import 'push_notice.dart';

/// Dónde está la página y la marca donde la app mete sus datos.
const String noticesPage = 'assets/push/avisos.html';
const String noticesMarker = '/*ECLIPTA*/{}';

/// El dibujo de cada aviso en la página (y en qué pestaña sale):
/// zone y safety en "Zonas", flight en "Vuelos" y group en "Grupo".
String noticeDrawing(PushKind kind) => switch (kind) {
  PushKind.zoneAudioguide => 'zone',
  PushKind.zoneSafety => 'safety',
  PushKind.airportArrival || PushKind.fareAlert => 'flight',
  PushKind.groupChat || PushKind.groupResult => 'group',
};

/// La hora como en la maqueta: "13:28" si es de hoy, [yesterday] si es de
/// ayer y la fecha corta ("24/10") si es más viejo.
String noticeTime(DateTime at, DateTime now, String yesterday) {
  final DateTime a = at.toLocal();
  final DateTime n = now.toLocal();
  final DateTime day = DateTime(a.year, a.month, a.day);
  final DateTime today = DateTime(n.year, n.month, n.day);
  String two(int v) => v.toString().padLeft(2, '0');
  if (day == today) return '${two(a.hour)}:${two(a.minute)}';
  if (day == DateTime(today.year, today.month, today.day - 1)) {
    return yesterday;
  }
  return '${two(a.day)}/${two(a.month)}';
}

/// Los avisos para la página (el número [i] es su sitio en [all]).
List<Map<String, Object?>> noticeItems(
  List<NoticeEntry> all,
  DateTime now,
  String yesterday,
) => <Map<String, Object?>>[
  for (int i = 0; i < all.length; i++)
    <String, Object?>{
      'i': i,
      'kind': noticeDrawing(all[i].kind),
      'title': all[i].title,
      'body': all[i].body,
      'time': noticeTime(all[i].at, now, yesterday),
    },
];

/// La página lista para enseñar.
String noticesPageWith(String page, Map<String, Object?> data) =>
    // "<" como \u003c: ningún dato puede cerrar el script.
    page.replaceFirst(
      noticesMarker,
      jsonEncode(data).replaceAll('<', r'\u003c'),
    );

/// Lo que se le manda a la página sin recargarla.
String noticesPushScript(Map<String, Object?> data) =>
    'window.ECLin&&window.ECLin(${jsonEncode(data).replaceAll('<', r'\u003c')})';
