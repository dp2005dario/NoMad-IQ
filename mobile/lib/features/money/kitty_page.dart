// Lo que la app le da a la página del Bote común (la maqueta "Bote común",
// en assets/money/bote.html): el bote del grupo (quién ha puesto, cuánto
// queda y en qué se ha gastado) y el modo pareja (quién pagó qué y cómo
// repartís).
//
// La página cuenta en unidades enteras de la moneda (como la maqueta: "254
// €"); aquí se pasa de céntimos a unidades. Dart puro: se prueba sin
// WebView.
import 'dart:convert';

import '../../core/money.dart';
import 'expenses_api.dart';

/// Dónde está la página y la marca donde la app mete sus datos.
const String kittyPage = 'assets/money/bote.html';
const String kittyMarker = '/*ECLIPTA*/{}';

/// Los repartos de pareja de la maqueta (tu parte en %): mitad, según
/// sueldo 60/40 y lo que toma cada uno 55/45.
const List<int> coupleSplits = <int>[50, 60, 55];

const List<String> _months = <String>[
  'ene',
  'feb',
  'mar',
  'abr',
  'may',
  'jun',
  'jul',
  'ago',
  'sep',
  'oct',
  'nov',
  'dic',
];

/// "Hoy", "Ayer" o "12 oct".
String dayText(DateTime day, DateTime now) {
  final DateTime d = DateTime(day.year, day.month, day.day);
  final int diff = DateTime(now.year, now.month, now.day).difference(d).inDays;
  if (diff == 0) return 'Hoy';
  if (diff == 1) return 'Ayer';
  return '${day.day} ${_months[day.month - 1]}';
}

/// El dibujo de cada gasto (el mismo orden que en la página): comida,
/// bebida, transporte, ocio, compras, alojamiento, salud, regalo, otros.
int categoryOf(String name) {
  final String n = name.toLowerCase();
  bool any(List<String> w) => w.any(n.contains);
  if (any(<String>['hotel', 'apart', 'albergue', 'hostal', 'tasa'])) return 5;
  if (any(<String>[
    'taxi',
    'tranv',
    'tuk',
    'metro',
    'tren',
    'bus',
    'gasolin',
    'uber',
  ])) {
    return 2;
  }
  if (any(<String>['museo', 'entrada', 'excursi', 'concierto', 'coliseo'])) {
    return 3;
  }
  if (any(<String>[
    'café',
    'cafe',
    'caña',
    'copa',
    'cerveza',
    'vino',
    'agua',
  ])) {
    return 1;
  }
  if (any(<String>[
    'súper',
    'super',
    'cena',
    'comida',
    'helado',
    'pizza',
    'desayuno',
    'restaurante',
    'tapas',
  ])) {
    return 0;
  }
  if (any(<String>['farmacia', 'médico', 'medico', 'seguro'])) return 6;
  if (any(<String>['regalo', 'flores'])) return 7;
  if (any(<String>['recuerdo', 'ropa', 'tienda', 'mercado'])) return 4;
  return 8;
}

/// El símbolo que se ve junto a los importes.
String currencySign(String currency) => switch (currency) {
  'EUR' => '€',
  'USD' => r'$',
  'GBP' => '£',
  'JPY' => '¥',
  _ => currency,
};

String _initial(String name) {
  final String n = name.trim();
  return n.isEmpty ? '?' : String.fromCharCodes(n.runes.take(1)).toUpperCase();
}

String _name(ExpenseMember m) => m.me ? 'Tú' : m.name;

/// El bote del grupo que se enseña: el primero con hucha, o el primero de
/// más de dos personas.
ExpenseGroupSummary? groupPotOf(List<ExpenseGroupSummary> pots) {
  for (final ExpenseGroupSummary p in pots) {
    if (p.members > 2) return p;
  }
  return pots.firstOrNull;
}

/// El bote de pareja: el primero de dos personas.
ExpenseGroupSummary? couplePotOf(List<ExpenseGroupSummary> pots) {
  for (final ExpenseGroupSummary p in pots) {
    if (p.members == 2) return p;
  }
  return null;
}

/// Tu parte en el reparto de pareja (50, 60 o 55) según el bote.
int coupleSplitIndex(ExpenseGroup pot) {
  final int? mine = pot.defaultWeights[pot.mySeat];
  if (mine == null || pot.defaultWeights.isEmpty) return 0;
  final int total = pot.defaultWeights.values.fold(0, (int a, int b) => a + b);
  final int pct = total == 0 ? 50 : (mine * 100 / total).round();
  final int i = coupleSplits.indexOf(pct);
  return i < 0 ? 0 : i;
}

/// El bote del grupo para la página.
Map<String, Object?> potJson(ExpenseGroup pot, DateTime now) {
  int whole(int minor) => minorToWhole(minor, pot.currency);
  final Kitty? k = pot.kitty;
  final int? ask = k?.askMinor;
  // Tú entre los cuatro primeros (la maqueta enseña cuatro caras).
  final List<ExpenseMember> people = <ExpenseMember>[...pot.members];
  final int me = people.indexWhere((ExpenseMember m) => m.me);
  if (me >= 4) people.insert(3, people.removeAt(me));
  final int put = k?.putMinor ?? 0;
  final int n = pot.members.length;
  return <String, Object?>{
    'name': pot.title,
    'head':
        'BOTE ${pot.title.toUpperCase()} · $n ${n == 1 ? 'PERSONA' : 'PERSONAS'}',
    'goal': whole(ask != null ? ask * n : put),
    'ask': ask == null ? null : whole(ask),
    'people': <Map<String, Object?>>[
      for (final ExpenseMember m in people)
        <String, Object?>{
          'seat': m.seat,
          'name': _name(m),
          'ini': _initial(_name(m)),
          'put': whole(k?.contributed[m.seat] ?? 0),
          'me': m.me,
        },
    ],
    'spends': <Map<String, Object?>>[
      for (final Expense e in pot.expenses)
        if (e.fromKitty)
          <String, Object?>{
            'id': e.id,
            'name': e.title,
            'meta':
                '${dayText(e.spentOn, now)} · apuntado por ${e.createdBy == pot.mySeat ? 'ti' : pot.nameOf(e.createdBy)} · ${e.items.isEmpty ? 'a mano' : 'ticket'}',
            'amt': whole(e.amountMinor),
            'cat': categoryOf(e.title),
          },
    ],
  };
}

/// El bote de pareja para la página.
Map<String, Object?> coupleJson(ExpenseGroup pot, DateTime now) {
  int whole(int minor) => minorToWhole(minor, pot.currency);
  final ExpenseMember me = pot.members.firstWhere((ExpenseMember m) => m.me);
  final ExpenseMember other = pot.members.firstWhere(
    (ExpenseMember m) => !m.me,
    orElse: () => me,
  );
  return <String, Object?>{
    'place': pot.title,
    'me': <String, String>{'ini': _initial(me.name), 'name': 'Tú'},
    'ot': <String, String>{'ini': _initial(other.name), 'name': other.name},
    'split': coupleSplitIndex(pot),
    'items': <Map<String, Object?>>[
      for (final Expense e in pot.expenses)
        <String, Object?>{
          'id': e.id,
          'name': e.title,
          'meta':
              '${dayText(e.spentOn, now)} · ${e.items.isEmpty ? 'a mano' : 'ticket'}',
          'amt': whole(e.amountMinor),
          'mine': e.payerSeat == pot.mySeat,
          'cat': categoryOf(e.title),
        },
      // Lo que os habéis enviado para saldar.
      for (final Payment p in pot.payments)
        if (p.fromSeat != kittySeat && p.toSeat != kittySeat)
          <String, Object?>{
            'name': '',
            'meta': 'Apuntado por la app',
            'amt': whole(p.amountMinor),
            'mine': p.fromSeat == pot.mySeat,
            'settle': true,
            'cat': 8,
          },
    ],
  };
}

/// Todo lo que necesita la página.
Map<String, Object?> kittyPageData({
  required DateTime now,
  ExpenseGroup? pot,
  ExpenseGroup? couple,
  bool loading = false,
  bool signedOut = false,
  bool failed = false,
  bool startCouple = false,
}) {
  final String why = signedOut
      ? 'Entra con tu cuenta para usar el bote común.'
      : failed
      ? 'No he podido traer tus botes. Comprueba la conexión y vuelve a entrar.'
      : loading
      ? 'Buscando tus botes…'
      : '';
  return <String, Object?>{
    'cur': currencySign((pot ?? couple)?.currency ?? 'EUR'),
    'tab': startCouple ? 'couple' : 'pot',
    'pot': pot == null ? null : potJson(pot, now),
    'potNote': why.isNotEmpty ? why : 'Aún no tienes ningún bote. Créalo en Gastos con tu grupo y aquí veréis lo que pone cada uno y en qué se gasta.',
    'couple': couple == null ? null : coupleJson(couple, now),
    'coupleNote': why.isNotEmpty
        ? why
        : 'Para el modo pareja, cread en Gastos un bote solo para los dos.',
  };
}

/// La página lista para enseñar.
String kittyPageWith(String page, Map<String, Object?> data) =>
    page.replaceFirst(kittyMarker, jsonEncode(data).replaceAll('<', r'\u003c'));

/// Lo que se le manda a la página sin recargarla.
String kittyPushScript(Map<String, Object?> data) =>
    'window.ECLin&&window.ECLin(${jsonEncode(data).replaceAll('<', r'\u003c')})';
