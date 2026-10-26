// Las llamadas de Grupo al ai-orchestrator (a través de la puerta de entrada):
//   GET  /v1/group-negotiations                 → mis viajes en grupo
//   POST /v1/group-negotiations                 → crear uno (con código de invitación)
//   POST /v1/group-negotiations/join            → entrar con el código de un amigo
//   GET  /v1/group-negotiations/{id}            → cómo va (y el resultado al final)
//   PUT  /v1/group-negotiations/{id}/preferences→ mis preferencias PRIVADAS
//   POST /v1/group-negotiations/{id}/start      → "Empezar" (solo el organizador)
//
// Cómo funciona la negociación, en una frase: cada viajero tiene un agente de
// IA que defiende sus gustos y su presupuesto (que nadie más ve) y negocia con
// los de los demás hasta encontrar un plan que todos acepten. Si no lo hay, un
// árbitro con reglas fijas elige la opción que deja mejor a quien queda peor.
//
// Igual que en Vuelos, aquí se revisa TODO lo que llega del servidor: si algo
// no tiene la forma esperada, mejor un error claro que una pantalla rota.
import '../../core/api_client.dart';

const String _base = '/v1/group-negotiations';

/// Los gustos que se pueden marcar. Son palabras fijas (en inglés, como
/// "identificadores") y la app enseña cada una traducida. Que sean fijas no
/// es por capricho: el servidor solo admite minúsculas y guiones en las
/// etiquetas, y así nadie puede colar instrucciones para la IA en ellas.
const List<String> tripTags = <String>[
  'beach',
  'museums',
  'nightlife',
  'mountains',
  'food',
  'nature',
  'history',
  'shopping',
  'relax',
  'adventure',
  'sport',
  'romantic',
  'kids',
  'early-starts',
  'long-walks',
  'crowds',
];

/// Idiomas en los que los agentes saben escribir sus argumentos. Con otro
/// idioma en el móvil se les pide en inglés (los textos de la app siguen en
/// el idioma de cada uno: solo cambian las frases de los agentes).
const Set<String> agentLanguages = <String>{'es', 'en', 'fr', 'de', 'it', 'pt'};

/// Límites del servidor (negotiation/domain.py): mejor avisar antes de enviar.
const int minOptions = 2;
const int maxOptions = 10;
const int maxMembers = 8;
const int maxTags = 10;
const int maxNotes = 280;
const int maxName = 40;

enum TripStatus {
  collecting, // esperando las preferencias de todos
  queued, // en cola: enseguida empiezan a negociar
  running, // los agentes están negociando
  concluded, // hay resultado
  expired; // se acabó el plazo sin gente suficiente

  bool get working => this == queued || this == running;
  bool get finished => this == concluded || this == expired;
}

enum TripOutcome {
  consensus, // todos aceptan la misma opción
  arbitration, // no hubo acuerdo: decidió el árbitro
  noFeasibleOption, // ninguna opción cabe en el presupuesto de todos
}

class TripOption {
  const TripOption({
    required this.id,
    required this.label,
    required this.priceMinor,
    this.tags = const <String>[],
  });

  final String id;
  final String label;

  /// Precio por persona en unidades mínimas de la divisa del viaje.
  final int priceMinor;
  final List<String> tags;

  Map<String, Object?> toJson() => <String, Object?>{
    'option_id': id,
    'label': label,
    'price_minor': priceMinor,
    'tags': tags,
  };

  static TripOption parse(Object? json) {
    final Map<String, Object?> m = _map(json);
    final Object? price = m['price_minor'];
    if (price is! int || price <= 0) _bad();
    return TripOption(
      id: _str(m['option_id']),
      label: _str(m['label']),
      priceMinor: price,
      tags: _strings(m['tags']),
    );
  }
}

class TripMember {
  const TripMember({
    required this.alias,
    required this.submitted,
    required this.me,
    this.name,
    this.photoUrl,
  });

  /// Foto de perfil del miembro, si su perfil la trae.
  final String? photoUrl;

  /// "Viajero 2": lo único que ve la IA.
  final String alias;

  /// El nombre que eligió para su grupo ("Noelia"), si puso uno.
  final String? name;
  final bool submitted;
  final bool me;

  static TripMember parse(Object? json) {
    final Map<String, Object?> m = _map(json);
    final Object? submitted = m['submitted'];
    final Object? me = m['me'];
    final Object? name = m['name'];
    if (submitted is! bool || me is! bool) _bad();
    if (name != null && name is! String) _bad();
    return TripMember(
      alias: _str(m['alias']),
      name: name as String?,
      photoUrl: m['photo_url'] is String ? m['photo_url'] as String : null,
      submitted: submitted,
      me: me,
    );
  }
}

/// Lo que cada uno cuenta a SU agente. Nadie más del grupo lo ve y el
/// servidor lo borra al terminar la negociación.
class TripPreferences {
  const TripPreferences({
    required this.budgetMinor,
    this.interests = const <String>[],
    this.avoid = const <String>[],
    this.notes = '',
  });

  /// Lo máximo que pagarías por persona. Es una línea roja: ningún agente
  /// puede aceptar algo más caro.
  final int budgetMinor;
  final List<String> interests;
  final List<String> avoid;
  final String notes;

  Map<String, Object?> toJson() => <String, Object?>{
    'budget_max_minor': budgetMinor,
    'interests': interests,
    'avoid': avoid,
    'notes': notes,
  };

  static TripPreferences parse(Object? json) {
    final Map<String, Object?> m = _map(json);
    final Object? budget = m['budget_max_minor'];
    final Object notes = m['notes'] ?? '';
    if (budget is! int || budget <= 0 || notes is! String) _bad();
    return TripPreferences(
      budgetMinor: budget,
      interests: _strings(m['interests']),
      avoid: _strings(m['avoid']),
      notes: notes,
    );
  }
}

/// Cómo quedó cada agente al final.
class MemberOutcome {
  const MemberOutcome({
    required this.alias,
    required this.argument,
    required this.byAi,
    this.chosenRank,
  });

  final String alias;

  /// Lo que dijo su agente, en una frase (en el idioma de la negociación).
  final String argument;

  /// true si lo decidió la IA; false si fue el plan B con reglas.
  final bool byAi;

  /// Qué puesto ocupaba la opción elegida en SU lista (1 = su favorita).
  final int? chosenRank;

  static MemberOutcome parse(Object? json) {
    final Map<String, Object?> m = _map(json);
    final Object? rank = m['chosen_rank'];
    final Object argument = m['argument'] ?? '';
    final Object? source = m['source'];
    if ((rank != null && rank is! int) ||
        argument is! String ||
        (source != 'llm' && source != 'rules')) {
      _bad();
    }
    return MemberOutcome(
      alias: _str(m['alias']),
      argument: argument,
      byAi: source == 'llm',
      chosenRank: rank as int?,
    );
  }
}

class TripResult {
  const TripResult({
    required this.outcome,
    required this.rounds,
    required this.excludedOverBudget,
    required this.members,
    this.chosenOptionId,
  });

  final TripOutcome outcome;
  final String? chosenOptionId;
  final int rounds;

  /// Cuántas opciones se cayeron por pasarse del presupuesto de ALGUIEN (no
  /// se dice de quién: el presupuesto de cada uno es privado).
  final int excludedOverBudget;
  final List<MemberOutcome> members;

  static TripResult parse(Object? json) {
    final Map<String, Object?> m = _map(json);
    final TripOutcome? outcome = switch (m['outcome']) {
      'consensus' => TripOutcome.consensus,
      'arbitration' => TripOutcome.arbitration,
      'no_feasible_option' => TripOutcome.noFeasibleOption,
      _ => null,
    };
    final Object? rounds = m['rounds'];
    final Object? chosen = m['chosen_option_id'];
    final Object? members = m['members'];
    if (outcome == null ||
        rounds is! int ||
        rounds < 0 ||
        (chosen != null && chosen is! String) ||
        members is! List<Object?>) {
      _bad();
    }
    return TripResult(
      outcome: outcome,
      chosenOptionId: chosen as String?,
      rounds: rounds,
      excludedOverBudget: _strings(m['excluded_over_budget']).length,
      members: members.map(MemberOutcome.parse).toList(),
    );
  }
}

/// Un viaje en grupo tal y como lo ve ESTA persona.
class GroupTrip {
  const GroupTrip({
    required this.id,
    required this.title,
    required this.status,
    required this.currency,
    required this.options,
    required this.deadline,
    required this.members,
    required this.myAlias,
    required this.iOrganize,
    this.inviteCode,
    this.myPreferences,
    this.result,
  });

  final String id;
  final String title;
  final TripStatus status;
  final String currency;
  final List<TripOption> options;

  /// Hasta cuándo se esperan las preferencias de todos.
  final DateTime deadline;
  final List<TripMember> members;
  final String myAlias;
  final bool iOrganize;

  /// El código para invitar ("7K2M9QXD"), mientras el grupo admite gente.
  final String? inviteCode;
  final TripPreferences? myPreferences;
  final TripResult? result;

  int get ready => members.where((TripMember m) => m.submitted).length;
  TripMember? get me {
    for (final TripMember m in members) {
      if (m.me) return m;
    }
    return null;
  }

  TripOption? option(String? id) {
    for (final TripOption o in options) {
      if (o.id == id) return o;
    }
    return null;
  }

  /// Nombre para enseñar de un alias: el que eligió esa persona, o su alias.
  String nameOf(String alias) {
    for (final TripMember m in members) {
      if (m.alias == alias) return m.name ?? alias;
    }
    return alias;
  }

  static GroupTrip parse(Object? json) {
    final Map<String, Object?> m = _map(json);
    final TripStatus? status = TripStatus.values.asNameMap()[m['status']];
    final DateTime? deadline = DateTime.tryParse(_str(m['deadline']));
    final Object? options = m['options'];
    final Object? members = m['members'];
    final Object? organize = m['i_organize'];
    final Object? code = m['invite_code'];
    final String currency = _str(m['currency']);
    if (status == null ||
        deadline == null ||
        options is! List<Object?> ||
        members is! List<Object?> ||
        organize is! bool ||
        (code != null && code is! String) ||
        !RegExp(r'^[A-Z]{3}$').hasMatch(currency)) {
      _bad();
    }
    final Object? prefs = m['my_preferences'];
    final Object? result = m['result'];
    return GroupTrip(
      id: _str(m['negotiation_id']),
      title: _str(m['title']),
      status: status,
      currency: currency,
      options: options.map(TripOption.parse).toList(),
      deadline: deadline.toLocal(),
      members: members.map(TripMember.parse).toList(),
      myAlias: _str(m['my_alias']),
      iOrganize: organize,
      inviteCode: code as String?,
      myPreferences: prefs == null ? null : TripPreferences.parse(prefs),
      result: result == null ? null : TripResult.parse(result),
    );
  }
}

/// Lo que escribe el organizador al crear el viaje.
class NewTrip {
  const NewTrip({
    required this.title,
    required this.currency,
    required this.language,
    required this.options,
    this.myName,
  });

  final String title;
  final String currency;
  final String language;
  final List<TripOption> options;
  final String? myName;
}

/// "7K2M9QXD" → "7K2M-9QXD" (más fácil de leer y de dictar).
String formatInviteCode(String code) =>
    code.length == 8 ? '${code.substring(0, 4)}-${code.substring(4)}' : code;

class GroupApi {
  const GroupApi(this._api);

  final ApiClient _api;

  Future<List<GroupTrip>> list() async {
    final Map<String, Object?> body = _map(await _api.getJson(_base));
    final Object? items = body['items'];
    if (items is! List<Object?>) _bad();
    return items.map(GroupTrip.parse).toList();
  }

  Future<GroupTrip> get(String id) async =>
      GroupTrip.parse(await _api.getJson('$_base/${Uri.encodeComponent(id)}'));

  Future<GroupTrip> create(NewTrip trip) async => GroupTrip.parse(
    await _api.postJson(_base, <String, Object?>{
      'title': trip.title,
      'currency': trip.currency,
      'language': agentLanguages.contains(trip.language) ? trip.language : 'en',
      'options': trip.options.map((TripOption o) => o.toJson()).toList(),
      // Sin miembros: los demás entran con el código de invitación.
      'members': <String>[],
      if (trip.myName != null) 'my_name': trip.myName,
    }),
  );

  Future<GroupTrip> join(String code, {String? myName}) async =>
      GroupTrip.parse(
        await _api.postJson('$_base/join', <String, Object?>{
          'code': code,
          'my_name': ?myName,
        }),
      );

  Future<GroupTrip> sendPreferences(String id, TripPreferences prefs) async =>
      GroupTrip.parse(
        await _api.putJson(
          '$_base/${Uri.encodeComponent(id)}/preferences',
          prefs.toJson(),
        ),
      );

  Future<GroupTrip> start(String id) async => GroupTrip.parse(
    await _api.postJson(
      '$_base/${Uri.encodeComponent(id)}/start',
      const <String, Object?>{},
    ),
  );
}

Map<String, Object?> _map(Object? json) =>
    json is Map<String, Object?> ? json : _bad();

String _str(Object? value) =>
    value is String && value.isNotEmpty && value.length <= 200 ? value : _bad();

List<String> _strings(Object? value) {
  if (value == null) return const <String>[];
  if (value is! List<Object?>) _bad();
  return <String>[for (final Object? v in value) _str(v)];
}

Never _bad() => throw const ApiException(ApiError.unavailable);
