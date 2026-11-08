// Lo que la app le da a la página de Ajustes (la maqueta "Ajustes", en
// assets/settings/ajustes.html): tu nombre, tu correo y tu ID, tu foto o tu
// avatar, los 4 interruptores, tu idioma, tu moneda y el Modo fácil.
//
// Dart puro: se prueba sin WebView.
import 'dart:convert';

import 'package:intl/intl.dart';

import '../../widgets/user_avatar.dart' show isTrustedPhotoUrl;
import 'profile_photo.dart';

/// Dónde está la página y la marca donde la app mete sus datos.
const String settingsPage = 'assets/settings/ajustes.html';
const String settingsMarker = '/*ECLIPTA*/{}';

/// El ID corto que se enseña: los 8 primeros caracteres del id de la
/// cuenta. Sirve para que soporte te encuentre sin pedirte el email.
String shortId(String id) {
  final String clean = id.replaceAll('-', '').toUpperCase();
  return clean.length <= 8 ? clean : clean.substring(0, 8);
}

/// La moneda de tu móvil ("EUR"), por su idioma y país ("es_ES").
String homeCurrency(String locale) {
  try {
    return NumberFormat.simpleCurrency(locale: locale).currencyName ?? 'EUR';
  } on Object {
    return 'EUR';
  }
}

/// "EUR · €", como en la maqueta.
String currencyLabel(String locale) {
  try {
    final NumberFormat f = NumberFormat.simpleCurrency(locale: locale);
    return '${f.currencyName ?? 'EUR'} · ${f.currencySymbol}';
  } on Object {
    return 'EUR · €';
  }
}

/// Tu foto para la página: {'img': dirección} (una foto) o {'av': n} (0 =
/// tu inicial; 1 a 5 = los avatares de viajero). [file] es tu foto del móvil
/// ya leída (data:...); [google], la de tu cuenta de Google.
Map<String, Object?> photoJson(
  ProfilePhotoChoice c, {
  String? file,
  String? google,
}) {
  final int? preset = c.preset;
  if (preset != null) return <String, Object?>{'av': preset + 1};
  if (c.filePath != null && file != null) return <String, Object?>{'img': file};
  if (c.isNone && isTrustedPhotoUrl(google)) {
    return <String, Object?>{'img': google};
  }
  return <String, Object?>{'av': 0};
}

/// Todo lo que necesita la página.
Map<String, Object?> settingsPageData({
  required String name,
  String? email,
  String? id,
  required bool signedIn,
  required Map<String, Object?> photo,
  required bool deals,
  required bool lock,
  required bool guides,
  required bool dark,
  required String lang,
  required String cur,
  required bool easy,
  required String version,
}) => <String, Object?>{
  'name': name,
  'email': email ?? '',
  'id': id == null ? '' : shortId(id),
  'ini': String.fromCharCodes(name.trim().runes.take(1)).toUpperCase(),
  'signedIn': signedIn,
  'photo': photo,
  'toggles': <String, Object?>{
    'ofertas': deals,
    'huella': lock,
    'ubicacion': guides,
    'oscuro': dark,
  },
  'lang': lang,
  'cur': cur,
  'easy': easy ? 'Fácil' : 'Normal',
  'ver': version,
};

/// La página lista para enseñar.
String settingsPageWith(String page, Map<String, Object?> data) =>
    // "<" como <: ningún dato puede cerrar el script.
    page.replaceFirst(
      settingsMarker,
      jsonEncode(data).replaceAll('<', r'\u003c'),
    );

/// Lo que se le manda a la página sin recargarla.
String settingsPushScript(Map<String, Object?> data) =>
    'window.ECLin&&window.ECLin(${jsonEncode(data).replaceAll('<', r'\u003c')})';
