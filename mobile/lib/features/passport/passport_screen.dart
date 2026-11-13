// Mi pasaporte (maqueta "Pasaporte"): la maqueta tal cual
// (assets/passport/pasaporte.html). Un librito con la tapa de ECLIPTA que
// flota; al abrirlo, una página por país con los sellos de los monumentos
// que has reconocido con la cámara. Cada sello es un "cromo" con su rareza
// (cuanto más antiguo el monumento, más rara); al tocarlo se ve su
// historia, se puede escuchar y abrir en el mapa.
// Todo sale del móvil: los sellos nunca se mandan a ningún servidor.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../auth/session.dart';
import '../../core/router.dart';
import '../../core/services.dart';
import '../../core/settings.dart';
import '../../core/theme.dart';
import '../../l10n/generated/app_localizations.dart';
import '../camera/stamps.dart';
import '../home/home_screen.dart' show displayName;
import '../route/flight3d.dart' show CountryCodes;
import '../route/world_data.dart';
import '../visa/visa_data.dart' show CountryNames;
import '../route/web_scene.dart';
import 'passport.dart';
import 'passport_page.dart';

class PassportScreen extends StatefulWidget {
  const PassportScreen({super.key});

  /// La última conexión con la página (para las pruebas).
  static WebSceneBridge? lastBridge;

  @override
  State<PassportScreen> createState() => _PassportScreenState();
}

class _PassportScreenState extends State<PassportScreen> {
  late final AppServices _services = ServicesScope.of(context);
  final WebSceneBridge _bridge = PassportScreen.lastBridge = WebSceneBridge();
  late final List<Stamp> _stamps = StampBook(_services.prefs).all();
  List<PassportPage>? _pages;
  CountryNames? _names;
  String? _speaking;

  // La página se lee una vez y se guarda (como String, no como Future).
  static String? _pageCache;
  String? _html;
  String? _sent;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_start()));
    // Ya has visto tus sellos: el número de "nuevos" del Mapa vuelve a 0.
    unawaited(
      _services.prefs.writeData(
        LocalData.passportSeen,
        DateTime.now().toUtc().toIso8601String(),
      ),
    );
  }

  @override
  void dispose() {
    if (_speaking != null) unawaited(_services.speaker.stop());
    super.dispose();
  }

  Future<void> _start() async {
    try {
      _pageCache ??= await rootBundle.loadString(passportPage, cache: false);
    } on Object {
      return;
    }
    if (mounted) setState(() {});
    // Sin sellos no hay nada que repartir por países.
    if (_stamps.isNotEmpty) await _load();
  }

  /// Los aeropuertos (para saber el país) vienen dentro de la app. Mientras
  /// cargan, o si fallan, los sellos salen todos en "Otros lugares".
  Future<void> _load() async {
    Iterable<Airport> airports = const <Airport>[];
    CountryCodes? codes;
    CountryNames? names;
    try {
      airports = (await WorldData.load()).airports.all;
      codes = await CountryCodes.load();
    } on Object {
      // sin datos del mundo: una sola página
    }
    try {
      names = await CountryNames.load();
    } on Object {
      // sin nombres: el código del país ("IT")
    }
    if (!mounted) return;
    setState(() {
      _pages = pagesOf(_stamps, airports: airports, codes: codes);
      _names = names;
    });
  }

  Stamp? _byId(String qid) =>
      _stamps.where((Stamp s) => s.qid == qid).firstOrNull;

  /// Escuchar el cromo (la voz del móvil lee su nombre y su historia).
  Future<void> _listen(Stamp s) async {
    if (_speaking == s.qid) {
      await _services.speaker.stop();
      if (mounted) setState(() => _speaking = null);
      return;
    }
    setState(() => _speaking = s.qid);
    await _services.speaker.speak(
      <String?>[s.name, s.description].whereType<String>().join('. '),
      Localizations.localeOf(context).toLanguageTag(),
    );
    if (mounted && _speaking == s.qid) setState(() => _speaking = null);
  }

  /// Lo que pide la página.
  void _onMessage(String m) {
    final int i = m.indexOf(':');
    final String what = i < 0 ? m : m.substring(0, i);
    final Stamp? s = i < 0 ? null : _byId(m.substring(i + 1));
    switch (what) {
      case 'back':
        if (context.canPop()) context.pop();
      case 'memories':
        unawaited(context.push(Routes.memories));
      case 'camera':
        context.go(Routes.cameraScan);
      case 'listen' when s != null:
        unawaited(_listen(s));
      case 'stop':
        unawaited(_services.speaker.stop());
        setState(() => _speaking = null);
      case 'map' when s != null && s.lat != null && s.lon != null:
        unawaited(_services.openLink(osmLink(s.lat!, s.lon!)));
    }
  }

  Map<String, Object?> _data(AppLocalizations t) {
    final String lang = Localizations.localeOf(context).languageCode;
    final String tag = Localizations.localeOf(context).toLanguageTag();
    final String? owner = displayName(SessionScope.of(context).user?.email);
    final List<PassportPage> pages = _pages ?? pagesOf(_stamps);
    // "PASAPORTE DE VIAJE": la primera palabra en grande y el resto con tu
    // nombre debajo, como en la tapa de la maqueta.
    final String cover = t.passportCoverTitle;
    final int sp = cover.indexOf(' ');
    final String cov1 = sp < 0 ? cover : cover.substring(0, sp);
    final String rest = sp < 0 ? '' : cover.substring(sp + 1);
    final String cov2 = <String>[
      if (rest.isNotEmpty) rest,
      if (owner != null) owner.toUpperCase(),
    ].join(' · ');
    int num = 0;
    final List<Map<String, Object?>> book = <Map<String, Object?>>[];
    for (int p = 0; p < pages.length; p++) {
      final PassportPage page = pages[p];
      final String? iso = page.country;
      final String country = iso == null
          ? t.passportElsewhere
          : _names?.name(iso, lang) ?? iso;
      final DateTime? newest = page.stamps.firstOrNull?.date;
      final String city = page.cities.isEmpty ? '' : page.cities.first;
      // Caben 4 cromos por página (como en la maqueta): un país con más
      // ocupa varias páginas seguidas.
      for (int from = 0; from < page.stamps.length; from += 4) {
        final List<Stamp> four = page.stamps.skip(from).take(4).toList();
        book.add(<String, Object?>{
          'group': p,
          'total': page.stamps.length,
          'country': country,
          'city': city,
          'sub': <String>[
            if (page.cities.isNotEmpty) page.cities.take(2).join(' · '),
            if (newest != null) DateFormat.yMMM(tag).format(newest.toLocal()),
          ].join(' · '),
          'tint': 'rgba(61,220,151,0.10)',
          'flag': iso == null ? '🌍' : flagOf(iso),
          'pageNo': 'Pág. ${book.length + 1}',
          'count': t.passportStamps(page.stamps.length),
          'cards': <Object?>[
            for (final Stamp s in four)
              () {
                num++;
                final Rarity r = rarityOf(s.year);
                return <String, Object?>{
                  'id': s.qid,
                  'name': s.name,
                  'num': '#${num.toString().padLeft(2, '0')}',
                  'icon': stampDrawing(s),
                  'rar': rarityKey(r),
                  'rarLbl': rarityLabel(t, r).toUpperCase(),
                  'date': stampDay(s.date),
                  'place': <String>[
                    if (city.isNotEmpty) '$city, $country' else country,
                    stampDay(s.date),
                  ].join(' · '),
                  'k1': t.cameraBuilt.toUpperCase(),
                  'v1': s.year?.toString() ?? '?',
                  'k2': 'SELLADO',
                  'v2': DateFormat.yMMMd(tag).format(s.date.toLocal()),
                  'text': s.description ?? t.passportRarityWhy,
                  'map': s.lat != null && s.lon != null,
                };
              }(),
          ],
        });
      }
    }
    if (book.isEmpty) {
      // Sin sellos: una página que lo dice y lleva a la cámara.
      book.add(<String, Object?>{
        'group': 0,
        'country': t.passportTitle,
        'city': '',
        'sub': '',
        'tint': 'rgba(61,220,151,0.10)',
        'flag': '🌍',
        'pageNo': 'Pág. 1',
        'count': t.passportStamps(0),
        'cards': const <Object?>[],
        'empty': true,
      });
    }
    return <String, Object?>{
      'title': t.passportTitle,
      'total':
          '${t.passportStamps(_stamps.length)} · ${t.passportCountries(pages.where((PassportPage p) => p.country != null).length)}',
      'memTxt': 'Recuerdos',
      'cov1': cov1,
      'cov2': cov2,
      'tapOpen': t.passportTapToOpen,
      'info': t.passportHint,
      'emptyTxt': t.passportEmpty,
      'cameraTxt': t.passportOpenCamera,
      'listenTxt': t.cameraListen,
      'stopTxt': t.cameraStopListening,
      'mapTxt': t.passportSeeOnMap,
      'speaking': _speaking,
      'pages': book,
    };
  }

  @override
  Widget build(BuildContext context) {
    final String? page = _pageCache;
    if (page == null) {
      return const Scaffold(
        backgroundColor: Color(0xFF0B1217),
        body: SizedBox.expand(),
      );
    }
    final Map<String, Object?> data = _data(AppLocalizations.of(context));
    final String push = passportPushScript(data);
    if (_html == null) {
      _html = passportPageWith(page, data);
      _sent = push;
    } else if (push != _sent) {
      _sent = push;
      unawaited(_bridge.run(push));
    }
    final String html = _html!;
    return Scaffold(
      backgroundColor: const Color(0xFF0B1217),
      body: SafeArea(
        bottom: false,
        child:
            _services.webScene?.call(html, _onMessage) ??
            WebScene(html: html, onMessage: _onMessage, bridge: _bridge),
      ),
    );
  }
}

Color rarityColor(Rarity r) => switch (r) {
  Rarity.legendary => const Color(0xFFE9C46A), // oro
  Rarity.epic => NomadColors.group, // violeta
  Rarity.rare => NomadColors.flights, // azul
  Rarity.common => NomadColors.textMuted,
};

String rarityLabel(AppLocalizations t, Rarity r) => switch (r) {
  Rarity.legendary => t.passportRarityLegendary,
  Rarity.epic => t.passportRarityEpic,
  Rarity.rare => t.passportRarityRare,
  Rarity.common => t.passportRarityCommon,
};
