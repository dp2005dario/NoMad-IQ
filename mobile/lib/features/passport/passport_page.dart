// Lo que la app le da a la página de "Mi pasaporte" (la maqueta, en
// assets/passport/pasaporte.html): una página por país con tus sellos
// convertidos en cromos.
//
// Dart puro: se prueba sin WebView.
import 'dart:convert';

import 'package:intl/intl.dart';

import '../camera/stamps.dart';
import 'passport.dart';

/// Dónde está la página y la marca donde la app mete sus datos.
const String passportPage = 'assets/passport/pasaporte.html';
const String passportMarker = '/*ECLIPTA*/{}';

/// El dibujo del cromo según lo que es el monumento (por palabras de su
/// nombre o su descripción, en varios idiomas). Si no se sabe: un palacio.
String stampDrawing(Stamp s) {
  final String text = '${s.name} ${s.description ?? ''}'.toLowerCase();
  bool has(List<String> words) => words.any(text.contains);
  if (has(<String>['torre', 'tower', 'tour ', 'turm', 'campanile'])) {
    return 'tower';
  }
  if (has(<String>[
    'coliseo',
    'colosseo',
    'colosseum',
    'anfiteatro',
    'amphitheat',
    'arena',
    'estadio',
    'stadium',
  ])) {
    return 'colos';
  }
  if (has(<String>['fuente', 'fontana', 'fountain', 'fontaine', 'brunnen'])) {
    return 'fountain';
  }
  if (has(<String>[
    'monte',
    'mount',
    'volcán',
    'volcano',
    'montaña',
    'mountain',
    'pico',
    'peak',
  ])) {
    return 'fuji';
  }
  if (has(<String>[
    'santuario',
    'shrine',
    'templo',
    'temple',
    'jinja',
    'pagoda',
  ])) {
    return 'torii';
  }
  if (has(<String>[
    'parque',
    'park',
    'jardín',
    'jardin',
    'garden',
    'bosque',
    'forest',
  ])) {
    return 'tree';
  }
  if (has(<String>['reloj', 'clock', 'correos', 'ayuntamiento', 'city hall'])) {
    return 'clock';
  }
  if (has(<String>[
    'estatua',
    'statue',
    'escultura',
    'sculpture',
    'monumento a',
  ])) {
    return 'bear';
  }
  if (has(<String>['tranvía', 'tram', 'funicular', 'teleférico'])) {
    return 'tram';
  }
  if (has(<String>[
    'plaza',
    'square',
    'piazza',
    'place ',
    'cruce',
    'crossing',
  ])) {
    return 'cross';
  }
  if (has(<String>[
    'castillo',
    'castle',
    'fortaleza',
    'fortress',
    'monasterio',
    'monastery',
    'iglesia',
    'church',
    'catedral',
    'cathedral',
  ])) {
    return 'belem';
  }
  return 'palace';
}

/// El nombre de la rareza para la página ("legendary"...).
String rarityKey(Rarity r) => r.name;

/// La página lista para enseñar.
String passportPageWith(String page, Map<String, Object?> data) =>
    // "<" como \u003c: ningún dato puede cerrar el script.
    page.replaceFirst(
      passportMarker,
      jsonEncode(data).replaceAll('<', r'\u003c'),
    );

/// Lo que se le manda a la página sin recargarla.
String passportPushScript(Map<String, Object?> data) =>
    'window.ECLin&&window.ECLin(${jsonEncode(data).replaceAll('<', r'\u003c')})';

/// "22/10/26", como en la maqueta.
String stampDay(DateTime d) => DateFormat('dd/MM/yy').format(d.toLocal());
