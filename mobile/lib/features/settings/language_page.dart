// Lo que la app le da a la página de "Idioma" (la maqueta, en
// assets/settings/idioma.html): los idiomas que trae la app y, para cada
// uno, cómo se ve la tarjeta de muestra en ese idioma.
//
// Dart puro: se prueba sin WebView.
import 'dart:convert';
import 'dart:ui' show Locale;

import 'package:intl/intl.dart';

import '../../core/languages.dart';
import '../../l10n/generated/app_localizations.dart';
import '../assistant/assistant_texts.dart';

/// Dónde está la página y la marca donde la app mete sus datos.
const String languagePage = 'assets/settings/idioma.html';
const String languageMarker = '/*ECLIPTA*/{}';

/// Los idiomas que se escriben de derecha a izquierda.
const Set<String> rtlLanguages = <String>{'ar', 'fa', 'ur'};

/// La letra de cada escritura (como en la maqueta).
const Map<String, String> languageFonts = <String, String>{
  'ja': "'Noto Sans JP', ",
  'zh': "'Noto Sans SC', ",
  'ko': "'Noto Sans KR', ",
  'ar': "'Noto Sans Arabic', ",
  'hi': "'Noto Sans Devanagari', ",
};

/// La tarjeta de muestra en el idioma [code]: textos de la app de verdad,
/// la fecha y la hora de ahora con el formato de ese idioma.
Map<String, Object?> languagePreview(String code, DateTime now, String? name) {
  final AppLocalizations l = lookupAppLocalizations(Locale(code));
  String format(DateFormat Function(String) f) {
    try {
      return f(code).format(now);
    } on Object {
      return f('en').format(now);
    }
  }

  return <String, Object?>{
    'tag': l.easyToday,
    'date': format(DateFormat.yMMMd),
    'title': name == null ? l.easyHelloGuest : l.easyHello(name),
    'rain': l.voiceExFlight,
    'money': format(DateFormat.Hm),
    'btn': l.navFlights,
  };
}

/// Una fila de la lista para la página.
Map<String, Object?> languageRow(
  String code,
  String appLang,
  DateTime now,
  String? name,
) => <String, Object?>{
  'code': code,
  'native': endonymFor(code),
  // Con la app en español, el nombre en español ("Japonés"); si no, el
  // código ("ja").
  'sub': appLang == 'es' ? spanishLanguageNames[code] ?? code : code,
  'font': languageFonts[code] ?? '',
  'rtl': rtlLanguages.contains(code),
  'pv': languagePreview(code, now, name),
};

/// La página lista para enseñar.
String languagePageWith(String page, Map<String, Object?> data) =>
    // "<" como \u003c: ningún dato puede cerrar el script.
    page.replaceFirst(
      languageMarker,
      jsonEncode(data).replaceAll('<', r'\u003c'),
    );

/// Lo que se le manda a la página sin recargarla.
String languagePushScript(Map<String, Object?> data) =>
    'window.ECLin&&window.ECLin(${jsonEncode(data).replaceAll('<', r'\u003c')})';
