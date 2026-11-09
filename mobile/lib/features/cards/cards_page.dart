// Lo que la app le da a la página de Cromos (la maqueta "Cromos con
// amigos", en assets/cards/cromos.html): los cambios que puedes hacer, la
// clasificación de tu liga y dónde están tus amigos (solo quien lo
// comparte, y nunca más exacto que la ciudad).
//
// La página va en español (como la maqueta). Dart puro: se prueba sin
// WebView.
import 'dart:convert';

import '../camera/stamps.dart';
import '../passport/passport.dart';
import 'league_api.dart';

/// Dónde está la página y la marca donde la app mete sus datos.
const String cardsPage = 'assets/cards/cromos.html';
const String cardsMarker = '/*ECLIPTA*/{}';

const List<String> _months = <String>[
  'ENERO',
  'FEBRERO',
  'MARZO',
  'ABRIL',
  'MAYO',
  'JUNIO',
  'JULIO',
  'AGOSTO',
  'SEPTIEMBRE',
  'OCTUBRE',
  'NOVIEMBRE',
  'DICIEMBRE',
];

/// Cuánto vale cada cromo (los mismos puntos que el servidor).
int _points(int? year) => switch (rarityOf(year)) {
  Rarity.legendary => 150,
  Rarity.epic => 80,
  Rarity.rare => 40,
  Rarity.common => 10,
};

String _rarityName(int? year) => switch (rarityOf(year)) {
  Rarity.legendary => 'LEGENDARIA',
  Rarity.epic => 'ÉPICA',
  Rarity.rare => 'RARA',
  Rarity.common => 'COMÚN',
};

/// "1.720": los miles con punto, como en la maqueta.
String thousands(int n) =>
    n.toString().replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (_) => '.');

/// "Hace 5 min" / "hace 3 h" / "hace 2 días".
String _ago(DateTime? at, DateTime now) {
  if (at == null) return '';
  final Duration d = now.difference(at);
  if (d.inMinutes < 1) return 'ahora';
  if (d.inMinutes < 60) return 'hace ${d.inMinutes} min';
  if (d.inHours < 24) return 'hace ${d.inHours} h';
  return d.inDays == 1 ? 'hace 1 día' : 'hace ${d.inDays} días';
}

String _initial(String name) {
  final String n = name.trim();
  return n.isEmpty ? '?' : String.fromCharCodes(n.runes.take(1)).toUpperCase();
}

/// Un cambio que se puede enseñar en "Cambiar".
enum SwapKind {
  /// Te lo ofrece un amigo: aceptar (con 30 s para deshacer) o no.
  incoming,

  /// Se lo propusiste tú: esperando respuesta.
  outgoing,

  /// Uno que puedes proponer: un cromo suyo que te falta por uno tuyo.
  proposal,

  /// Aún no hay nada que cambiar: invitar a la liga.
  invite,

  /// Aún no estás en ninguna liga.
  join,
}

/// Un cambio de la pestaña "Cambiar" (lo que se ve y lo que hace el botón).
class SwapItem {
  const SwapItem({
    required this.kind,
    this.swap,
    this.toSeat,
    this.give,
    this.want,
    this.who = '',
  });

  final SwapKind kind;

  /// El cambio del servidor (si es uno que ya existe).
  final LeagueSwap? swap;

  /// Para proponer: a quién, qué das y qué pides.
  final int? toSeat;
  final LeagueCard? give;
  final LeagueCard? want;
  final String who;
}

/// Los cambios que se ven, en orden: los que te ofrecen, los que esperan
/// respuesta y los que puedes proponer (uno por amigo: el cromo suyo que
/// más vale y te falta, por uno tuyo que no tenga, mejor si es repetido).
List<SwapItem> swapItems({
  required LeagueView? league,
  required List<Stamp> stamps,
  required Map<int, List<LeagueCard>> friendCards,
}) {
  if (league == null) return const <SwapItem>[SwapItem(kind: SwapKind.join)];
  final List<SwapItem> out = <SwapItem>[];
  final Set<int> waiting = <int>{};
  for (final LeagueSwap s in league.swaps) {
    if (s.status != SwapStatus.pending) continue;
    if (s.toSeat == league.mySeat) {
      out.add(
        SwapItem(
          kind: SwapKind.incoming,
          swap: s,
          give: s.want,
          want: s.give,
          who: league.nameOf(s.fromSeat),
        ),
      );
    } else if (s.fromSeat == league.mySeat) {
      waiting.add(s.toSeat);
      out.add(
        SwapItem(
          kind: SwapKind.outgoing,
          swap: s,
          give: s.give,
          want: s.want,
          who: league.nameOf(s.toSeat),
        ),
      );
    }
  }
  final Set<String> mine = <String>{
    for (final Stamp s in stamps) s.qid,
    for (final LeagueCard c in league.received) c.qid,
  };
  final Map<String, int> copies = <String, int>{};
  for (final Stamp s in stamps) {
    copies[s.qid] = (copies[s.qid] ?? 0) + 1;
  }
  for (final Standing f in league.standings) {
    if (f.me || waiting.contains(f.seat)) continue;
    final List<LeagueCard> theirs = friendCards[f.seat] ?? const <LeagueCard>[];
    final Set<String> theirQids = <String>{
      for (final LeagueCard c in theirs) c.qid,
    };
    final List<LeagueCard> wants = <LeagueCard>[
      for (final LeagueCard c in theirs)
        if (!mine.contains(c.qid)) c,
    ]..sort((LeagueCard a, LeagueCard b) => _points(b.year) - _points(a.year));
    final List<Stamp> gives = <Stamp>[
      for (final Stamp s in stamps)
        if (!theirQids.contains(s.qid)) s,
    ];
    if (wants.isEmpty || gives.isEmpty) continue;
    // Mejor uno repetido; si no, el que menos vale.
    gives.sort((Stamp a, Stamp b) {
      final int dup =
          (copies[b.qid]! > 1 ? 1 : 0) - (copies[a.qid]! > 1 ? 1 : 0);
      return dup != 0 ? dup : _points(a.year) - _points(b.year);
    });
    out.add(
      SwapItem(
        kind: SwapKind.proposal,
        toSeat: f.seat,
        give: LeagueCard.ofStamp(gives.first),
        want: wants.first,
        who: f.name,
      ),
    );
  }
  if (out.isEmpty) out.add(const SwapItem(kind: SwapKind.invite));
  return out;
}

/// Todo lo que necesita la página.
Map<String, Object?> cardsPageData({
  required LeagueView? league,
  required List<Stamp> stamps,
  required List<SwapItem> swaps,
  required Map<int, List<LeagueCard>> friendCards,
  required DateTime now,
  bool loading = false,
  String? error,
}) {
  final Map<String, int> copies = <String, int>{};
  for (final Stamp s in stamps) {
    copies[s.qid] = (copies[s.qid] ?? 0) + 1;
  }
  Map<String, String>? card(LeagueCard? c, {bool mine = false}) {
    if (c == null) return null;
    final int n = mine ? (copies[c.qid] ?? 0) : 0;
    return <String, String>{
      'name': c.name.toUpperCase(),
      'label': n > 1 ? '${_rarityName(c.year)} · x$n' : _rarityName(c.year),
      'rar': rarityOf(c.year).name,
    };
  }

  const String keep = 'Los dos os quedáis una copia: nunca pierdes un cromo.';
  final String more = swaps.length > 1 ? ' Toca un móvil para ver otro.' : '';
  final List<Map<String, Object?>> items = <Map<String, Object?>>[
    for (final SwapItem i in swaps)
      switch (i.kind) {
        SwapKind.incoming => <String, Object?>{
          'kind': 'in',
          'who': i.who.toUpperCase(),
          'mine': card(i.give, mine: true),
          'theirs': card(i.want),
          'title': 'Tu ${i.give!.name} por su ${i.want!.name}',
          'text': '${i.who} te lo propone desde la liga. $keep$more',
          'hint': '${i.who} te lo ofrece',
          'doneHint': '¡Cambio hecho! Ya tienes ${i.want!.name}',
          'button': 'Aceptar cambio',
          'alt': 'No, gracias',
        },
        SwapKind.outgoing => <String, Object?>{
          'kind': 'out',
          'who': i.who.toUpperCase(),
          'mine': card(i.give, mine: true),
          'theirs': card(i.want),
          'title': 'Tu ${i.give!.name} por su ${i.want!.name}',
          'text': 'Se lo has propuesto a ${i.who}. $keep$more',
          'hint': 'Esperando a que ${i.who} acepte',
          'button': 'Esperando respuesta',
        },
        SwapKind.proposal => <String, Object?>{
          'kind': 'new',
          'who': i.who.toUpperCase(),
          'mine': card(i.give, mine: true),
          'theirs': card(i.want),
          'title': 'Tu ${i.give!.name} por su ${i.want!.name}',
          'text':
              'A ${i.who} le falta tu cromo y tiene uno que te falta a ti. $keep$more',
          'hint': '${i.who} tiene un cromo que te falta',
          'button': 'Proponer cambio',
        },
        SwapKind.invite => <String, Object?>{
          'kind': 'invite',
          'who': 'AMIGO',
          'mine': stamps.isEmpty
              ? null
              : card(LeagueCard.ofStamp(stamps.first), mine: true),
          'theirs': null,
          'title': 'Aún no hay cambios posibles',
          'text': stamps.isEmpty
              ? 'Consigue cromos visitando monumentos con la cámara. Cuando tus amigos tengan cromos que te falten, saldrán aquí.'
              : 'Cuando alguien de tu liga tenga un cromo que te falte, saldrá aquí. Invita a más amigos con el código ${league?.inviteCode ?? ''}.',
          'hint': 'Invita a tus amigos a la liga',
          'button': 'Invitar amigos',
        },
        SwapKind.join => <String, Object?>{
          'kind': 'join',
          'who': 'AMIGO',
          'mine': stamps.isEmpty
              ? null
              : card(LeagueCard.ofStamp(stamps.first), mine: true),
          'theirs': null,
          'title': 'Aún no estás en ninguna liga',
          'text': 'Crea una con tus amigos o entra con su código. Tus cromos (monumento, año y mes) solo los ve la gente de tu liga.',
          'hint':
              error ??
              (loading
                  ? 'Buscando tus ligas…'
                  : 'Crea una liga con tus amigos'),
          'button': 'Crear una liga',
          'alt': 'Entrar con un código',
        },
      },
  ];

  // La liga: tu puesto y la clasificación del mes.
  final List<Standing> table = <Standing>[...?league?.standings]
    ..sort((Standing a, Standing b) => b.pointsMonth - a.pointsMonth);
  final int pos = table.indexWhere((Standing s) => s.me);
  final Standing? me = pos < 0 ? null : table[pos];
  final String headSub;
  if (league == null || me == null) {
    headSub = 'Crea una liga o entra con un código para competir.';
  } else if (pos > 0) {
    headSub =
        'Te faltan ${thousands(table[pos - 1].pointsMonth - me.pointsMonth)} puntos para ${table[pos - 1].name}';
  } else if (table.length > 1) {
    headSub =
        'Sacas ${thousands(me.pointsMonth - table[1].pointsMonth)} puntos a ${table[1].name}';
  } else {
    headSub = 'Invita a tus amigos con el código ${league.inviteCode}';
  }
  String meta(Standing s) => <String>[
    s.countries == 1 ? '1 país' : '${s.countries} países',
    if (s.legendary > 0)
      s.legendary == 1 ? '1 legendaria' : '${s.legendary} legendarias',
  ].join(' · ');

  // Amigos: solo los que comparten su ciudad.
  final Set<String> mine = <String>{
    for (final Stamp s in stamps) s.qid,
    for (final LeagueCard c in league?.received ?? const <LeagueCard>[]) c.qid,
  };
  final List<Map<String, String>> friends = <Map<String, String>>[
    for (final Standing s in table)
      if (!s.me && s.city != null)
        () {
          final List<LeagueCard>? theirs = friendCards[s.seat];
          final int missing = theirs == null
              ? 0
              : theirs.where((LeagueCard c) => !mine.contains(c.qid)).length;
          return <String, String>{
            'name': s.name,
            'ini': _initial(s.name),
            'where': s.city!,
            'meta': <String>[
              _ago(s.cityAt, now),
              if (missing > 0)
                missing == 1
                    ? 'tiene 1 cromo que te falta'
                    : 'tiene $missing cromos que te faltan',
            ].where((String x) => x.isNotEmpty).join(' · '),
          };
        }(),
  ];
  final String? myCity = me?.city;

  return <String, Object?>{
    'swaps': items,
    'headK': league == null
        ? 'SIN LIGA'
        : 'LIGA ${league.title.toUpperCase()} · ${_months[now.month - 1]}',
    'headPos': me == null
        ? 'Aún sin liga'
        : 'Vas ${pos + 1}.º de ${table.length}',
    'headSub': headSub,
    'league': <Map<String, Object?>>[
      for (final Standing s in table)
        <String, Object?>{
          'name': s.me ? 'Tú' : s.name,
          'ini': _initial(s.me ? 'Tú' : s.name),
          'meta': meta(s),
          'pts': thousands(s.pointsMonth),
          'me': s.me,
        },
    ],
    'pointsNote': league == null
        ? 'Puntos: cromo común 10, rara 40, épica 80, legendaria 150.'
        : 'Puntos: cromo común 10, rara 40, épica 80, legendaria 150. Toca el cartel de la liga para invitar (código ${league.inviteCode}) o cambiar de liga.',
    'friends': friends,
    'friendsNote': league == null
        ? 'Entra en una liga para ver dónde están tus amigos.'
        : 'Aún nadie de tu liga comparte su ciudad contigo.',
    'shareNote': league == null
        ? 'Solo ves a quien comparte su ciudad contigo, y nunca más exacto que la ciudad.'
        : myCity != null
        ? 'Tu liga ve que estás en $myCity (nunca más exacto que la ciudad). Toca aquí para dejar de compartirlo.'
        : 'Solo ves a quien comparte su ciudad contigo, y nunca más exacto que la ciudad. Toca aquí para compartir la tuya.',
  };
}

/// La página lista para enseñar.
String cardsPageWith(String page, Map<String, Object?> data) =>
    page.replaceFirst(cardsMarker, jsonEncode(data).replaceAll('<', r'\u003c'));

/// Lo que se le manda a la página sin recargarla. [keep] = no cambiar el
/// cambio que se está viendo.
String cardsPushScript(Map<String, Object?> data, {bool keep = true}) =>
    'window.ECLin&&window.ECLin(${jsonEncode(<String, Object?>{...data, 'keep': keep}).replaceAll('<', r'\u003c')})';
