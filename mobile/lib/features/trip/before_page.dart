// Lo que la app le da a la página de "Antes de salir" (la maqueta, en
// assets/trip/antes.html): tu viaje, las tarjetas del país, los consejos de
// Flyra, la maleta, datos móviles y seguro, y los reels.
//
// Dart puro: se prueba sin WebView.
import 'dart:convert';

/// Dónde está la página y la marca donde la app mete sus datos.
const String beforePage = 'assets/trip/antes.html';
const String beforeMarker = '/*ECLIPTA*/{}';

/// Una red de vídeos cortos: TikTok, Instagram o YouTube.
enum ReelNet { tt, ig, yt }

/// Un reel: una búsqueda de verdad en la app oficial de esa red. No hay
/// vídeos inventados: al tocar "Ver en ..." se abre la red buscando esto.
class BeforeReel {
  const BeforeReel(this.title, this.net, {this.tag = ''});

  final String title;
  final ReelNet net;

  /// La etiqueta de Instagram (la ciudad o el país).
  final String tag;

  /// El enlace que abre la búsqueda en la red.
  Uri get url => switch (net) {
    ReelNet.tt => Uri.https('www.tiktok.com', '/search', <String, String>{
      'q': title,
    }),
    // Instagram busca por etiqueta: sin espacios ni signos.
    ReelNet.ig => Uri.https(
      'www.instagram.com',
      '/explore/tags/${tag.replaceAll(RegExp(r'[^\p{L}\p{N}]', unicode: true), '')}/',
    ),
    ReelNet.yt => Uri.https('www.youtube.com', '/results', <String, String>{
      'search_query': '$title #shorts',
    }),
  };
}

/// Los 6 reels del viaje, como en la maqueta (2 de cada red).
List<BeforeReel> reelsFor(String city, String country) => <BeforeReel>[
  BeforeReel('$city de noche', ReelNet.tt),
  BeforeReel('Qué comer en $city', ReelNet.ig, tag: city),
  BeforeReel('$country en 1 minuto', ReelNet.yt),
  BeforeReel('Imprescindibles de $country', ReelNet.ig, tag: country),
  BeforeReel('$country consejos de viaje', ReelNet.tt),
  BeforeReel('Paseo por $city', ReelNet.yt),
];

/// Los reels guardados (sus títulos), leídos con cuidado.
Set<String> savedReels(String? raw) {
  try {
    final Object? v = jsonDecode(raw ?? '[]');
    return v is List<Object?> ? v.whereType<String>().toSet() : <String>{};
  } on FormatException {
    return <String>{};
  }
}

/// Las tarjetas del país para la página.
Map<String, Object?> factJson({
  required String key,
  required String value,
  required String more,
  required String source,
  required String icon,
  required String color,
}) => <String, Object?>{
  'k': key.toUpperCase(),
  'v': value,
  'more': more,
  'src': source,
  'ic': icon,
  'c': color,
};

/// Los reels para la página.
List<Map<String, Object?>> reelsJson(List<BeforeReel> reels, String who) =>
    <Map<String, Object?>>[
      for (final BeforeReel r in reels)
        <String, Object?>{'t': r.title, 'who': who, 'net': r.net.name},
    ];

/// La página lista para enseñar.
String beforePageWith(String page, Map<String, Object?> data) =>
    // "<" como <: ningún dato puede cerrar el script.
    page.replaceFirst(beforeMarker, jsonEncode(data).replaceAll('<', r'<'));

/// Lo que se le manda a la página sin recargarla.
String beforePushScript(Map<String, Object?> data) =>
    'window.ECLin&&window.ECLin(${jsonEncode(data).replaceAll('<', r'<')})';
