// Lo que la app le da a la página "Tu dinero fuera" (la maqueta "Dinero",
// en assets/money/dinero.html): los cajeros de verdad que tienes cerca
// (OpenStreetMap) y los gastos de tu viaje (tu parte de cada gasto del bote
// que elegiste, tu límite y tus fechas).
//
// La página cuenta en unidades enteras de la moneda (como la maqueta: "790
// €"); aquí se pasa de céntimos a unidades. Dart puro: se prueba sin
// WebView.
import 'dart:convert';
import 'dart:math' as math;

import '../../core/money.dart';
import '../map/geo.dart';
import 'atms_api.dart';
import 'expenses_api.dart';
import 'kitty_page.dart' show categoryOf, currencySign, dayText;
import 'trip_budget.dart';

/// Dónde está la página y la marca donde la app mete sus datos.
const String abroadPage = 'assets/money/dinero.html';
const String abroadMarker = '/*ECLIPTA*/{}';

/// Las siglas y los colores de los bancos que dibuja la maqueta (y algunos
/// más). Los demás: sus tres primeras letras y un color de la lista.
const Map<String, (String, String, String)> _banks =
    <String, (String, String, String)>{
      'bbva': ('BBVA', '#1973B8', '#072146'),
      'santander': ('SAN', '#FF3B30', '#B00000'),
      'caixa': ('CX', '#3FA9F5', '#00609C'),
      'sabadell': ('SAB', '#33B4F0', '#0062A8'),
      'euronet': ('EUR', '#FFD34D', '#C7900E'),
      'bankinter': ('BKT', '#FF8A3D', '#D9531E'),
      'ing': ('ING', '#FF8A3D', '#D9531E'),
      'unicaja': ('UNI', '#3DDC97', '#0F6A45'),
      'ibercaja': ('IBC', '#6CA8FF', '#14305A'),
      'kutxa': ('KTX', '#FF3B30', '#7A1010'),
      'abanca': ('ABN', '#33B4F0', '#0062A8'),
      'cajamar': ('CJM', '#3DDC97', '#0F6A45'),
      'deutsche': ('DB', '#1973B8', '#072146'),
    };

const List<(String, String)> _otherColors = <(String, String)>[
  ('#B69CFF', '#2A1A5A'),
  ('#FF8FB1', '#6A1A3A'),
  ('#6CA8FF', '#14305A'),
  ('#3DDC97', '#0F3A2A'),
  ('#FFB86B', '#7A3A10'),
];

/// Siglas y colores del cajero (por su banco).
(String, String, String) atmBadge(Atm a) {
  final String label = (a.operator ?? a.name ?? '').trim();
  final String low = label.toLowerCase();
  for (final MapEntry<String, (String, String, String)> e in _banks.entries) {
    if (RegExp('\\b${e.key}').hasMatch(low)) return e.value;
  }
  // La primera palabra que no sea "cajero" ni "banco".
  final String word = low
      .split(RegExp(r'[^a-záéíóúüñ0-9]+'))
      .firstWhere(
        (String w) =>
            w.length > 1 && !<String>{'cajero', 'banco', 'atm'}.contains(w),
        orElse: () => '',
      );
  final (String c1, String c2) =
      _otherColors[label.runes.fold(0, (int s, int r) => s + r) %
          _otherColors.length];
  if (word.isEmpty) return ('ATM', c1, c2);
  return (String.fromCharCodes(word.runes.take(3)).toUpperCase(), c1, c2);
}

/// "Cajero BBVA" (o lo que ponga en el mapa).
String atmName(Atm a) {
  final String? label = a.name ?? a.operator;
  if (label == null) return 'Cajero automático';
  return label.toLowerCase().startsWith('cajero') ? label : 'Cajero $label';
}

/// "150 m" o "1,2 km".
String distanceText(double meters) => meters < 1000
    ? '${(meters / 10).round() * 10} m'
    : '${(meters / 1000).toStringAsFixed(1).replaceAll('.', ',')} km';

/// Dónde cae cada cajero en el dibujo del mapa (358 × 210, tú en el centro):
/// 1 px = 4 m; si dos se pisan, el segundo se aparta un poco.
List<(int, int)> pinSpots(GeoPoint me, List<Atm> atms) {
  final List<(int, int)> out = <(int, int)>[];
  for (final Atm a in atms) {
    final double east =
        (a.point.lon - me.lon) * 111320 * math.cos(me.lat * math.pi / 180);
    final double north = (a.point.lat - me.lat) * 110540;
    int x = (180 + east / 4 - 19).round();
    int y = (112 - north / 4 - 19).round();
    for (int tries = 0; tries < 8; tries++) {
      x = x.clamp(6, 314);
      // Ni encima del contador (arriba) ni del botón del mapa (abajo).
      y = y.clamp(40, x > 220 ? 106 : 148);
      final (int, int) here = (x, y);
      if (out.every(
        ((int, int) o) =>
            (o.$1 - here.$1).abs() >= 40 || (o.$2 - here.$2).abs() >= 58,
      )) {
        break;
      }
      x += x > 180 ? -42 : 42;
      if (tries.isOdd) y += 30;
    }
    out.add((x, y));
  }
  return out;
}

/// Los cajeros para la página (el más cercano arriba).
List<Map<String, Object?>> atmsJson(
  GeoPoint me,
  List<Atm> sorted,
  String currency,
) {
  final List<Atm> shown = sorted.take(6).toList();
  final List<(int, int)> spots = pinSpots(me, shown);
  final String sign = currencySign(currency);
  return <Map<String, Object?>>[
    for (int i = 0; i < shown.length; i++)
      () {
        final Atm a = shown[i];
        final (String short, String c1, String c2) = atmBadge(a);
        final int k = a.fee == false
            ? 0
            : a.fee == null
            ? 1
            : 2;
        final String hours = a.open24h
            ? 'abierto 24 h'
            : a.openingHours != null
            ? a.openingHours!
            : a.inBank
            ? 'dentro de un banco'
            : '';
        return <String, Object?>{
          'name': atmName(a),
          'meta': <String>[
            distanceText(a.point.distanceTo(me)),
            if (hours.isNotEmpty) hours,
          ].join(' · '),
          'fee': switch (k) {
            0 => '0 $sign',
            1 => 'Sin datos',
            _ => 'Con comisión',
          },
          'pin': switch (k) {
            0 => '0 $sign',
            1 => '?',
            _ => 'Cobra',
          },
          'k': k,
          'short': short,
          'c1': c1,
          'c2': c2,
          'x': spots[i].$1,
          'y': spots[i].$2,
        };
      }(),
  ];
}

const List<String> _monthNames = <String>[
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

/// "del 1 al 9 de noviembre" / "del 28 de octubre al 3 de noviembre".
String rangeText(DateTime a, DateTime b) => a.month == b.month
    ? 'del ${a.day} al ${b.day} de ${_monthNames[b.month - 1]}'
    : 'del ${a.day} de ${_monthNames[a.month - 1]} al ${b.day} de '
          '${_monthNames[b.month - 1]}';

String _currencyWord(String c) => switch (c) {
  'EUR' => 'EUROS',
  'USD' => 'DÓLARES',
  'GBP' => 'LIBRAS',
  'JPY' => 'YENES',
  'CHF' => 'FRANCOS',
  'MXN' => 'PESOS',
  _ => c,
};

/// Los tipos de gasto de las fotos (Comida, Transporte, Ocio, Compras)
/// según el dibujo de cada gasto (ver categoryOf).
int? photoCategory(int cat) => switch (cat) {
  0 || 1 => 0,
  2 => 1,
  3 => 2,
  4 => 3,
  _ => null,
};

/// Tu viaje para la página: tu parte de cada gasto del bote.
Map<String, Object?> tripJson(
  TripBudget budget,
  ExpenseGroup pot,
  DateTime now,
) {
  int whole(int minor) => minorToWhole(minor, pot.currency);
  final BudgetForecast f = forecast(budget, pot, now);
  final List<int> daily = <int>[
    for (int i = 0; i < f.cumulative.length; i++)
      whole(f.cumulative[i] - (i == 0 ? 0 : f.cumulative[i - 1])),
  ];
  final int spent = whole(f.spentMinor);
  final int limit = whole(budget.limitMinor);
  final int left = f.days - f.day;
  final int allowed = math.max(0, (limit - spent) ~/ (left + 1));
  final List<int> cats = <int>[0, 0, 0, 0];
  final List<Expense> mine = <Expense>[
    for (final Expense e in pot.expenses)
      if ((e.shares[pot.mySeat] ?? 0) > 0) e,
  ];
  for (final Expense e in mine) {
    final int? c = photoCategory(categoryOf(e.title));
    if (c != null) cats[c] += e.shares[pot.mySeat]!;
  }
  // Lo último arriba.
  final List<Expense> recent = mine.reversed.toList()
    ..sort((Expense a, Expense b) => b.spentOn.compareTo(a.spentOn));
  final DateTime today = DateTime(now.year, now.month, now.day);
  return <String, Object?>{
    'title': pot.title,
    'name': '${pot.title} · ${rangeText(budget.start, budget.end)}',
    'src':
        'Tu parte de los gastos del bote «${pot.title}», con tus fechas y tu '
        'límite. Moneda: ${pot.currency}.',
    'head':
        '${pot.title.toUpperCase()} · DÍA ${f.day} DE ${f.days} · EN '
        '${_currencyWord(pot.currency)}',
    'limit': limit,
    'spent': spent,
    'day': f.day,
    'days': f.days,
    'daily': daily,
    'cats': <int>[for (final int c in cats) whole(c)],
    'recent': <Map<String, Object?>>[
      for (int i = 0; i < math.min(4, recent.length); i++)
        <String, Object?>{
          'name': recent[i].title,
          'meta':
              '${dayText(recent[i].spentOn, now)} · '
              '${recent[i].items.isEmpty ? 'apuntado a mano' : 'leído del ticket'}',
          'amt': whole(recent[i].shares[pot.mySeat]!),
          'cat': categoryOf(recent[i].title),
          'isNew':
              i == 0 &&
              !DateTime(
                recent[i].spentOn.year,
                recent[i].spentOn.month,
                recent[i].spentOn.day,
              ).isBefore(today),
        },
    ],
    // Flyra avisa si hoy ya vas por encima de lo que puedes gastar al día.
    'flyToday':
        f.day <= f.days &&
        daily.isNotEmpty &&
        daily.last > allowed &&
        !today.isAfter(budget.end),
  };
}

/// Qué pasa con los cajeros.
enum AtmPhase { idle, searching, noLocation, failed, done }

/// Todo lo que necesita la página.
Map<String, Object?> abroadPageData({
  required DateTime now,
  String tab = 'atm',
  AtmPhase atmPhase = AtmPhase.idle,
  GeoPoint? me,
  List<Atm>? atms,
  bool atmsCached = false,
  List<ExpenseGroupSummary>? pots,
  TripBudget? budget,
  ExpenseGroup? pot,
  bool signedOut = false,
  bool failed = false,
}) {
  final String currency = pot?.currency ?? 'EUR';
  final List<Atm> found = atms ?? const <Atm>[];
  final bool hasTrip = budget != null && pot != null;
  final String atmNote = switch (atmPhase) {
    AtmPhase.idle =>
      'Para ver los cajeros que tienes cerca necesito tu ubicación.',
    AtmPhase.searching => 'Buscando cajeros cerca de ti…',
    AtmPhase.noLocation =>
      'No sé dónde estás. Activa la ubicación para ver los cajeros cerca.',
    AtmPhase.failed => 'No he podido traer los cajeros. Comprueba la conexión y vuelve a probar.',
    AtmPhase.done when found.isEmpty =>
      'No hay cajeros en OpenStreetMap a menos de 1 km.',
    AtmPhase.done when atmsCached =>
      'Sin conexión: son los cajeros que guardé de esta zona.',
    AtmPhase.done => '',
  };
  return <String, Object?>{
    'cur': currencySign(currency),
    'tab': tab,
    'atms': me == null ? const <Object?>[] : atmsJson(me, found, currency),
    'atmCount': me == null
        ? 0
        : found.where((Atm a) => a.point.distanceTo(me) <= 1000).length,
    'atmNote': atmNote,
    'atmBtn': switch (atmPhase) {
      AtmPhase.idle || AtmPhase.noLocation => 'Usar mi ubicación',
      AtmPhase.failed => 'Reintentar',
      AtmPhase.done when atmsCached => 'Reintentar',
      _ => '',
    },
    'trip': hasTrip ? tripJson(budget, pot, now) : null,
    'trips': <Map<String, Object?>>[
      for (final ExpenseGroupSummary p in pots ?? const <ExpenseGroupSummary>[])
        <String, Object?>{
          'title': p.title,
          'sub': hasTrip && p.id == budget.potId
              ? 'En curso · ${rangeText(budget.start, budget.end)}'
              : '${p.members} ${p.members == 1 ? 'persona' : 'personas'} · '
                    '${p.currency}',
          'on': hasTrip && p.id == budget.potId,
        },
    ],
    'tripNote': signedOut
        ? 'Entra con tu cuenta para contar los gastos de tu viaje.'
        : failed
        ? 'No he podido traer tus gastos. Comprueba la conexión y vuelve a entrar.'
        : pots == null
        ? 'Buscando tu viaje…'
        : pots.isEmpty
        ? 'Para contar tus gastos necesito saber adónde vas y cuándo. Crea '
              'antes un bote en Gastos y aquí le pones tus fechas y tu límite.'
        : 'Para contar tus gastos necesito saber adónde vas y cuándo. Elige '
              'el bote de tu viaje y pon tus fechas y tu límite.',
  };
}

/// La página lista para enseñar.
String abroadPageWith(String page, Map<String, Object?> data) =>
    // "<" como <: ningún dato puede cerrar el script.
    page.replaceFirst(
      abroadMarker,
      jsonEncode(data).replaceAll('<', r'\u003c'),
    );

/// Lo que se le manda a la página sin recargarla.
String abroadPushScript(Map<String, Object?> data) =>
    'window.ECLin&&window.ECLin(${jsonEncode(data).replaceAll('<', r'\u003c')})';
