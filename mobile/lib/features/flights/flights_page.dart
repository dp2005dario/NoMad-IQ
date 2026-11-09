// Lo que la app le da a la página de Vuelos (la maqueta "Cazador de vuelos",
// en assets/flights/vuelos.html): tus chollos de hoy (el mejor arriba), la
// ruta de cada uno con sus coordenadas, tus alertas y si falló algo.
//
// Los nombres de ciudades y países (en español) los pone la propia página
// con su lista de aeropuertos. Aquí van los datos: códigos, precios,
// posiciones y horas. Dart puro: se prueba sin WebView.
import 'dart:convert';
import 'dart:math' as math;

import '../route/geo.dart';
import '../route/world_data.dart';
import 'fares_api.dart';

/// Dónde está la página y la marca donde la app mete sus datos.
const String flightsPage = 'assets/flights/vuelos.html';
const String flightsMarker = '/*ECLIPTA*/{}';

/// Los monumentos que dibuja la maqueta (su nombre en la página), dónde
/// están y por qué lado del avión salen en el vuelo simulado.
const List<(String, LatLon, int)> pageMonuments = <(String, LatLon, int)>[
  ('palacio', LatLon(40.4180, -3.7143), -1),
  ('alcala', LatLon(40.4200, -3.6887), 1),
  ('eiffel', LatLon(48.8584, 2.2945), 1),
  ('branden', LatLon(52.5163, 13.3777), -1),
  ('basilio', LatLon(55.7525, 37.6231), 1),
  ('muralla', LatLon(40.4319, 116.5704), -1),
  ('fuji', LatLon(35.3606, 138.7274), -1),
  ('ttower', LatLon(35.6586, 139.7454), 1),
];

/// Los monumentos a menos de [maxKm] del camino: nombre → [lat, lon, en
/// qué momento del vuelo se pasa (0 = despegue, 1 = llegada), lado].
Map<String, List<num>> monumentsNear(
  LatLon from,
  LatLon to, {
  double maxKm = 600,
}) {
  const int steps = 64;
  final List<LatLon> path = <LatLon>[
    for (int i = 0; i <= steps; i++) intermediate(from, to, i / steps),
  ];
  final Map<String, List<num>> out = <String, List<num>>{};
  for (final (String key, LatLon at, int side) in pageMonuments) {
    double best = double.infinity;
    int bestI = 0;
    for (int i = 0; i < path.length; i++) {
      final double d = distanceKm(path[i], at);
      if (d < best) {
        best = d;
        bestI = i;
      }
    }
    if (best > maxKm) continue;
    // Como en la maqueta: los de la salida se ven nada más despegar y los
    // de la llegada, al aterrizar.
    final double t = bestI / steps;
    out[key] = <num>[
      at.lat,
      at.lon,
      t <= 0.04
          ? 0.04
          : t >= 0.96
          ? 1.04
          : double.parse(t.toStringAsFixed(3)),
      side,
    ];
  }
  return out;
}

/// Por dónde va el avión: [momento, país]. "^" = despegando, "$" = llegando,
/// "" = sobre el mar, o el código del país (el del aeropuerto más cercano a
/// menos de 350 km). Solo se apunta cuando cambia.
List<List<Object>> regionsAlong(
  LatLon from,
  LatLon to,
  Iterable<Airport> airports,
  String? Function(String country) codeOf,
) {
  final List<List<Object>> out = <List<Object>>[
    <Object>[0, '^'],
  ];
  // Los aeropuertos en una rejilla de 5° para no mirar los 5.500 cada vez.
  final Map<int, List<Airport>> grid = <int, List<Airport>>{};
  int cell(double lat, double lon) =>
      ((lat + 90) ~/ 5) * 100 + ((lon + 180) ~/ 5);
  for (final Airport a in airports) {
    grid
        .putIfAbsent(cell(a.position.lat, a.position.lon), () => <Airport>[])
        .add(a);
  }
  String last = '^';
  for (double t = 0.12; t < 0.88; t += 0.04) {
    final LatLon p = intermediate(from, to, t);
    Airport? best;
    double bestKm = 350;
    for (int dy = -1; dy <= 1; dy++) {
      for (int dx = -1; dx <= 1; dx++) {
        final int lon = ((p.lon + 180) ~/ 5 + dx) % 72;
        final int c = ((p.lat + 90) ~/ 5 + dy) * 100 + lon;
        for (final Airport a in grid[c] ?? const <Airport>[]) {
          final double d = distanceKm(p, a.position);
          if (d < bestKm) {
            bestKm = d;
            best = a;
          }
        }
      }
    }
    final String here = best == null ? '' : (codeOf(best.country) ?? '');
    if (here != last) {
      out.add(<Object>[double.parse(t.toStringAsFixed(2)), here]);
      last = here;
    }
  }
  out.add(<Object>[0.88, r'$']);
  return out;
}

/// La ruta de un chollo para el globo, el vuelo y las fichas. [offset] da
/// la diferencia con UTC (en minutos) de una zona horaria en una fecha.
Map<String, Object?>? routeJson(
  String origin,
  String destination, {
  required Airports airports,
  required String? Function(String country) codeOf,
  required int? Function(String zone, DateTime when) offset,
  required DateTime now,
}) {
  final Airport? o = airports[origin];
  final Airport? d = airports[destination];
  if (o == null || d == null) return null;
  final double km = distanceKm(o.position, d.position);
  // La otra mitad del año (para "+2 en verano").
  final DateTime other = DateTime.utc(now.year, now.month <= 6 ? 12 : 6, 21);
  Map<String, Object?> end(Airport a) => <String, Object?>{
    'iata': a.iata,
    'lat': a.position.lat,
    'lon': a.position.lon,
    'cc': codeOf(a.country) ?? '',
    'off': offset(a.timeZone, now),
    'alt': offset(a.timeZone, other),
  };
  return <String, Object?>{
    'o': end(o),
    'd': end(d),
    // El globo se centra en la mitad del camino.
    'c': double.parse(
      intermediate(o.position, d.position, 0.5).lon.toStringAsFixed(1),
    ),
    'km': km.round(),
    'min': estimatedFlightTime(km).inMinutes,
    'mons': monumentsNear(o.position, d.position),
    'regions': regionsAlong(o.position, d.position, airports.all, codeOf),
  };
}

/// "Hace 14 min" / "Hace 3 h" / "Hace 2 días".
String agoText(DateTime observed, DateTime now) {
  final int m = math.max(0, now.difference(observed).inMinutes);
  if (m < 1) return 'Ahora mismo';
  if (m < 60) return 'Hace $m min';
  if (m < 48 * 60) return 'Hace ${m ~/ 60} h';
  return 'Hace ${m ~/ (24 * 60)} días';
}

const List<String> _months = <String>[
  'enero',
  'febrero',
  'marzo',
  'abril',
  'mayo',
  'junio',
  'julio',
  'agosto',
  'septiembre',
  'octubre',
  'noviembre',
  'diciembre',
];

/// Un chollo para la página ([i] = su número en la lista).
Map<String, Object?> dealJson(
  int i,
  Deal deal, {
  required DateTime now,
  Map<String, Object?>? route,
}) {
  final FareRoute r = deal.fare.route;
  final bool oneWay = r.returnDate == null;
  final int drop = deal.dropBasisPoints;
  return <String, Object?>{
    'i': i,
    'o': r.origin,
    'd': r.destination,
    'pm': deal.fare.price.amountMinor,
    'usualMinor': deal.usualMinor,
    'drop': drop,
    'cur': deal.fare.price.currency,
    'ow': oneWay,
    'y': r.departure.year,
    'm': r.departure.month,
    'day': r.departure.day,
    // Las barras empiezan con el precio del chollo; el de cada día del mes
    // llega después (la página lo pide).
    'sel': 0,
    'bars': <Map<String, int>>[
      <String, int>{'d': r.departure.day, 'p': deal.fare.price.amountMinor},
    ],
    'kind': deal.looksLikeErrorFare
        ? '¡VUELO CAZADO! · ERROR DE TARIFA'
        : drop > 0
        ? '¡VUELO CAZADO!'
        : 'EL MÁS BARATO DE HOY',
    'ago': agoText(deal.fare.observedAt, now),
    'trip': oneWay ? 'Solo ida' : 'Ida y vuelta',
    'extra': oneWay
        ? ''
        : 'vuelta el ${r.returnDate!.day} de ${_months[r.returnDate!.month - 1]}',
    'route': route,
  };
}

/// Una ruta que vigilas, para "Tus alertas de precio".
Map<String, Object?> alertJson(Watch w, String Function(Money) money) {
  final Money? target = w.target;
  final Money? latest = w.latest?.price;
  final bool hit =
      target != null &&
      latest != null &&
      latest.currency == target.currency &&
      latest.amountMinor <= target.amountMinor;
  final int pct = target == null || latest == null || latest.amountMinor == 0
      ? 0
      : math.min(100, target.amountMinor * 100 ~/ latest.amountMinor);
  return <String, Object?>{
    'route': '${w.route.origin} → ${w.route.destination}',
    'd': w.route.destination,
    'target': target == null
        ? '· sin precio objetivo'
        : '· si baja de ${money(target)}',
    'price': latest == null ? '—' : money(latest),
    'hit': hit,
    'pct': hit ? 100 : pct,
  };
}

/// Todo lo que necesita la página.
Map<String, Object?> flightsPageData({
  required DateTime now,
  required String origin,
  required String locale,
  required String initial,
  required List<Map<String, Object?>> deals,
  required List<Map<String, Object?>> alerts,
  required bool guest,
  required bool failed,
  bool loading = false,
}) {
  final String code = deals.isNotEmpty ? deals.first['cur']! as String : 'EUR';
  return <String, Object?>{
    // El día de hoy contado desde 1970 (como cuenta la página los días).
    'today':
        DateTime.utc(now.year, now.month, now.day).millisecondsSinceEpoch ~/
        Duration.millisecondsPerDay,
    'origin': origin,
    'initial': initial,
    'locale': locale,
    'cur': code,
    'exp': <String, int>{
      for (final Map<String, Object?> d in deals)
        d['cur']! as String: _digits(d['cur']! as String),
    },
    'deals': deals,
    'empty': loading
        ? 'Buscando los chollos de hoy…'
        : failed
        ? 'No he podido traer los chollos de hoy. Toca «Reintentar» en el aviso.'
        : 'Aún no hay chollos desde {city}. Vuelve en un rato.',
    'alerts': alerts,
    'alertsNote': guest
        ? 'Entra con tu cuenta para vigilar rutas y que te avisemos si bajan.'
        : 'Aún no vigilas ninguna ruta. Toca «Avisar si baja» en un chollo.',
    'guest': guest,
    'fly': failed,
  };
}

/// Decimales de cada divisa (las que no tienen céntimos, 0).
int _digits(String currency) => switch (currency) {
  'JPY' || 'KRW' || 'CLP' || 'ISK' || 'HUF' || 'VND' || 'PYG' => 0,
  'KWD' || 'BHD' || 'OMR' || 'JOD' || 'TND' => 3,
  _ => 2,
};

/// La página lista para enseñar.
String flightsPageWith(String page, Map<String, Object?> data) {
  // "<" como \u003c: ningún dato puede cerrar el script.
  final String json = jsonEncode(data).replaceAll('<', r'\u003c');
  return page.replaceFirst(flightsMarker, json);
}

/// Lo que manda la página con "palabra:0:base64url" (el buscador, el
/// calendario) → el objeto. null si no se entiende.
Map<String, Object?>? unpackJson(String packed) {
  try {
    final String padded = packed.padRight((packed.length + 3) ~/ 4 * 4, '=');
    final Object? v = jsonDecode(utf8.decode(base64Url.decode(padded)));
    return v is Map<String, Object?> ? v : null;
  } on FormatException {
    return null;
  }
}

/// Lo que se le manda a la página sin recargarla: window.ECLin({...}).
String pushScript(Map<String, Object?> data) =>
    'window.ECLin&&window.ECLin(${jsonEncode(data).replaceAll('<', r'\u003c')})';
