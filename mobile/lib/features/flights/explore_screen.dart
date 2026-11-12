// Explorar (maqueta "Explorar"): el mundo entero pintado según lo bueno que es
// cada mes para viajar a cada país. Globo 3D que se arrastra (o mapa plano),
// "Mejor ahora mismo", la lista de todos los países y la ficha de cada uno.
//
// La página es la propia maqueta (assets/explore/explorar.html) dentro de un
// WebView, sin datos de ejemplo: la app le pone los textos en tu idioma y el
// clima REAL de cada país (NASA POWER, medias de 30 años: temperatura y
// lluvia de cada mes). La puntuación de 0 a 100 sale de ahí: 22 °C y poca
// lluvia es lo ideal. Turistas, precios, seguridad, habitantes y capital
// salen del Banco Mundial (también por el servidor). Lo que un país no
// tenga dice "Sin datos". Todo se guarda en el móvil: la siguiente vez la
// página sale llena al instante.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/services.dart';
import '../../core/settings.dart';
import '../../core/theme.dart';
import '../../l10n/generated/app_localizations.dart';
import '../route/web_scene.dart';
import 'climate_api.dart';

/// Dónde está la página y la marca donde la app mete sus datos.
const String explorePage = 'assets/explore/explorar.html';
const String exploreMarker = '/*ECLIPTA*/{"lang":"es","t":{},"climate":{}}';

/// Los textos de la página en el idioma [t] (las claves que usa la página).
Map<String, String> exploreTexts(AppLocalizations t) => <String, String>{
  'title': t.exwTitle,
  'sub': t.exwSub,
  'map': t.exwMap,
  'globe': t.exwGlobe,
  'clouds': t.exwClouds,
  'loading': t.exwLoading,
  'hintGlobe': t.exwHintGlobe,
  'hintMap': t.exwHintMap,
  'avoid': t.exwAvoid,
  'bestTime': t.exwBestTime,
  'source': t.exwSource,
  'topNow': t.exwTopNow,
  'allCountries': t.exwAllCountries,
  'search': t.exwSearch,
  // La página cambia {n} y {total} por los números.
  'count': t.exwCount('{n}', '{total}'),
  'show': t.exwShow,
  'hide': t.exwHide,
  'noData': t.exwNoData,
  'vGreat': t.exwGreat,
  'vGood': t.exwGood,
  'vFair': t.exwFair,
  'vAvoid': t.exwAvoidVerdict,
  'bestMonth': t.exwBestMonth('{month}', '{best}'),
  'temp': t.exwTemp,
  'rain': t.exwRain,
  'tourists': t.exwTourists,
  'cost': t.exwCost,
  'safety': t.exwSafety,
  'year': t.exwYear,
  'close': t.exwClose,
  'zoomIn': t.exwZoomIn,
  'zoomOut': t.exwZoomOut,
  'zoomAll': t.exwZoomAll,
  'loadFail': t.exwLoadFail,
  'perYear': t.exwPerYear,
  'cheap': t.exwCheap,
  'mid': t.exwMid,
  'pricey': t.exwPricey,
  'safe': t.exwSafe,
  'careful': t.exwCareful,
  'risky': t.exwRisky,
  'capital': t.exwCapital,
  'population': t.exwPopulation,
  'factsSource': t.exwFactsSource,
};

/// La página lista para enseñar: [page] con los textos y el clima dentro.
String explorePageWith(
  String page, {
  required String language,
  required Map<String, String> texts,
  required CountryClimate climate,
}) {
  // Se escapa "</" para que nada pueda cerrar el <script> de la página.
  final String data = jsonEncode(<String, Object?>{
    'lang': language,
    't': texts,
    'climate': climate.byCountry,
    'facts': factsJson(climate.facts),
  }).replaceAll('</', r'<\/');
  return page.replaceFirst(exploreMarker, data);
}

/// Los datos de cada país, como los lee la página.
Map<String, Object> factsJson(Map<String, WorldFacts> facts) =>
    <String, Object>{
      for (final MapEntry<String, WorldFacts> e in facts.entries)
        e.key: e.value.toJson(),
    };

/// Cuántas veces se vuelve a preguntar mientras el servidor aún va
/// llenando países (cada 15 s: hasta ~10 minutos con la pantalla abierta).
const int exploreMaxTries = 40;

class ExploreScreen extends StatefulWidget {
  const ExploreScreen({super.key});

  @override
  State<ExploreScreen> createState() => _ExploreScreenState();
}

class _ExploreScreenState extends State<ExploreScreen> {
  late final AppServices _services = ServicesScope.of(context);
  final WebSceneBridge _bridge = WebSceneBridge();
  String? _page;
  CountryClimate _climate = const CountryClimate(
    byCountry: <String, List<List<double>>>{},
    complete: false,
  );
  String? _html;
  int _tries = 0;
  Timer? _again;
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    unawaited(_load());
  }

  @override
  void dispose() {
    _again?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    _page ??= await rootBundle.loadString(explorePage);
    // Lo que se guardó la última vez: la página sale ya con datos, al
    // instante, aunque el servidor tarde o no haya red.
    if (_html == null) {
      try {
        final String? saved = _services.prefs.readData(LocalData.exploreData);
        if (saved != null) _climate = CountryClimate.parse(jsonDecode(saved));
      } on FormatException {
        // Guardado roto: se empieza de cero.
      }
    }
    CountryClimate fresh = const CountryClimate(
      byCountry: <String, List<List<double>>>{},
      complete: false,
    );
    bool answered = false;
    try {
      fresh = await _services.climate.countries();
      answered = true;
    } on Exception {
      // Sin red: se queda lo guardado; se reintenta.
    }
    if (!mounted) return;
    final CountryClimate before = _climate;
    final CountryClimate climate = answered ? before.merge(fresh) : before;
    final Map<String, List<List<double>>> added = <String, List<List<double>>>{
      for (final MapEntry<String, List<List<double>>> e
          in climate.byCountry.entries)
        if (!before.byCountry.containsKey(e.key)) e.key: e.value,
    };
    final bool newFacts = before.facts.isEmpty && climate.facts.isNotEmpty;
    final bool first = _html == null;
    setState(() {
      _climate = climate;
      if (first) _html = _build();
    });
    if (answered && (added.isNotEmpty || newFacts)) {
      unawaited(
        _services.prefs.writeData(
          LocalData.exploreData,
          jsonEncode(climate.toJson()),
        ),
      );
    }
    // Países nuevos con la página ya abierta: se le mandan sin recargarla
    // (recargar cerraba la ficha del país que estabas mirando y reiniciaba
    // el globo: por eso "salía muy rápido" o parecía pillado).
    if (!first && added.isNotEmpty) {
      await _bridge.run(
        'window.__climate&&window.__climate('
        '${jsonEncode(added).replaceAll('</', r'<\/')});',
      );
    }
    if (!first && newFacts) {
      await _bridge.run(
        'window.__facts&&window.__facts('
        '${jsonEncode(factsJson(climate.facts)).replaceAll('</', r'<\/')});',
      );
    }
    // El servidor va pidiendo los países poco a poco (la NASA no deja ir
    // más rápido): se vuelve a preguntar mientras la pantalla esté abierta.
    if (!(answered && fresh.complete) && _tries < exploreMaxTries) {
      _tries++;
      _again = Timer(const Duration(seconds: 15), () => unawaited(_load()));
    }
  }

  String _build() {
    final AppLocalizations t = AppLocalizations.of(context);
    return explorePageWith(
      _page!,
      language: Localizations.localeOf(context).languageCode,
      texts: exploreTexts(t),
      climate: _climate,
    );
  }

  @override
  Widget build(BuildContext context) {
    final String? html = _html;
    return Scaffold(
      backgroundColor: NomadColors.background,
      body: html == null
          // Mientras se prepara la página (un instante), el fondo oscuro.
          ? const SizedBox.expand()
          : SafeArea(
              bottom: false,
              child:
                  _services.webScene?.call(html, (_) {}) ??
                  WebScene(html: html, onMessage: (_) {}, bridge: _bridge),
            ),
    );
  }
}
