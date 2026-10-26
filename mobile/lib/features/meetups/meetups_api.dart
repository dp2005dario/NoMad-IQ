// Quedadas de viajeros (maqueta "Quedadas"): planes abiertos con gente que
// está en la misma ciudad ("cena de ramen hoy a las 20:00, 4 de 6 plazas").
//
//   GET    /v1/meetups?city=LIS      las de una ciudad (código de aeropuerto)
//   GET    /v1/meetups/mine          a las que vas
//   POST   /v1/meetups               proponer una
//   POST   /v1/meetups/{id}/join     unirme       DELETE .../join   ya no voy
//   DELETE /v1/meetups/{id}          cancelar la mía
//   POST   /v1/meetups/{id}/report   denunciar
//
// La ciudad va por código de aeropuerto: el servidor nunca sabe dónde estás.
import '../../core/api_client.dart';

/// Topes del servidor (meetups/api.py): mejor avisar antes de enviar.
const int maxMeetupTitle = 80;
const int maxMeetupPlace = 80;
const int maxMeetupName = 40;
const int minMeetupCapacity = 2;
const int maxMeetupCapacity = 12;
const Duration maxMeetupAhead = Duration(days: 30);

enum MeetupKind { food, walk, drinks, culture, other }

MeetupKind? _kind(Object? v) {
  for (final MeetupKind k in MeetupKind.values) {
    if (k.name == v) return k;
  }
  return null;
}

/// Alguien apuntado. [name] es null si prefirió no enseñarlo.
class MeetupPerson {
  const MeetupPerson({this.name, this.country, this.organizer = false});

  final String? name;

  /// Código de país ("ES"), si lo quiso decir.
  final String? country;
  final bool organizer;

  static MeetupPerson? parse(Object? json) {
    if (json is! Map<String, Object?>) return null;
    final Object? name = json['name'];
    final Object? country = json['country'];
    return MeetupPerson(
      name: name is String && name.isNotEmpty ? name : null,
      country: country is String && country.length == 2 ? country : null,
      organizer: json['organizer'] == true,
    );
  }
}

class Meetup {
  const Meetup({
    required this.id,
    required this.city,
    required this.kind,
    required this.title,
    required this.place,
    required this.startsAt,
    required this.capacity,
    required this.going,
    required this.people,
    required this.joined,
    required this.mine,
  });

  final String id;
  final String city;
  final MeetupKind kind;
  final String title;

  /// Un sitio público ("Praça do Comércio, junto a la estatua").
  final String place;
  final DateTime startsAt;
  final int capacity;
  final int going;
  final List<MeetupPerson> people;

  /// Voy (o la propuse yo).
  final bool joined;

  /// La propuse yo: solo así la puedo cancelar.
  final bool mine;

  bool get full => going >= capacity;

  static Meetup? parse(Object? json) {
    if (json is! Map<String, Object?>) return null;
    final Object? id = json['meetup_id'];
    final Object? city = json['city'];
    final MeetupKind? kind = _kind(json['kind']);
    final Object? title = json['title'];
    final Object? place = json['place'];
    final Object? starts = json['starts_at'];
    final Object? capacity = json['capacity'];
    final Object? going = json['going'];
    final Object? people = json['people'];
    if (id is! String ||
        city is! String ||
        kind == null ||
        title is! String ||
        place is! String ||
        starts is! String ||
        capacity is! int ||
        going is! int) {
      return null;
    }
    final DateTime? at = DateTime.tryParse(starts);
    if (at == null) return null;
    return Meetup(
      id: id,
      city: city,
      kind: kind,
      title: title,
      place: place,
      startsAt: at,
      capacity: capacity,
      going: going,
      people: <MeetupPerson>[
        if (people is List<Object?>)
          for (final Object? p in people) ?MeetupPerson.parse(p),
      ],
      joined: json['joined'] == true,
      mine: json['mine'] == true,
    );
  }
}

List<Meetup> _list(Object? json) {
  if (json is! Map<String, Object?> || json['meetups'] is! List<Object?>) {
    throw const ApiException(ApiError.unavailable);
  }
  return <Meetup>[
    for (final Object? m in json['meetups']! as List<Object?>) ?Meetup.parse(m),
  ];
}

Meetup _one(Object? json) =>
    Meetup.parse(json) ?? (throw const ApiException(ApiError.unavailable));

/// Cómo te ven los demás en una quedada (se elige cada vez).
class MeetupMe {
  const MeetupMe({required this.name, this.country, this.visible = true});

  final String name;
  final String? country;
  final bool visible;

  Map<String, Object?> toJson() => <String, Object?>{
    'name': name.length > maxMeetupName
        ? name.substring(0, maxMeetupName)
        : name,
    'country': ?country,
    'visible': visible,
  };
}

class NewMeetup {
  const NewMeetup({
    required this.city,
    required this.kind,
    required this.title,
    required this.place,
    required this.startsAt,
    required this.capacity,
  });

  final String city;
  final MeetupKind kind;
  final String title;
  final String place;
  final DateTime startsAt;
  final int capacity;

  Map<String, Object?> toJson(MeetupMe me) => <String, Object?>{
    'city': city,
    'kind': kind.name,
    'title': title,
    'place': place,
    // Siempre en UTC con zona: el servidor rechaza horas sin zona.
    'starts_at': startsAt.toUtc().toIso8601String(),
    'capacity': capacity,
    'me': me.toJson(),
  };
}

class MeetupsApi {
  const MeetupsApi(this._api);

  final ApiClient _api;

  static const String _base = '/v1/meetups';

  String _id(String id) => '$_base/${Uri.encodeComponent(id)}';

  Future<List<Meetup>> city(String iata) async =>
      _list(await _api.getJson(_base, query: <String, String>{'city': iata}));

  Future<List<Meetup>> mine() async => _list(await _api.getJson('$_base/mine'));

  Future<Meetup> create(NewMeetup draft, MeetupMe me) async =>
      _one(await _api.postJson(_base, draft.toJson(me)));

  Future<Meetup> join(String id, MeetupMe me) async => _one(
    await _api.postJson('${_id(id)}/join', <String, Object?>{
      'me': me.toJson(),
    }),
  );

  Future<Meetup> leave(String id) async =>
      _one(await _api.delete('${_id(id)}/join'));

  Future<void> cancel(String id) => _api.delete(_id(id));

  Future<void> report(String id) =>
      _api.postJson('${_id(id)}/report', const <String, Object?>{});
}
