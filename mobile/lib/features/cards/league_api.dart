// "Cromos con amigos": hablar con el servidor (/v1/leagues).
//
// Una liga es un grupo de amigos (con código, como Grupo y Gastos). Cada uno
// sube la lista de sus cromos (los sellos del Pasaporte: monumento, año y
// mes) y el servidor hace la clasificación del mes y los cambios.
import '../../core/api_client.dart';
import '../camera/stamps.dart';

/// Un cromo tal y como se comparte con la liga: sin coordenadas ni fecha
/// exacta, solo el mes (para la liga del mes).
class LeagueCard {
  const LeagueCard({
    required this.qid,
    required this.name,
    required this.month,
    this.year,
  });

  final String qid;
  final String name;
  final int? year;

  /// "2026-10".
  final String month;

  /// Un sello del Pasaporte → cromo para la liga.
  factory LeagueCard.ofStamp(Stamp s) {
    final DateTime d = s.date.toUtc();
    return LeagueCard(
      qid: s.qid,
      name: s.name.length > 80 ? s.name.substring(0, 80) : s.name,
      year: s.year,
      month:
          '${d.year.toString().padLeft(4, '0')}-'
          '${d.month.toString().padLeft(2, '0')}',
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'qid': qid,
    'name': name,
    'year': year,
    'month': month,
  };

  static LeagueCard? parse(Object? json) {
    if (json is! Map<String, Object?>) return null;
    final Object? qid = json['qid'];
    final Object? name = json['name'];
    final Object? year = json['year'];
    final Object? month = json['month'];
    if (qid is! String || name is! String || month is! String) return null;
    return LeagueCard(
      qid: qid,
      name: name,
      year: year is int ? year : null,
      month: month,
    );
  }
}

/// Una fila de la clasificación.
class Standing {
  const Standing({
    required this.seat,
    required this.name,
    required this.me,
    required this.pointsMonth,
    required this.pointsTotal,
    required this.cards,
    required this.legendary,
    required this.countries,
    this.city,
    this.cityAt,
  });

  final int seat;
  final String name;
  final bool me;
  final int pointsMonth;
  final int pointsTotal;
  final int cards;
  final int legendary;
  final int countries;

  /// La ciudad aproximada, solo si esa persona lo ha activado.
  final String? city;
  final DateTime? cityAt;

  static Standing parse(Object? json) {
    final Map<String, Object?> m = _map(json);
    final Object? city = m['city'];
    return Standing(
      seat: _int(m['seat']),
      name: _str(m['name']),
      me: m['me'] == true,
      pointsMonth: _int(m['points_month']),
      pointsTotal: _int(m['points_total']),
      cards: _int(m['cards']),
      legendary: _int(m['legendary']),
      countries: _int(m['countries']),
      city: city is String && city.isNotEmpty ? city : null,
      cityAt: DateTime.tryParse('${m['city_at']}'),
    );
  }
}

enum SwapStatus {
  pending,
  accepted,
  declined;

  static SwapStatus parse(Object? raw) => SwapStatus.values.firstWhere(
    (SwapStatus s) => s.name == raw,
    orElse: () => SwapStatus.declined,
  );
}

/// "Te doy [give] por [want]".
class LeagueSwap {
  const LeagueSwap({
    required this.id,
    required this.fromSeat,
    required this.toSeat,
    required this.give,
    required this.want,
    required this.status,
  });

  final String id;
  final int fromSeat;
  final int toSeat;
  final LeagueCard give;
  final LeagueCard want;
  final SwapStatus status;

  static LeagueSwap parse(Object? json) {
    final Map<String, Object?> m = _map(json);
    final LeagueCard? give = LeagueCard.parse(m['give']);
    final LeagueCard? want = LeagueCard.parse(m['want']);
    if (give == null || want == null) _bad();
    return LeagueSwap(
      id: _str(m['swap_id']),
      fromSeat: _int(m['from_seat']),
      toSeat: _int(m['to_seat']),
      give: give,
      want: want,
      status: SwapStatus.parse(m['status']),
    );
  }
}

class LeagueView {
  const LeagueView({
    required this.id,
    required this.title,
    required this.inviteCode,
    required this.mySeat,
    required this.standings,
    required this.swaps,
    required this.received,
  });

  final String id;
  final String title;
  final String inviteCode;
  final int mySeat;
  final List<Standing> standings;
  final List<LeagueSwap> swaps;

  /// Las copias que te han dado en cambios aceptados.
  final List<LeagueCard> received;

  Standing? get me => standings.where((Standing s) => s.me).firstOrNull;
  int get myPosition => standings.indexWhere((Standing s) => s.me) + 1;

  String nameOf(int seat) => standings
      .firstWhere(
        (Standing s) => s.seat == seat,
        orElse: () => const Standing(
          seat: 0,
          name: '—',
          me: false,
          pointsMonth: 0,
          pointsTotal: 0,
          cards: 0,
          legendary: 0,
          countries: 0,
        ),
      )
      .name;

  static LeagueView parse(Object? json) {
    final Map<String, Object?> m = _map(json);
    return LeagueView(
      id: _str(m['league_id']),
      title: _str(m['title']),
      inviteCode: _str(m['invite_code']),
      mySeat: _int(m['my_seat']),
      standings: _list(m['standings']).map(Standing.parse).toList(),
      swaps: _list(m['swaps']).map(LeagueSwap.parse).toList(),
      received: <LeagueCard>[
        for (final Object? c in _list(m['received'])) ?LeagueCard.parse(c),
      ],
    );
  }
}

class LeagueSummary {
  const LeagueSummary({
    required this.id,
    required this.title,
    required this.members,
    required this.myPosition,
  });

  final String id;
  final String title;
  final int members;
  final int myPosition;

  static LeagueSummary parse(Object? json) {
    final Map<String, Object?> m = _map(json);
    return LeagueSummary(
      id: _str(m['league_id']),
      title: _str(m['title']),
      members: _int(m['members']),
      myPosition: _int(m['my_position']),
    );
  }
}

Never _bad() => throw const ApiException(ApiError.unavailable);

Map<String, Object?> _map(Object? v) => v is Map<String, Object?> ? v : _bad();
List<Object?> _list(Object? v) => v is List<Object?> ? v : _bad();
int _int(Object? v) => v is int ? v : _bad();
String _str(Object? v) => v is String ? v : _bad();

class LeagueApi {
  const LeagueApi(this._api);

  final ApiClient _api;

  static const String _base = '/v1/leagues';

  Future<List<LeagueSummary>> list() async =>
      _list(_map(await _api.getJson(_base))['items'])
          .map(LeagueSummary.parse)
          .toList();

  Future<LeagueView> create({
    required String title,
    required String myName,
  }) async => LeagueView.parse(
    await _api.postJson(_base, <String, Object?>{
      'title': title,
      'my_name': myName,
    }),
  );

  Future<LeagueView> join(String code, {required String myName}) async =>
      LeagueView.parse(
        await _api.postJson('$_base/join', <String, Object?>{
          'code': code,
          'my_name': myName,
        }),
      );

  Future<LeagueView> get(String id) async =>
      LeagueView.parse(await _api.getJson('$_base/$id'));

  Future<List<LeagueCard>> cardsOf(String id, int seat) async => <LeagueCard>[
    for (final Object? c in _list(
      _map(await _api.getJson('$_base/$id/members/$seat/cards'))['cards'],
    ))
      ?LeagueCard.parse(c),
  ];

  /// Sube tus cromos (los del Pasaporte). Se llama al abrir la liga.
  Future<void> upload(
    String id,
    List<LeagueCard> cards, {
    required int countries,
  }) => _api.putJson('$_base/$id/me', <String, Object?>{
    'cards': <Object?>[for (final LeagueCard c in cards.take(1000)) c.toJson()],
    'countries': countries.clamp(0, 250),
  });

  /// [city] null = dejar de compartir dónde estás.
  Future<void> setCity(String id, String? city) =>
      _api.putJson('$_base/$id/me/city', <String, Object?>{'city': city});

  Future<void> propose(
    String id, {
    required int toSeat,
    required String giveQid,
    required String wantQid,
  }) => _api.postJson('$_base/$id/swaps', <String, Object?>{
    'to_seat': toSeat,
    'give_qid': giveQid,
    'want_qid': wantQid,
  });

  Future<void> decide(String id, String swapId, {required bool accept}) =>
      _api.postJson(
        '$_base/$id/swaps/$swapId/${accept ? 'accept' : 'decline'}',
        const <String, Object?>{},
      );

  Future<void> leave(String id) => _api.delete('$_base/$id/me');
}
