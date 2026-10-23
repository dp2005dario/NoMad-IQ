// VUELO 3D (maqueta "En vuelo"): el avión en 3D cruza el planeta desde tu
// ciudad hasta tu destino, pasa junto a los monumentos que quedan cerca de TU
// ruta, se hace de noche, amanece y aterriza (bajan los pasajeros).
//
// La escena es una página web con three.js (assets/flight3d/vuelo.html) que
// va DENTRO de la app: no descarga nada y funciona en modo avión. Se ve en un
// WebView (un "navegador" dentro de la pantalla). Este archivo decide qué
// enseñar y le pasa los datos y los textos en tu idioma:
//
//   1. monumentsAlong: qué monumentos pillan cerca de la ruta (y en qué orden).
//   2. flight3dConfig: la ruta, los km y TODOS los textos (en 10 idiomas, de
//      los .arb). La página no lleva textos propios en el idioma del usuario.
//   3. flight3dHtml: mete esos datos en la página (window.NQ_FLIGHT).
//
// El código de la escena está en tool/flight3d/ (ver docs/guia-ruta-del-vuelo.md).
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/generated/app_localizations.dart';
import 'geo.dart';
import 'world_data.dart';

/// Lo que dibuja una página web (un WebView en la app; algo falso en los
/// tests). [onMessage] recibe los avisos de la página: "landed" y "done".
typedef WebSceneBuilder = Widget Function(
  String html,
  void Function(String message) onMessage,
);

/// Un monumento que la escena sabe dibujar en 3D, con su posición real.
class Monument {
  const Monument(this.key, this.position, this.countryCode);

  /// El nombre que usa la escena (vuelo.js, CATALOG).
  final String key;
  final LatLon position;
  final String countryCode;
}

/// Los 11 monumentos de la maqueta. Para añadir uno: modelo 3D en vuelo.js,
/// una línea aquí y sus textos (monumentXxxName/City/Fact) en los .arb.
const List<Monument> monuments = <Monument>[
  Monument('alcala', LatLon(40.4200, -3.6887), 'ES'),
  Monument('eiffel', LatLon(48.8584, 2.2945), 'FR'),
  Monument('bigben', LatLon(51.5007, -0.1246), 'GB'),
  Monument('coliseo', LatLon(41.8902, 12.4922), 'IT'),
  Monument('brandeburgo', LatLon(52.5163, 13.3777), 'DE'),
  Monument('piramides', LatLon(29.9792, 31.1342), 'EG'),
  Monument('basilio', LatLon(55.7525, 37.6231), 'RU'),
  Monument('taj', LatLon(27.1751, 78.0421), 'IN'),
  Monument('muralla', LatLon(40.4319, 116.5704), 'CN'),
  Monument('fuji', LatLon(35.3606, 138.7274), 'JP'),
  Monument('tokio', LatLon(35.6586, 139.7454), 'JP'),
];

/// Los monumentos a menos de [maxKm] del camino del avión, en el orden en
/// que se pasa junto a ellos. Como mucho [limit] (los más cercanos).
///
/// Analogía: trazas la ruta con un rotulador gordo de 600 km sobre el globo;
/// lo que queda debajo del rotulador sale por la ventanilla.
List<String> monumentsAlong(
  LatLon from,
  LatLon to, {
  double maxKm = 600,
  int limit = 8,
}) {
  const int steps = 128;
  final List<LatLon> path = <LatLon>[
    for (int i = 0; i <= steps; i++) intermediate(from, to, i / steps),
  ];
  final List<({String key, double km, double at})> near =
      <({String key, double km, double at})>[];
  for (final Monument m in monuments) {
    double best = double.infinity;
    int bestI = 0;
    for (int i = 0; i < path.length; i++) {
      final double d = distanceKm(path[i], m.position);
      if (d < best) {
        best = d;
        bestI = i;
      }
    }
    if (best <= maxKm) near.add((key: m.key, km: best, at: bestI / steps));
  }
  near.sort((a, b) => a.km.compareTo(b.km));
  final List<({String key, double km, double at})> kept =
      near.take(limit).toList()..sort((a, b) => a.at.compareTo(b.at));
  return <String>[for (final r in kept) r.key];
}

/// "Spain" → "ES": los nombres de país de airports.txt con su código ISO
/// (assets/geo/countries.txt). Con el código, la escena pone la bandera y
/// el nombre del país en tu idioma.
class CountryCodes {
  CountryCodes(this._byName);

  final Map<String, String> _byName;

  String? operator [](String country) => _byName[country];

  static CountryCodes parse(String text) => CountryCodes(<String, String>{
    for (final String line in text.split('\n'))
      if (line.split('|') case [final String name, final String code]
          when RegExp(r'^[A-Z]{2}$').hasMatch(code))
        name: code,
  });

  static Future<CountryCodes>? _loading;

  static Future<CountryCodes> load([AssetBundle? bundle]) =>
      _loading ??= (bundle ?? rootBundle)
          .loadString('assets/geo/countries.txt')
          .then(parse)
          .catchError((Object e) {
            _loading = null;
            throw e;
          });
}

/// Los datos que necesita la escena, ya en tu idioma.
Map<String, Object?> flight3dConfig({
  required AppLocalizations t,
  required String language,
  required Airport from,
  required Airport to,
  required CountryCodes countries,
}) {
  final List<String> keys = monumentsAlong(from.position, to.position);
  return <String, Object?>{
    'lang': language,
    'from': _airport(from, countries),
    'to': _airport(to, countries),
    'km': distanceKm(from.position, to.position).round(),
    'monuments': keys,
    'texts': <String, Object?>{
      for (final String k in keys) k: _monumentTexts(t, k),
    },
    // Las marcas {km}, {city}... las rellena la página con los números de
    // cada momento del vuelo.
    't': <String, String>{
      'loading': t.flight3dLoading,
      'noWebgl': t.flight3dNoWebgl,
      'sceneLabel': t.flight3dSceneLabel(from.city, to.city),
      'overflying': t.flight3dOverflying,
      'landingIn': t.flight3dLandingIn,
      'arrivedIn': t.flight3dArrivedIn,
      'kmOf': t.flight3dKmOf('{km}', '{total}'),
      'day': t.flight3dDay,
      'dusk': t.flight3dDusk,
      'nightfall': t.flight3dNightfall,
      'night': t.flight3dNight,
      'dawn': t.flight3dDawn,
      'camFront': t.flight3dCamFront,
      'camSide': t.flight3dCamSide,
      'camBehind': t.flight3dCamBehind,
      'camTop': t.flight3dCamTop,
      'camCine': t.flight3dCamCine,
      'speed': t.flight3dSpeed,
      'pause': t.flight3dPause,
      'resume': t.flight3dResume,
      'land': t.flight3dLand,
      'theme': t.flight3dTheme('{name}'),
      'themeNormal': t.flight3dThemeNormal,
      'themeHalloween': t.flight3dThemeHalloween,
      'themeXmas': t.flight3dThemeXmas,
      'happyHalloween': t.flight3dHappyHalloween,
      'merryXmas': t.flight3dMerryXmas,
      'controls': t.flight3dControls,
      'welcome': t.flight3dWelcome('{city}'),
      'landed': t.flight3dLanded('{to}', '{km}', '{from}'),
      'again': t.flight3dAgain,
      'done': t.flight3dDone,
      'boardingPass': t.flight3dBoardingPass,
      'passenger': t.flight3dPassenger,
      'flight': t.flight3dFlight,
      'seat': t.flight3dSeat,
    },
  };
}

Map<String, String> _airport(Airport a, CountryCodes countries) =>
    <String, String>{
      'code': a.iata,
      'city': a.city,
      'cc': countries[a.country] ?? '',
    };

Map<String, String> _monumentTexts(AppLocalizations t, String key) =>
    switch (key) {
      'alcala' => _texts(
        t.monumentAlcalaName,
        t.monumentAlcalaCity,
        t.monumentAlcalaFact,
      ),
      'eiffel' => _texts(
        t.monumentEiffelName,
        t.monumentEiffelCity,
        t.monumentEiffelFact,
      ),
      'bigben' => _texts(
        t.monumentBigbenName,
        t.monumentBigbenCity,
        t.monumentBigbenFact,
      ),
      'coliseo' => _texts(
        t.monumentColiseoName,
        t.monumentColiseoCity,
        t.monumentColiseoFact,
      ),
      'brandeburgo' => _texts(
        t.monumentBrandeburgoName,
        t.monumentBrandeburgoCity,
        t.monumentBrandeburgoFact,
      ),
      'piramides' => _texts(
        t.monumentPiramidesName,
        t.monumentPiramidesCity,
        t.monumentPiramidesFact,
      ),
      'basilio' => _texts(
        t.monumentBasilioName,
        t.monumentBasilioCity,
        t.monumentBasilioFact,
      ),
      'taj' => _texts(t.monumentTajName, t.monumentTajCity, t.monumentTajFact),
      'muralla' => _texts(
        t.monumentMurallaName,
        t.monumentMurallaCity,
        t.monumentMurallaFact,
      ),
      'fuji' => _texts(
        t.monumentFujiName,
        t.monumentFujiCity,
        t.monumentFujiFact,
      ),
      'tokio' => _texts(
        t.monumentTokioName,
        t.monumentTokioCity,
        t.monumentTokioFact,
      ),
      _ => const <String, String>{},
    };

Map<String, String> _texts(String name, String city, String fact) =>
    <String, String>{'name': name, 'city': city, 'fact': fact};

/// La página con los datos dentro. "</" se escribe "<\/" para que ningún
/// texto pueda cerrar la etiqueta <script> antes de tiempo.
String flight3dHtml(String template, Map<String, Object?> config) {
  final String json = jsonEncode(config).replaceAll('</', r'<\/');
  return template.replaceFirst('/*NQ_CONFIG*/', 'window.NQ_FLIGHT = $json;');
}

/// La pantalla del vuelo 3D. Devuelve true si el vuelo terminó (el usuario
/// pulsó "Continuar" tras aterrizar) y false si lo cerró antes.
class Flight3dScreen extends StatefulWidget {
  const Flight3dScreen({
    super.key,
    required this.from,
    required this.to,
    required this.scene,
    this.loadTemplate,
    this.loadCountries,
  });

  final Airport from;
  final Airport to;
  final WebSceneBuilder scene;

  /// En los tests se dan ya cargados.
  final Future<String> Function()? loadTemplate;
  final Future<CountryCodes> Function()? loadCountries;

  @override
  State<Flight3dScreen> createState() => _Flight3dScreenState();
}

class _Flight3dScreenState extends State<Flight3dScreen> {
  Future<(String, CountryCodes)>? _ready;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _ready ??= Future.wait(<Future<Object>>[
      (widget.loadTemplate ??
          () => rootBundle.loadString('assets/flight3d/vuelo.html'))(),
      (widget.loadCountries ?? CountryCodes.load)(),
    ]).then((List<Object> r) => (r[0] as String, r[1] as CountryCodes));
  }

  void _onMessage(String message) {
    // La página avisa al pulsar "Continuar" tras aterrizar.
    if (message == 'done' && mounted) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    final String language = Localizations.localeOf(context).languageCode;
    return Scaffold(
      backgroundColor: const Color(0xFF050A14),
      body: Stack(
        children: <Widget>[
          Positioned.fill(
            child: FutureBuilder<(String, CountryCodes)>(
              future: _ready,
              builder:
                  (
                    BuildContext context,
                    AsyncSnapshot<(String, CountryCodes)> snap,
                  ) {
                    final (String, CountryCodes)? ready = snap.data;
                    if (ready == null) {
                      return Center(
                        child: snap.hasError
                            ? Text(t.flight3dNoWebgl)
                            : const CircularProgressIndicator(),
                      );
                    }
                    final (String template, CountryCodes countries) = ready;
                    return widget.scene(
                      flight3dHtml(
                        template,
                        flight3dConfig(
                          t: t,
                          language: language,
                          from: widget.from,
                          to: widget.to,
                          countries: countries,
                        ),
                      ),
                      _onMessage,
                    );
                  },
            ),
          ),
          // Cerrar, siempre a mano. La página es siempre de izquierda a
          // derecha y deja hueco arriba a la izquierda para este botón.
          Positioned(
            top: 0,
            left: 0,
            child: SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(4),
                child: IconButton(
                  tooltip: t.flight3dClose,
                  color: Colors.white,
                  icon: const Icon(Icons.close_rounded),
                  onPressed: () => Navigator.of(context).pop(false),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
