// Explorar (maqueta "Explorar"): el mundo entero pintado según lo bueno que es
// cada mes para viajar a cada país. Globo 3D que se arrastra (o mapa plano),
// "Mejor ahora mismo", la lista de todos los países y la ficha de cada uno.
//
// La página es la propia maqueta (assets/explore/explorar.html) dentro de un
// WebView, sin datos de ejemplo: la app le pone los textos en tu idioma y el
// clima REAL de cada país (NASA POWER, medias de 30 años: temperatura y
// lluvia de cada mes). La puntuación de 0 a 100 sale de ahí: 22 °C y poca
// lluvia es lo ideal. Lo que no tiene una fuente fiable y gratis (turistas,
// coste diario, seguridad) dice "Sin datos".
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/services.dart';
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
  }).replaceAll('</', r'<\/');
  return page.replaceFirst(exploreMarker, data);
}

class ExploreScreen extends StatefulWidget {
  const ExploreScreen({super.key});

  @override
  State<ExploreScreen> createState() => _ExploreScreenState();
}

class _ExploreScreenState extends State<ExploreScreen> {
  late final AppServices _services = ServicesScope.of(context);
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
    CountryClimate climate = _climate;
    try {
      climate = await _services.climate.countries();
    } on Exception {
      // Sin red: el mundo sale en gris ("Sin datos"); se reintenta.
    }
    if (!mounted) return;
    final bool more = climate.byCountry.length > _climate.byCountry.length;
    setState(() {
      _climate = climate;
      // Solo se vuelve a cargar la página si hay países nuevos (cargarla
      // reinicia el globo).
      if (_html == null || more) _html = _build();
    });
    // La primera vez el servidor va pidiendo los países poco a poco: se
    // vuelve a preguntar unas cuantas veces.
    if (!climate.complete && _tries < 4) {
      _tries++;
      _again = Timer(const Duration(seconds: 20), () => unawaited(_load()));
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
              child: KeyedSubtree(
                // Una página nueva = un WebView nuevo.
                key: ValueKey<int>(html.hashCode),
                child:
                    _services.webScene?.call(html, (_) {}) ??
                    WebScene(html: html, onMessage: (_) {}),
              ),
            ),
    );
  }
}
