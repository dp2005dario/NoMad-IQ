// Lo que la app le da a la página de "Zonas sin conexión" (la maqueta, en
// assets/offline/sinconexion.html).
//
// Dart puro: se prueba sin WebView.
import 'dart:convert';

import '../route/world_data.dart';

/// Dónde está la página y la marca donde la app mete sus datos.
const String offlinePage = 'assets/offline/sinconexion.html';
const String offlineMarker = '/*ECLIPTA*/{}';

/// Sin acentos y en minúsculas, para buscar "malaga" y encontrar "Málaga".
String plainText(String s) {
  const String from = 'áàâäãåéèêëíìîïóòôöõúùûüñçÁÀÂÄÃÅÉÈÊËÍÌÎÏÓÒÔÖÕÚÙÛÜÑÇ';
  const String to = 'aaaaaaeeeeiiiiooooouuuuncAAAAAAEEEEIIIIOOOOOUUUUNC';
  final StringBuffer out = StringBuffer();
  for (final int r in s.runes) {
    final String c = String.fromCharCode(r);
    final int i = from.indexOf(c);
    out.write(i < 0 ? c : to[i]);
  }
  return out.toString().toLowerCase().trim();
}

/// Las ciudades que salen al buscar: primero el aeropuerto con ese código
/// exacto, luego las ciudades que empiezan así y luego las que lo llevan
/// dentro. Como mucho [max].
List<Airport> searchAirports(Airports all, String query, {int max = 8}) {
  final String q = plainText(query);
  if (q.length < 2) return <Airport>[];
  final List<Airport> exact = <Airport>[];
  final List<Airport> starts = <Airport>[];
  final List<Airport> inside = <Airport>[];
  for (final Airport a in all.all) {
    final String city = plainText(a.city);
    if (a.iata.toLowerCase() == q) {
      exact.add(a);
    } else if (city.startsWith(q)) {
      starts.add(a);
    } else if (q.length >= 3 && city.contains(q)) {
      inside.add(a);
    }
  }
  int byName(Airport a, Airport b) {
    final int c = plainText(a.city).compareTo(plainText(b.city));
    return c != 0 ? c : a.iata.compareTo(b.iata);
  }

  starts.sort(byName);
  inside.sort(byName);
  return <Airport>[...exact, ...starts, ...inside].take(max).toList();
}

/// Cuánto ocupa cada ciudad en la barra de espacio, en % del total (los
/// trozos suman 100). Con todo a 0 no hay barra.
List<double> spaceShares(List<int> bytes) {
  final int total = bytes.fold(0, (int a, int b) => a + b);
  if (total <= 0) return <double>[];
  return <double>[
    for (final int b in bytes)
      double.parse((b * 100 / total).toStringAsFixed(2)),
  ];
}

/// La página lista para enseñar.
String offlinePageWith(String page, Map<String, Object?> data) =>
    // "<" como \u003c: ningún dato puede cerrar el script.
    page.replaceFirst(
      offlineMarker,
      jsonEncode(data).replaceAll('<', r'\u003c'),
    );

/// Lo que se le manda a la página sin recargarla.
String offlinePushScript(Map<String, Object?> data) =>
    'window.ECLin&&window.ECLin(${jsonEncode(data).replaceAll('<', r'\u003c')})';
