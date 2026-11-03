// "Elegid planes" (maqueta "Planes"): el grupo de un viaje vota planes
// deslizando tarjetas y los que gustan a todos son un match.
//
//   GET    /v1/group-negotiations/{id}/plans               el tablero
//   POST   /v1/group-negotiations/{id}/plans               añadir planes
//   PUT    /v1/group-negotiations/{id}/plans/{plan}/vote   votar sí o no
//   DELETE /v1/group-negotiations/{id}/plans/{plan}        quitar uno mío
//
// Todas devuelven el tablero entero. Del resto del grupo solo llega cuántos
// han votado y cuántos sí: nunca quién votó qué.
import '../../core/api_client.dart';

/// Topes del servidor (plans/domain.py): mejor avisar antes de enviar.
const int maxPlanTitle = 80;
const int maxPlanNote = 140;
const int maxPlansPerAdd = 10;

class GroupPlan {
  const GroupPlan({
    required this.id,
    required this.title,
    required this.mine,
    required this.yes,
    required this.voted,
    required this.match,
    this.note,
    this.wikidataId,
    this.photoUrl,
    this.articleUrl,
    this.myVote,
    this.matchWith = const <String>[],
    this.planned = false,
  });

  final String id;
  final String title;

  /// "Esta noche · 21:30 · ≈ 25 €/persona".
  final String? note;
  final String? wikidataId;
  final Uri? photoUrl;
  final Uri? articleUrl;

  /// Lo propuse yo (solo así lo puedo quitar).
  final bool mine;

  /// null = aún no lo he votado.
  final bool? myVote;
  final int yes;
  final int voted;
  final bool match;

  /// Con quién coincides ("Marta", "Álex"). Solo llega si tú dijiste que sí
  /// y hay match: los votos son secretos hasta que coincidís.
  final List<String> matchWith;

  /// Ya está metido en el plan del grupo.
  final bool planned;

  /// Es un "match viajero" mío: coincido con alguien.
  bool get myMatch => match && myVote == true && matchWith.isNotEmpty;

  static GroupPlan? parse(Object? json) {
    if (json is! Map<String, Object?>) return null;
    final Object? id = json['plan_id'];
    final Object? title = json['title'];
    final Object? yes = json['yes'];
    final Object? voted = json['voted'];
    if (id is! String || title is! String || yes is! int || voted is! int) {
      return null;
    }
    String? text(String key) {
      final Object? v = json[key];
      return v is String && v.isNotEmpty ? v : null;
    }

    // Solo enlaces de Wikimedia (el servidor ya lo exige; aquí, por si acaso).
    Uri? wiki(String key, String hostEnd) {
      final Uri? u = Uri.tryParse(text(key) ?? '');
      return u != null && u.scheme == 'https' && u.host.endsWith(hostEnd)
          ? u
          : null;
    }

    final Object? myVote = json['my_vote'];
    return GroupPlan(
      id: id,
      title: title,
      note: text('note'),
      wikidataId: text('wikidata_id'),
      photoUrl: wiki('photo_url', 'wikimedia.org'),
      articleUrl: wiki('article_url', 'wikipedia.org'),
      mine: json['mine'] == true,
      myVote: myVote is bool ? myVote : null,
      yes: yes,
      voted: voted,
      match: json['match'] == true,
      matchWith: switch (json['match_with']) {
        final List<Object?> l => <String>[
          for (final Object? n in l) ?(n is String && n.isNotEmpty ? n : null),
        ],
        _ => const <String>[],
      },
      planned: json['planned'] == true,
    );
  }
}

/// Una persona del viaje (las caras de arriba).
class PlanPerson {
  const PlanPerson({required this.name, required this.me, required this.voted});

  final String name;
  final bool me;

  /// Ya ha votado algún plan ("ya votó"); si no, "sin entrar".
  final bool voted;

  static PlanPerson? parse(Object? json) {
    if (json is! Map<String, Object?>) return null;
    final Object? name = json['name'];
    if (name is! String || name.isEmpty) return null;
    return PlanPerson(
      name: name,
      me: json['me'] == true,
      voted: json['voted'] == true,
    );
  }
}

class PlanBoard {
  const PlanBoard({
    required this.members,
    required this.plans,
    this.people = const <PlanPerson>[],
  });

  /// Cuántas personas cuentan para el match.
  final int members;
  final List<GroupPlan> plans;
  final List<PlanPerson> people;

  /// Los que me faltan por votar.
  List<GroupPlan> get pending =>
      plans.where((GroupPlan p) => p.myVote == null).toList();
  List<GroupPlan> get matches => plans.where((GroupPlan p) => p.match).toList();

  static PlanBoard parse(Object? json) {
    if (json is! Map<String, Object?>) {
      throw const ApiException(ApiError.unavailable);
    }
    final Object? members = json['members'];
    final Object? plans = json['plans'];
    if (members is! int || plans is! List<Object?>) {
      throw const ApiException(ApiError.unavailable);
    }
    return PlanBoard(
      members: members,
      plans: <GroupPlan>[for (final Object? p in plans) ?GroupPlan.parse(p)],
      people: switch (json['people']) {
        final List<Object?> l => <PlanPerson>[
          for (final Object? p in l) ?PlanPerson.parse(p),
        ],
        _ => const <PlanPerson>[],
      },
    );
  }
}

/// Un plan nuevo: uno tuyo o una atracción de la ficha de la ciudad.
class NewPlan {
  const NewPlan({
    required this.title,
    this.note,
    this.wikidataId,
    this.photoUrl,
    this.articleUrl,
  });

  final String title;
  final String? note;
  final String? wikidataId;
  final Uri? photoUrl;
  final Uri? articleUrl;

  Map<String, Object?> toJson() => <String, Object?>{
    'title': title.length > maxPlanTitle
        ? title.substring(0, maxPlanTitle)
        : title,
    if (note != null)
      'note': note!.length > maxPlanNote
          ? '${note!.substring(0, maxPlanNote - 1)}…'
          : note,
    'wikidata_id': ?wikidataId,
    'photo_url': ?photoUrl?.toString(),
    'article_url': ?articleUrl?.toString(),
  };
}

class PlansApi {
  const PlansApi(this._api);

  final ApiClient _api;

  String _base(String tripId) =>
      '/v1/group-negotiations/${Uri.encodeComponent(tripId)}/plans';

  Future<PlanBoard> board(String tripId) async =>
      PlanBoard.parse(await _api.getJson(_base(tripId)));

  Future<PlanBoard> add(String tripId, List<NewPlan> plans) async =>
      PlanBoard.parse(
        await _api.postJson(_base(tripId), <String, Object?>{
          'plans': <Object?>[
            for (final NewPlan p in plans.take(maxPlansPerAdd)) p.toJson(),
          ],
        }),
      );

  Future<PlanBoard> vote(String tripId, String planId, {required bool yes}) =>
      _api
          .putJson(
            '${_base(tripId)}/${Uri.encodeComponent(planId)}/vote',
            <String, Object?>{'yes': yes},
          )
          .then(PlanBoard.parse);

  /// "Añadir al plan": mete un match en el plan del grupo.
  Future<PlanBoard> addToPlan(String tripId, String planId) => _api
      .putJson(
        '${_base(tripId)}/${Uri.encodeComponent(planId)}/planned',
        const <String, Object?>{},
      )
      .then(PlanBoard.parse);

  Future<PlanBoard> remove(String tripId, String planId) => _api
      .delete('${_base(tripId)}/${Uri.encodeComponent(planId)}')
      .then(PlanBoard.parse);
}
