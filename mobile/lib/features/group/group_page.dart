// Lo que la app le da a la página de Grupo (la maqueta "Viaje en grupo", en
// assets/group/grupo.html) cuando el viaje ya tiene destino: quiénes vais,
// los gustos de cada uno, las zonas para dormir con vuestros votos, los
// eventos de esos días, los sitios cerca y el plan del grupo.
//
// La página va en español (como la maqueta). Todo sale de datos de verdad;
// si algo no se encuentra, se dice con una frase en vez de inventarlo.
// Dart puro: se prueba sin WebView.

import 'dart:convert';
import 'dart:math' as math;

import '../../core/money.dart';
import '../events/events_api.dart';
import '../map/geo.dart';
import '../money/expenses_api.dart';
import '../plans/plans_api.dart';
import '../stays/stays_api.dart';
import 'cravings_api.dart';
import 'group_api.dart';

/// Dónde está la página y la marca donde la app mete sus datos.
const String groupPage = 'assets/group/grupo.html';
const String groupMarker = '/*ECLIPTA*/{}';

/// Los gustos que enseña la maqueta, en su orden y con su nombre.
const List<(String, String)> pageTastes = <(String, String)>[
  ('tapas', 'Tapas'),
  ('music', 'Música en directo'),
  ('beach', 'Playa'),
  ('museums', 'Museos'),
  ('views', 'Con vistas'),
  ('fish', 'Pescado'),
  ('veggie', 'Vegetariano'),
  ('late', 'Sin madrugar'),
];

/// Los colores de las caras, los de la maqueta (y luego más).
const List<String> faceColors = <String>[
  '#B69CFF',
  '#FF8A65',
  '#6CA8FF',
  '#FFB86B',
  '#3DDC97',
  '#FF7EB6',
  '#7FE0E6',
  '#E6D86B',
];

/// El nombre que se ve de cada uno: "Tú", el que eligió o su alias.
String pageName(TripMember m) => m.me ? 'Tú' : (m.name ?? m.alias);

/// La letra de su cara (la tuya, la de tu nombre si lo pusiste).
String pageInitial(TripMember m) {
  final String n = (m.name ?? m.alias).trim();
  // La primera letra entera (también si es una tilde o un emoji sencillo).
  return n.isEmpty ? '?' : String.fromCharCodes(n.runes.take(1)).toUpperCase();
}

String _tasteName(String id) {
  for (final (String k, String v) in pageTastes) {
    if (k == id) return v;
  }
  return id;
}

/// El gusto de cada antojo (para "Encaja con Marta").
String? _tasteOf(Craving c) => switch (c) {
  Craving.tapas => 'tapas',
  Craving.fish => 'fish',
  Craving.veggie => 'veggie',
  Craving.views => 'views',
  Craving.cafe => null,
};

const List<String> _weekdays = <String>[
  'LUN',
  'MAR',
  'MIÉ',
  'JUE',
  'VIE',
  'SÁB',
  'DOM',
];

String _kindName(EventKind k) => switch (k) {
  EventKind.holiday => 'Festivo',
  EventKind.music => 'Música',
  EventKind.sports => 'Deporte',
  EventKind.arts => 'Arte y teatro',
  EventKind.family => 'En familia',
  EventKind.festival => 'Fiesta famosa',
  EventKind.other => 'Evento',
};

String _two(int n) => n.toString().padLeft(2, '0');

/// El título de una zona para dormir (el mismo que se vota en el tablero).
String zoneTitle(StayZone z, String city) => z.name ?? 'Junto a $city';

/// Dónde cae un sitio en el mapa de la maqueta (en %): el centro es donde
/// estás tú o el centro de la ciudad; el borde, a 1 km.
(int, int) spotOnMap(GeoPoint center, GeoPoint at) {
  final double east =
      (at.lon - center.lon) * 111320 * math.cos(center.lat * math.pi / 180);
  final double north = (at.lat - center.lat) * 110540;
  final int x = (50 + east / cravingRadiusM * 40).round().clamp(12, 88);
  final int y = (55 - north / cravingRadiusM * 35).round().clamp(15, 85);
  return (x, y);
}

GroupPlan? findPlan(PlanBoard? board, PlanKind kind, String title) {
  if (board == null) return null;
  final String key = title.toLowerCase();
  for (final GroupPlan p in board.extras) {
    if (p.kind == kind && p.title.toLowerCase() == key) return p;
  }
  return null;
}

/// Todo lo que necesita la página.
Map<String, Object?> groupPageData({
  required GroupTrip trip,
  required String city,
  required Craving crave,
  List<StayZone>? zones,
  bool zonesFailed = false,
  bool noCity = false,
  PlanBoard? board,
  List<CravingSpot>? spots,
  bool spotsFailed = false,
  GeoPoint? center,
  DateTime? golden,
  String? iata,
  List<CityEvent>? events,
  bool eventsFailed = false,
  String debt = '',
}) {
  final List<TripMember> people = trip.members;
  final int n = people.length;
  final int total = math.max(1, board?.members ?? n);
  final String noCityText =
      'No encuentro «$city» en el mapa: sin datos de zonas ni de sitios cerca.';

  // El aviso de Flyra: cómo acabó la negociación.
  final (String, String) flyra = switch (trip.result?.outcome) {
    TripOutcome.arbitration => (
      'He elegido $city por el grupo',
      'No os poníais de acuerdo y he decidido yo. Mira abajo cómo lo he buscado y vota.',
    ),
    TripOutcome.noFeasibleOption => (
      'Ninguna opción cabe en todos los presupuestos',
      'Mira abajo lo que he encontrado y votad entre vosotros.',
    ),
    _ => (
      n == 1 ? '¡Tu viaje está listo!' : '¡Tengo un acuerdo para los $n!',
      'He cruzado lo que quiere cada uno. Mira abajo cómo lo he buscado y vota.',
    ),
  };

  // Las zonas (las dos primeras son las que se votan).
  final List<StayZone> zs = zones ?? const <StayZone>[];
  final String zonesProblem = noCity
      ? noCityText
      : zonesFailed
      ? 'No he podido traer las zonas para dormir. Vuelve a abrir el viaje.'
      : zones == null
      ? 'Buscando barrios con alojamientos en OpenStreetMap…'
      : zs.isEmpty
      ? 'No he encontrado zonas con alojamientos en OpenStreetMap.'
      : '';
  String detail(StayZone z) =>
      '${z.minutes} min ${z.by == StayBy.walk ? 'andando' : 'en tren'} · '
      '${z.lodgings} ${z.lodgings == 1 ? 'alojamiento' : 'alojamientos'}';

  // Los eventos de las próximas dos semanas.
  final List<CityEvent> evs = events ?? const <CityEvent>[];
  final String eventsNote = iata == null
      ? (noCity
            ? noCityText
            : 'Sin aeropuerto cerca de $city: sin eventos de Ticketmaster.')
      : eventsFailed
      ? 'No he podido traer los eventos de Ticketmaster.'
      : events == null
      ? 'Buscando eventos en Ticketmaster…'
      : evs.isEmpty
      ? 'Ticketmaster no tiene eventos en $city las próximas dos semanas.'
      : 'Eventos reales de Ticketmaster en $city las próximas dos semanas.';

  // Los sitios cerca, con quién encajan y vuestros votos.
  final String? taste = _tasteOf(crave);
  final List<String> fans = <String>[
    if (taste != null)
      for (final TripMember m in people)
        if (m.tastes.contains(taste)) pageName(m),
  ];
  final List<CravingSpot> sp = spots ?? const <CravingSpot>[];
  final String spotsNote = noCity
      ? noCityText
      : spotsFailed
      ? 'No he podido traer los sitios cerca. Elige otro antojo o vuelve luego.'
      : spots == null || center == null
      ? 'Buscando sitios a un paseo en OpenStreetMap…'
      : sp.isEmpty
      ? 'No hay sitios así a un paseo en OpenStreetMap.'
      : '';

  // El plan del grupo: lo metido en el plan o, si no, los matches.
  final List<GroupPlan> planned = <GroupPlan>[
    for (final GroupPlan p in board?.plans ?? const <GroupPlan>[])
      if (p.planned) p,
  ];
  final List<GroupPlan> days = planned.isNotEmpty
      ? planned
      : (board?.matches ?? const <GroupPlan>[]);

  return <String, Object?>{
    'title': city,
    'sub': n == 1 ? '1 viajero' : '$n viajeros',
    'people': <Map<String, Object?>>[
      for (int i = 0; i < n; i++)
        <String, Object?>{
          'i': pageInitial(people[i]),
          'name': pageName(people[i]),
          'c': faceColors[i % faceColors.length],
          'me': people[i].me,
          'on': people[i].submitted,
          'tastes': people[i].tastes,
        },
    ],
    'tastes': <List<String>>[
      for (final (String id, String label) in pageTastes) <String>[id, label],
    ],
    'flyraTitle': flyra.$1,
    'flyraText': flyra.$2,
    'wants': <String>[
      for (final TripMember m in people)
        if (m.tastes.isNotEmpty)
          '${pageName(m)}: ${_tasteName(m.tastes.first)}',
    ],
    'zones': <Map<String, String>>[
      for (final StayZone z in zs.take(3))
        <String, String>{
          'name': z.name ?? 'Centro',
          'title': zoneTitle(z, city),
          'detail': detail(z),
        },
    ],
    'zoneNote': zonesProblem.isNotEmpty
        ? zonesProblem
        : 'Barrios y distancias con OpenStreetMap. Primera opción: '
              '${zoneTitle(zs.first, city)}.',
    'filters': <String>[
      if (zs.isNotEmpty) zs.first.name ?? city else city,
      n == 1 ? '1 persona' : '$n personas',
    ],
    'events': <Map<String, String>>[
      for (final CityEvent e in evs.take(3))
        <String, String>{
          'day': '${_weekdays[e.date.weekday - 1]} ${e.date.day}',
          't': e.name,
          'd': e.venue ?? _kindName(e.kind),
        },
    ],
    'eventsNote': eventsNote,
    'proposal': zs.isEmpty
        ? 'Aún sin zonas'
        : zs.take(2).length == 1
        ? 'Te propongo 1 zona'
        : 'Te propongo 2 zonas',
    'options': <Map<String, Object?>>[
      for (final StayZone z in zs.take(2))
        () {
          final GroupPlan? p = findPlan(
            board,
            PlanKind.sleep,
            zoneTitle(z, city),
          );
          return <String, Object?>{
            'title': zoneTitle(z, city),
            'detail': detail(z),
            'yes': p?.yes ?? 0,
            'mine': p?.myVote ?? false,
          };
        }(),
    ],
    'total': total,
    'optionsNote': zonesProblem,
    'crave': Craving.values.indexOf(crave),
    'spots': <Map<String, Object?>>[
      if (center != null)
        for (final CravingSpot s in sp.take(3))
          () {
            final GroupPlan? p = findPlan(board, PlanKind.crave, s.name);
            final (int x, int y) = spotOnMap(center, s.point);
            return <String, Object?>{
              't': s.name,
              'walk': '${walkMinutes(center.distanceTo(s.point))} min a pie',
              'why': fans.isNotEmpty
                  ? 'Encaja con ${fans.join(', ')}'
                  : s.openingHours != null
                  ? 'Horario: ${s.openingHours}'
                  : (s.cuisine ?? 'A un paseo'),
              'yes': p?.yes ?? 0,
              'mine': p?.myVote,
              'x': x,
              'y': y,
            };
          }(),
    ],
    'spotsNote': spotsNote,
    'golden': golden == null
        ? ''
        : 'Hora dorada hoy sobre las ${_two(golden.toLocal().hour)}:'
              '${_two(golden.toLocal().minute)} (estimada por la posición del '
              'sol): buen momento para un mirador.',
    'days': <String>[for (final GroupPlan p in days.take(3)) p.title],
    // Los gastos van unidos al viaje: lo que debes (o te deben) en su bote.
    'debt': debt,
  };
}

/// La fila "Gastos del grupo": "Debes 12,50 €", "Te deben 8 €" o nada si
/// estáis en paz.
String potDebt(ExpenseGroup pot, String locale) {
  final int mine = pot.balances[pot.mySeat] ?? 0;
  if (mine == 0) return '';
  final String amount = formatMoney(
    mine.abs(),
    pot.currency,
    locale,
    compact: true,
  );
  return mine < 0 ? 'Debes $amount' : 'Te deben $amount';
}

/// La página lista para enseñar.
String groupPageWith(String page, Map<String, Object?> data) =>
    // "<" como \u003c: ningún dato puede cerrar el script.
    page.replaceFirst(groupMarker, jsonEncode(data).replaceAll('<', r'\u003c'));

/// Lo que se le manda a la página sin recargarla.
String groupPushScript(Map<String, Object?> data) =>
    'window.ECLin&&window.ECLin(${jsonEncode(data).replaceAll('<', r'\u003c')})';
