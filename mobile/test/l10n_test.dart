// Vigila las traducciones: ningún idioma puede quedarse sin un texto ni
// "romper" un hueco como {feature}. Si alguien añade un texto solo en inglés,
// este test falla y avisa ANTES de que llegue a los usuarios.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:eclipta/core/languages.dart';
import 'package:eclipta/l10n/generated/app_localizations.dart';

Map<String, Object?> _read(File f) =>
    jsonDecode(f.readAsStringSync()) as Map<String, Object?>;

Set<String> _messages(Map<String, Object?> arb) =>
    arb.keys.where((String k) => !k.startsWith('@')).toSet();

final RegExp _placeholder = RegExp(r'\{(\w+)\}');

void main() {
  final List<File> files = Directory('lib/l10n')
      .listSync()
      .whereType<File>()
      .where((File f) => f.path.endsWith('.arb'))
      .toList();
  final Map<String, Object?> template = _read(
    files.singleWhere((File f) => f.path.endsWith('app_en.arb')),
  );

  test('hay varios idiomas, incluido uno de derecha a izquierda', () {
    expect(files.length, greaterThanOrEqualTo(10));
    expect(
      AppLocalizations.supportedLocales.map((l) => l.languageCode),
      contains('ar'),
    );
  });

  for (final File file in files) {
    test('${file.uri.pathSegments.last} tiene todos los textos y huecos', () {
      final Map<String, Object?> arb = _read(file);
      expect(_messages(arb), _messages(template));
      for (final String key in _messages(template)) {
        final String value = arb[key]! as String;
        expect(value.trim(), isNotEmpty, reason: key);
        expect(
          _placeholder.allMatches(value).map((m) => m[1]).toSet(),
          _placeholder
              .allMatches(template[key]! as String)
              .map((m) => m[1])
              .toSet(),
          reason: '$key debe conservar sus {huecos}',
        );
      }
      expect(arb['appTitle'], 'ECLIPTA', reason: 'la marca no se traduce');
    });
  }

  test('cada idioma de la app tiene su nombre propio en el selector', () {
    for (final locale in AppLocalizations.supportedLocales) {
      expect(languageEndonyms, contains(locale.languageCode));
    }
  });

  test('Android conoce los mismos idiomas (locales_config.xml)', () {
    final String xml = File('android/app/src/main/res/xml/locales_config.xml')
        .readAsStringSync();
    final Set<String> android = RegExp(r'android:name="([\w-]+)"')
        .allMatches(xml)
        .map((m) => m[1]!)
        .toSet();
    expect(
      android,
      AppLocalizations.supportedLocales.map((l) => l.toLanguageTag()).toSet(),
    );
  });
}
