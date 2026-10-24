// Perfiles de familia (maqueta "Familia"): quién viaja, su edad, lo que
// necesita (alergias, salud, silla de coche...) y lo que le gusta. Con eso
// la app da consejos para que el viaje sirva a todos, y Flyra puede planear
// un día pensando en cada uno.
//
// Las alergias y la salud son datos delicados: se guardan CIFRADOS y solo en
// este móvil (en el Keystore de Android, la misma caja fuerte que la sesión).
import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Lo que alguien necesita en un viaje (elegido de una lista: así la app
/// sabe qué consejo dar, cosa que con texto libre no podría).
enum Need {
  walksLittle, // camina poco (rodilla, edad...)
  carSeat, // silla de coche (niños pequeños)
  stroller, // carrito de bebé
  medication, // medicación a horas fijas
}

/// Lo que le gusta (sirve para que Flyra proponga planes).
enum Like {
  museums,
  food,
  photography,
  animals,
  music,
  beach,
  nature,
  shopping,
}

class FamilyMember {
  const FamilyMember({
    required this.name,
    this.age,
    this.allergies = const <String>[],
    this.needs = const <Need>{},
    this.likes = const <Like>{},
  });

  final String name;
  final int? age;

  /// Texto libre ("frutos secos", "gluten").
  final List<String> allergies;
  final Set<Need> needs;
  final Set<Like> likes;

  bool get isChild => age != null && age! < 12;
  bool get isSenior => age != null && age! >= 65;

  Map<String, Object?> toJson() => <String, Object?>{
    'name': name,
    'age': ?age,
    'allergies': allergies,
    'needs': <String>[for (final Need n in needs) n.name],
    'likes': <String>[for (final Like l in likes) l.name],
  };

  static FamilyMember? parse(Object? json) {
    if (json is! Map<String, Object?>) return null;
    final Object? name = json['name'];
    if (name is! String || name.trim().isEmpty || name.length > 40) {
      return null;
    }
    final Object? age = json['age'];
    List<String> strings(Object? v) => <String>[
      if (v is List<Object?>)
        for (final Object? s in v)
          if (s is String && s.trim().isNotEmpty) s.trim(),
    ];
    return FamilyMember(
      name: name.trim(),
      age: age is int && age >= 0 && age <= 120 ? age : null,
      allergies: strings(json['allergies']).take(10).toList(),
      needs: <Need>{
        for (final String n in strings(json['needs']))
          ?Need.values.asNameMap()[n],
      },
      likes: <Like>{
        for (final String l in strings(json['likes']))
          ?Like.values.asNameMap()[l],
      },
    );
  }
}

/// Convierte "Frutos secos, gluten ," en ["Frutos secos", "gluten"].
List<String> splitAllergies(String text) => <String>[
  for (final String s in text.split(','))
    if (s.trim().isNotEmpty) s.trim(),
];

/// Un consejo para el viaje y para quién es.
enum TipKind { allergy, walk, carSeat, stroller, medication, kids, seniors }

class FamilyTip {
  const FamilyTip(this.kind, this.who);

  final TipKind kind;

  /// Los nombres de las personas por las que sale el consejo.
  final List<String> who;
}

/// Los consejos que salen de la familia (sin repetir: si dos personas
/// necesitan lo mismo, sale una vez con los dos nombres).
List<FamilyTip> tipsFor(List<FamilyMember> family) {
  List<String> who(bool Function(FamilyMember) test) => <String>[
    for (final FamilyMember m in family)
      if (test(m)) m.name,
  ];
  final List<(TipKind, List<String>)> all = <(TipKind, List<String>)>[
    (TipKind.allergy, who((FamilyMember m) => m.allergies.isNotEmpty)),
    (TipKind.walk, who((FamilyMember m) => m.needs.contains(Need.walksLittle))),
    (TipKind.carSeat, who((FamilyMember m) => m.needs.contains(Need.carSeat))),
    (
      TipKind.stroller,
      who((FamilyMember m) => m.needs.contains(Need.stroller)),
    ),
    (
      TipKind.medication,
      who((FamilyMember m) => m.needs.contains(Need.medication)),
    ),
    (TipKind.kids, who((FamilyMember m) => m.isChild)),
    (TipKind.seniors, who((FamilyMember m) => m.isSenior)),
  ];
  return <FamilyTip>[
    for (final (TipKind kind, List<String> names) in all)
      if (names.isNotEmpty) FamilyTip(kind, names),
  ];
}

/// Dónde se guarda la familia. Es una interfaz para poder usar una versión
/// en memoria en los tests.
abstract interface class FamilyStore {
  Future<List<FamilyMember>> load();
  Future<void> save(List<FamilyMember> family);
}

/// Como mucho 12 personas: una familia grande cabe de sobra.
const int maxFamily = 12;

List<FamilyMember> _decode(String? raw) {
  if (raw == null) return <FamilyMember>[];
  try {
    final Object? list = jsonDecode(raw);
    if (list is! List<Object?>) return <FamilyMember>[];
    return <FamilyMember>[for (final Object? j in list) ?FamilyMember.parse(j)]
        .take(maxFamily)
        .toList();
  } on FormatException {
    return <FamilyMember>[];
  }
}

String? _encode(List<FamilyMember> family) => family.isEmpty
    ? null
    : jsonEncode(<Object?>[
        for (final FamilyMember m in family.take(maxFamily)) m.toJson(),
      ]);

/// La de verdad: cifrada en el Keystore del móvil.
final class SecureFamilyStore implements FamilyStore {
  SecureFamilyStore([FlutterSecureStorage? storage])
    : _storage =
          storage ??
          const FlutterSecureStorage(
            aOptions: AndroidOptions(resetOnError: true),
            iOptions: IOSOptions(
              accessibility: KeychainAccessibility.first_unlock_this_device,
            ),
          );

  static const String _key = 'family_profiles';
  final FlutterSecureStorage _storage;

  @override
  Future<List<FamilyMember>> load() async =>
      _decode(await _storage.read(key: _key));

  @override
  Future<void> save(List<FamilyMember> family) async {
    final String? raw = _encode(family);
    if (raw == null) {
      await _storage.delete(key: _key);
    } else {
      await _storage.write(key: _key, value: raw);
    }
  }
}

/// Para los tests (y como reserva): en memoria.
final class MemoryFamilyStore implements FamilyStore {
  String? raw;

  @override
  Future<List<FamilyMember>> load() async => _decode(raw);

  @override
  Future<void> save(List<FamilyMember> family) async => raw = _encode(family);
}
