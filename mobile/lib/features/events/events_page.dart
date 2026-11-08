// Lo que la app le da a la página "Qué pasa en tus fechas" (la maqueta
// "Eventos", en assets/events/eventos.html): tus días, los festivos y
// eventos de verdad (con su fuente), dónde caen en el mapa, lo que has
// guardado y lo que ya mandaste a "Elegid planes".
//
// Dart puro: se prueba sin WebView.
import 'dart:convert';
import 'dart:math' as math;

import 'package:intl/intl.dart';

import '../map/geo.dart';
import 'events_api.dart';

/// Dónde está la página y la marca donde la app mete sus datos.
const String eventsPage = 'assets/events/eventos.html';
const String eventsMarker = '/*ECLIPTA*/{}';

/// Como mucho, los días que caben en la fila de la maqueta.
const int maxEventDays = 6;

const List<String> _dows = <String>[
  'LUN',
  'MAR',
  'MIÉ',
  'JUE',
  'VIE',
  'SÁB',
  'DOM',
];
const List<String> _weekdays = <String>[
  'Lunes',
  'Martes',
  'Miércoles',
  'Jueves',
  'Viernes',
  'Sábado',
  'Domingo',
];
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

/// La categoría de la maqueta (Música, Fiestas, Deporte, Teatro, Familia).
String eventCat(EventKind k) => switch (k) {
  EventKind.music => 'mus',
  EventKind.holiday => 'fie',
  EventKind.sports => 'dep',
  EventKind.arts => 'tea',
  EventKind.family => 'fam',
  EventKind.other => 'otr',
};

/// El dibujo de la maqueta para cada tipo.
String eventIcon(EventKind k) => switch (k) {
  EventKind.music => 'music',
  EventKind.holiday => 'fish',
  EventKind.sports => 'ball',
  EventKind.arts => 'masks',
  EventKind.family => 'bag',
  EventKind.other => 'ticket',
};

/// "2026-06-10" (la clave de cada día).
String dayKey(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

/// "10-13 de junio" o "30 de mayo-2 de junio".
String rangeText(DateTime a, DateTime b) {
  if (a.year == b.year && a.month == b.month) {
    return a.day == b.day
        ? '${a.day} de ${_months[a.month - 1]}'
        : '${a.day}-${b.day} de ${_months[a.month - 1]}';
  }
  return '${a.day} de ${_months[a.month - 1]}-${b.day} de ${_months[b.month - 1]}';
}

/// "a 12 min andando de tu hotel" (a 80 m por minuto) o "a 7,5 km de tu
/// hotel".
String fromHotelText(double meters) => meters <= 3000
    ? 'a ${math.max(1, (meters / 80).round())} min andando de tu hotel'
    : 'a ${(meters / 1000).toStringAsFixed(1).replaceAll('.', ',')} km de tu hotel';

/// Dónde cae cada evento en el dibujo del mapa (en %, como en la maqueta):
/// tu hotel (o el centro de los eventos) en el punto azul, y todos a la
/// misma escala para que se vea qué está lejos y qué cerca.
List<Map<String, Object?>> eventPins(List<CityEvent> events, GeoPoint? hotel) {
  final List<CityEvent> at = <CityEvent>[
    for (final CityEvent e in events)
      if (e.lat != null && e.lon != null) e,
  ];
  if (at.isEmpty) return const <Map<String, Object?>>[];
  final GeoPoint c =
      hotel ??
      GeoPoint(
        at.map((CityEvent e) => e.lat!).reduce((double a, double b) => a + b) /
            at.length,
        at.map((CityEvent e) => e.lon!).reduce((double a, double b) => a + b) /
            at.length,
      );
  double east(CityEvent e) =>
      (e.lon! - c.lon) * 111320 * math.cos(c.lat * math.pi / 180);
  double north(CityEvent e) => (e.lat! - c.lat) * 110540;
  // El mapa mide 334 × 190: el punto azul está en (50 %, 55 %).
  double far = 1;
  for (final CityEvent e in at) {
    far = math.max(far, math.max(east(e).abs() / 150, north(e).abs() / 80));
  }
  return <Map<String, Object?>>[
    for (final CityEvent e in at)
      <String, Object?>{
        'id': e.id,
        'name': e.name,
        'ik': eventIcon(e.kind),
        'x': ((167 + east(e) / far) / 334 * 100).clamp(6, 94).round(),
        'y': ((104.5 - north(e) / far) / 190 * 100).clamp(12, 90).round(),
      },
  ];
}

/// El precio: el de Ticketmaster si lo da el organizador.
String _price(CityEvent e) {
  if (e.kind == EventKind.holiday) {
    return e.regional
        ? 'Festivo solo en parte del país'
        : 'Festivo: algunas tiendas y museos pueden cerrar';
  }
  final double? p = e.priceMin;
  final String? cur = e.currency;
  if (p == null || cur == null) return 'Precio en Ticketmaster';
  final String money = NumberFormat.simpleCurrency(
    locale: 'es',
    name: cur,
    decimalDigits: p == p.roundToDouble() ? 0 : 2,
  ).format(p);
  return 'Entradas desde $money en Ticketmaster';
}

(String, String) _status(CityEvent e) => e.kind == EventKind.holiday
    ? ('FESTIVO', '#3DDC97')
    : switch (e.status) {
        SaleStatus.onsale => ('A LA VENTA', '#6CA8FF'),
        SaleStatus.offsale => ('SIN VENTA AHORA', '#FFD27A'),
        SaleStatus.cancelled => ('CANCELADO', '#FF6B6B'),
        SaleStatus.rescheduled => ('CAMBIO DE FECHA', '#FF8A65'),
        null => ('EVENTO', '#B69CFF'),
      };

/// Todo lo que necesita la página. [startOf] da la hora a la que empieza
/// cada evento (hora de la ciudad); sin ella, a las 00:00 de ese día.
Map<String, Object?> eventsPageData({
  required String? iata,
  required DateTime from,
  required DateTime to,
  CityEvents? found,
  bool loading = false,
  bool offline = false,
  bool failed = false,
  Set<String> saved = const <String>{},
  Set<String> planned = const <String>{},
  GeoPoint? hotel,
  DateTime? Function(CityEvent e)? startOf,
  String? tip,
}) {
  final List<CityEvent> all = found?.events ?? const <CityEvent>[];
  final List<DateTime> days = <DateTime>[
    for (
      DateTime d = DateTime(from.year, from.month, from.day);
      !d.isAfter(to);
      d = DateTime(d.year, d.month, d.day + 1)
    )
      d,
  ].take(maxEventDays).toList();
  final String city = found?.city ?? '';
  final List<String> sources = found?.sources ?? const <String>[];
  return <String, Object?>{
    'key': '$iata|${dayKey(from)}|${dayKey(to)}|${found == null}',
    'sub': iata == null
        ? 'Toca aquí para elegir la ciudad'
        : '${city.isEmpty ? iata : city} · ${rangeText(from, to)}'
              '${hotel != null ? ' · cerca de tu hotel' : ''}',
    'src': sources.contains('Ticketmaster')
        ? 'TICKETMASTER'
        : sources.isNotEmpty
        ? 'FESTIVOS OFICIALES'
        : '',
    'days': <Map<String, Object?>>[
      for (final DateTime d in days)
        <String, Object?>{
          'k': dayKey(d),
          'n': d.day,
          'dow': _dows[d.weekday - 1],
        },
    ],
    'events': <Map<String, Object?>>[
      for (final CityEvent e in all)
        () {
          final (String stTxt, String stCol) = _status(e);
          final DateTime start =
              startOf?.call(e) ??
              DateTime(e.date.year, e.date.month, e.date.day);
          final String? near = hotel != null && e.lat != null && e.lon != null
              ? fromHotelText(hotel.distanceTo(GeoPoint(e.lat!, e.lon!)))
              : null;
          return <String, Object?>{
            'id': e.id,
            'dk': dayKey(e.date),
            'dow': _dows[e.date.weekday - 1],
            'day': e.date.day,
            'cat': eventCat(e.kind),
            'ik': eventIcon(e.kind),
            'name': e.name,
            'when': <String>[
              '${_weekdays[e.date.weekday - 1]} ${e.date.day}',
              ?e.time,
              ?e.venue,
              ?near,
            ].join(' · '),
            'price': _price(e),
            'free': e.kind == EventKind.holiday,
            'src': e.kind == EventKind.holiday
                ? 'Festivo oficial'
                : 'Ticketmaster',
            'stTxt': stTxt,
            'stCol': stCol,
            'start': start.millisecondsSinceEpoch,
            'url': e.url?.toString() ?? '',
          };
        }(),
    ],
    'pins': eventPins(all, hotel),
    'hotel': hotel != null,
    'saved': saved.toList()..sort(),
    'planned': planned.toList()..sort(),
    'emptyTxt': iata == null
        ? 'Elige la ciudad (toca arriba, debajo del título) para ver los festivos y eventos de tus fechas.'
        : loading || (found == null && !offline && !failed)
        ? 'Buscando lo que pasa en tus fechas…'
        : offline
        ? 'Sin internet. Prueba cuando tengas conexión.'
        : failed
        ? 'Ahora no se pueden cargar los eventos. Prueba en un minuto.'
        : 'No hay festivos ni eventos publicados en estas fechas. Toca arriba para cambiarlas.',
    'tip': tip ?? 'Mandad a «Elegid planes» lo que os apetezca: si coincidís, ¡match viajero!',
  };
}

/// La página lista para enseñar.
String eventsPageWith(String page, Map<String, Object?> data) =>
    // "<" como <: ningún dato puede cerrar el script.
    page.replaceFirst(
      eventsMarker,
      jsonEncode(data).replaceAll('<', r'\u003c'),
    );

/// Lo que se le manda a la página sin recargarla.
String eventsPushScript(Map<String, Object?> data) =>
    'window.ECLin&&window.ECLin(${jsonEncode(data).replaceAll('<', r'\u003c')})';
