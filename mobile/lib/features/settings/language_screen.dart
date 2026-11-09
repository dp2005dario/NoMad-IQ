// Elegir idioma (maqueta "Idioma"): la maqueta tal cual
// (assets/settings/idioma.html) con TODOS los idiomas que trae la app, cada
// uno escrito en su propio idioma y con su bandera, el buscador, la tarjeta
// que enseña cómo se ve la app en el idioma elegido y el interruptor "Flyra
// y las audioguías también en este idioma".
import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';

import '../../auth/session.dart';
import '../../core/languages.dart';
import '../../core/services.dart';
import '../../core/settings.dart';
import '../../l10n/generated/app_localizations.dart';
import '../home/home_screen.dart' show displayName;
import '../route/web_scene.dart';
import 'language_page.dart';

class LanguageScreen extends StatefulWidget {
  const LanguageScreen({super.key});

  /// La última conexión con la página (para las pruebas).
  static WebSceneBridge? lastBridge;

  @override
  State<LanguageScreen> createState() => _LanguageScreenState();
}

class _LanguageScreenState extends State<LanguageScreen> {
  late final AppServices _services = ServicesScope.of(context);
  final WebSceneBridge _bridge = LanguageScreen.lastBridge = WebSceneBridge();

  // La página se lee una vez y se guarda (como String, no como Future).
  static String? _pageCache;
  String? _html;
  String? _sent;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_start()));
  }

  Future<void> _start() async {
    try {
      _pageCache ??= await rootBundle.loadString(languagePage, cache: false);
    } on Object {
      return;
    }
    if (mounted) setState(() {});
  }

  /// El idioma del móvil, si la app lo trae (si no, inglés).
  String get _deviceLang {
    final String sys = ui.PlatformDispatcher.instance.locale.languageCode;
    return AppLocalizations.supportedLocales.any(
          (Locale l) => l.languageCode == sys,
        )
        ? sys
        : 'en';
  }

  /// Lo que pide la página.
  void _onMessage(String m) {
    final SettingsController settings = SettingsScope.of(context);
    final List<String> p = m.split(':');
    switch (p.first) {
      case 'back':
        if (context.canPop()) context.pop();
      case 'lang' when p.length > 1:
        final String code = p[1];
        final bool known = AppLocalizations.supportedLocales.any(
          (Locale l) => l.toLanguageTag() == code,
        );
        if (code == 'system') {
          unawaited(settings.setLocale(null));
        } else if (known) {
          unawaited(settings.setLocale(Locale(code)));
        }
      case 'ai' when p.length > 1:
        // Apagado: Flyra y las audioguías se quedan en el idioma de ahora.
        unawaited(
          _services.prefs
              .writeData(
                LocalData.contentLang,
                p[1] == '1'
                    ? null
                    : Localizations.localeOf(context).languageCode,
              )
              .then((_) {
                if (mounted) setState(() {});
              }),
        );
    }
  }

  Map<String, Object?> _data(AppLocalizations t) {
    final SettingsController settings = SettingsScope.of(context);
    final String appLang = Localizations.localeOf(context).languageCode;
    final String? name = displayName(SessionScope.of(context).user?.email);
    final DateTime now = DateTime.now();
    // La lista sale del código generado: añadir un .arb lo añade aquí solo.
    final List<String> codes = <String>[
      for (final Locale l in AppLocalizations.supportedLocales) l.languageCode,
    ]..sort((String a, String b) => endonymFor(a).compareTo(endonymFor(b)));
    final String device = _deviceLang;
    final Map<String, Object?> system = languageRow(device, appLang, now, name)
      ..['code'] = 'system'
      ..['native'] = t.languageSystem
      ..['sub'] = endonymFor(device);
    return <String, Object?>{
      'title': t.languageTitle,
      'sub': 'La app, Flyra y las audioguías en tu idioma',
      'hint': t.languageSearchHint,
      'allH': 'TODOS LOS IDIOMAS',
      'aiTxt': 'Flyra y las audioguías también en este idioma',
      'none': t.languageNoResults('{q}'),
      'sel': settings.locale?.languageCode ?? 'system',
      'ai': _services.prefs.readData(LocalData.contentLang) == null,
      'langs': <Object?>[
        system,
        for (final String c in codes) languageRow(c, appLang, now, name),
      ],
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
    final String push = languagePushScript(data);
    if (_html == null) {
      _html = languagePageWith(page, data);
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
