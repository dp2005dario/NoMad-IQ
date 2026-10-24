// Lo que el SOS guarda en el móvil: tus contactos de emergencia y tu ficha
// médica. Nada de esto se manda a ningún servidor.
import 'dart:convert';

import '../../core/settings.dart';
import '../map/geo.dart';

/// Hasta 5 contactos: a los que se avisa al pulsar SOS.
const int maxSosContacts = 5;

class SosContact {
  const SosContact({required this.name, required this.phone});

  final String name;

  /// Tal cual lo escribiste ("+34 600 11 22 33").
  final String phone;

  /// Solo dígitos y el "+" del principio (lo que entiende el teléfono).
  String get dial => phone.replaceAll(RegExp(r'[^0-9+]'), '');

  Map<String, Object?> toJson() => <String, Object?>{
    'name': name,
    'phone': phone,
  };

  static SosContact? parse(Object? json) {
    if (json is! Map<String, Object?>) return null;
    final Object? name = json['name'];
    final Object? phone = json['phone'];
    if (name is! String || phone is! String || !isPhone(phone)) return null;
    return SosContact(name: name, phone: phone);
  }

  /// Un teléfono "de verdad": entre 3 y 15 cifras (como manda la ITU), con
  /// espacios, guiones, paréntesis o un + delante.
  static bool isPhone(String raw) {
    final String t = raw.trim();
    if (!RegExp(r'^\+?[0-9 ()\-.]{3,24}$').hasMatch(t)) return false;
    final int digits = RegExp(r'[0-9]').allMatches(t).length;
    return digits >= 3 && digits <= 15;
  }
}

List<SosContact> loadContacts(SettingsStore prefs) {
  final String? raw = prefs.readData(LocalData.sosContacts);
  if (raw == null) return <SosContact>[];
  try {
    return <SosContact>[
      for (final Object? j in jsonDecode(raw) as List<Object?>)
        ?SosContact.parse(j),
    ].take(maxSosContacts).toList();
  } on Object {
    return <SosContact>[];
  }
}

Future<void> saveContacts(SettingsStore prefs, List<SosContact> contacts) =>
    prefs.writeData(
      LocalData.sosContacts,
      contacts.isEmpty
          ? null
          : jsonEncode(<Object?>[
              for (final SosContact c in contacts.take(maxSosContacts))
                c.toJson(),
            ]),
    );

/// Los grupos sanguíneos que se pueden elegir.
const List<String> bloodTypes = <String>[
  '0+',
  '0-',
  'A+',
  'A-',
  'B+',
  'B-',
  'AB+',
  'AB-',
];

/// Tu ficha médica. Todo es opcional.
class MedicalCard {
  const MedicalCard({
    this.blood,
    this.allergies = '',
    this.conditions = '',
    this.medication = '',
  });

  final String? blood;
  final String allergies;
  final String conditions;
  final String medication;

  bool get isEmpty =>
      blood == null &&
      allergies.trim().isEmpty &&
      conditions.trim().isEmpty &&
      medication.trim().isEmpty;

  /// "0+ · celíaco · alergia: penicilina" (la línea corta de la maqueta).
  String summary() => <String>[
    ?blood,
    if (conditions.trim().isNotEmpty) conditions.trim(),
    if (allergies.trim().isNotEmpty) allergies.trim(),
  ].join(' · ');

  Map<String, Object?> toJson() => <String, Object?>{
    'blood': ?blood,
    'allergies': allergies,
    'conditions': conditions,
    'medication': medication,
  };

  static MedicalCard load(SettingsStore prefs) {
    try {
      final Object? j = jsonDecode(prefs.readData(LocalData.medicalCard) ?? '');
      if (j is! Map<String, Object?>) return const MedicalCard();
      String text(String k) =>
          j[k] is String ? (j[k]! as String).characters200 : '';
      final Object? blood = j['blood'];
      return MedicalCard(
        blood: blood is String && bloodTypes.contains(blood) ? blood : null,
        allergies: text('allergies'),
        conditions: text('conditions'),
        medication: text('medication'),
      );
    } on FormatException {
      return const MedicalCard();
    }
  }

  Future<void> save(SettingsStore prefs) => prefs.writeData(
    LocalData.medicalCard,
    isEmpty ? null : jsonEncode(toJson()),
  );
}

extension on String {
  /// Corta textos enormes (un dato guardado roto no debe romper la pantalla).
  String get characters200 => length <= 200 ? this : substring(0, 200);
}

/// El mensaje que reciben tus contactos: corto (cabe en un SMS) y con un
/// enlace al mapa que se abre en cualquier móvil, sin instalar nada.
String sosMessage(String intro, GeoPoint? where) {
  if (where == null) return intro;
  final String lat = where.lat.toStringAsFixed(5);
  final String lon = where.lon.toStringAsFixed(5);
  return '$intro https://www.openstreetmap.org/?mlat=$lat&mlon=$lon#map=17/$lat/$lon';
}

/// El SMS ya escrito para todos tus contactos (tú solo pulsas "Enviar").
Uri smsUri(List<SosContact> contacts, String body) => Uri(
  scheme: 'sms',
  path: contacts.map((SosContact c) => c.dial).join(','),
  queryParameters: <String, String>{'body': body},
);

/// Llamar a un número (abre el marcador del móvil con el número puesto).
Uri telUri(String number) => Uri(scheme: 'tel', path: number);

/// Embajadas y consulados cerca, en el mapa libre de OpenStreetMap.
Uri embassiesUri(GeoPoint where) => Uri.parse(
  'https://www.openstreetmap.org/search?query=embassy'
  '#map=13/${where.lat.toStringAsFixed(4)}/${where.lon.toStringAsFixed(4)}',
);
