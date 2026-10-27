// La app en sí: une el tema, los idiomas, los ajustes y las rutas.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:go_router/go_router.dart';

import 'auth/session.dart';
import 'core/router.dart';
import 'core/services.dart';
import 'core/settings.dart';
import 'core/theme.dart';
import 'features/map/location.dart';
import 'features/widgets/widget_sync.dart';
import 'l10n/generated/app_localizations.dart';

class EcliptaApp extends StatefulWidget {
  const EcliptaApp({
    super.key,
    required this.settings,
    required this.session,
    required this.services,
    this.router,
  });

  final SettingsController settings;
  final SessionController session;

  /// Servidor, GPS, mapa y altavoz (ver core/services.dart).
  final AppServices services;

  /// Los tests pueden pasar un router que empiece en otra pantalla.
  final GoRouter? router;

  @override
  State<EcliptaApp> createState() => _EcliptaAppState();
}

class _EcliptaAppState extends State<EcliptaApp> {
  // Se crea UNA vez: si se recreara en cada dibujado, se perdería la pantalla actual.
  late final GoRouter _router =
      widget.router ?? buildRouter(session: widget.session);
  AppLifecycleListener? _lifecycle;
  StreamSubscription<String>? _taps;

  // Para poner al día los widgets del escritorio hacen falta los textos en
  // el idioma de la app; se guardan aquí al dibujar (ver builder).
  AppLocalizations? _t;
  String? _locale;
  DateTime? _widgetsAt;

  @override
  void initState() {
    super.initState();
    final AppServices services = widget.services;
    // El GPS se apaga al salir de la app (salvo en modo viaje) y vuelve al
    // entrar. Se decide aquí, para toda la app, y no en cada pantalla.
    _lifecycle = AppLifecycleListener(
      onPause: () => unawaited(services.tracker.paused()),
      onResume: () {
        unawaited(services.tracker.appResumed());
        unawaited(_syncWidgets());
      },
    );
    // Si el modo viaje quedó encendido, sigue al abrir la app. Tras el
    // primer dibujado: así su notificación fija ya sale traducida.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(services.tracker.appResumed());
      unawaited(_syncWidgets());
    });
    // Tocar una notificación abre su pantalla (audioguía, mapa...).
    _taps = services.notices.taps.listen(_open);
    unawaited(services.notices.launchRoute().then(_openLater));
  }

  void _openLater(String? route) {
    if (route == null) return;
    // Se espera al primer dibujado: antes no hay pantalla sobre la que abrir.
    WidgetsBinding.instance.addPostFrameCallback((_) => _open(route));
  }

  void _open(String route) {
    if (!mounted) return;
    unawaited(_router.push(route));
  }

  /// Widgets del escritorio y aviso del vuelo al día. Como mucho cada 10
  /// minutos (abrir y cerrar la app no debe llenar el servidor de
  /// peticiones), y otra vez si cambias de idioma.
  Future<void> _syncWidgets() async {
    final AppLocalizations? t = _t;
    final String? locale = _locale;
    final DateTime now = DateTime.now();
    final DateTime? last = _widgetsAt;
    if (!widget.services.syncWidgetsOnStart || t == null || locale == null) {
      return;
    }
    if (last != null && now.difference(last) < const Duration(minutes: 10)) {
      return;
    }
    _widgetsAt = now;
    try {
      await syncWidgets(widget.services, t, locale);
    } on Object {
      // Un widget sin actualizar nunca debe romper la app.
    }
  }

  void _localizeTracker(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    final String locale = Localizations.localeOf(context).toLanguageTag();
    if (locale != _locale) _widgetsAt = null;
    _t = t;
    _locale = locale;
    widget.services.tracker
      ..language = Localizations.localeOf(context).languageCode
      ..notice = TrackingNotice(
        title: t.travelServiceTitle,
        text: t.travelServiceText,
        channel: t.travelServiceChannel,
      );
  }

  @override
  void dispose() {
    _lifecycle?.dispose();
    unawaited(_taps?.cancel());
    if (widget.router == null) _router.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ServicesScope(
      services: widget.services,
      child: SessionScope(
        controller: widget.session,
        child: SettingsScope(
          controller: widget.settings,
          // ListenableBuilder redibuja la app cuando cambia un ajuste (el idioma).
          child: ListenableBuilder(
            listenable: widget.settings,
            builder: (BuildContext context, Widget? _) => MaterialApp.router(
              // El título que ve Android en "apps recientes", traducido.
              onGenerateTitle: (BuildContext context) =>
                  AppLocalizations.of(context).appTitle,
              debugShowCheckedModeBanner: false,
              theme: buildNomadTheme(),
              // null = idioma del móvil (ver resolveLocale, abajo).
              locale: widget.settings.locale,
              supportedLocales: AppLocalizations.supportedLocales,
              localeListResolutionCallback: resolveLocale,
              localizationsDelegates: const <LocalizationsDelegate<Object>>[
                AppLocalizations.delegate,
                // Textos del propio Flutter (copiar, pegar, calendario...) y la
                // dirección del texto: en árabe o hebreo todo se dibuja de derecha
                // a izquierda (RTL) automáticamente.
                GlobalMaterialLocalizations.delegate,
                GlobalWidgetsLocalizations.delegate,
                GlobalCupertinoLocalizations.delegate,
              ],
              routerConfig: _router,
              // Justo debajo de los idiomas: el rastreador se entera del
              // idioma actual (para las posiciones y su notificación fija).
              builder: (BuildContext context, Widget? child) {
                _localizeTracker(context);
                return child ?? const SizedBox.shrink();
              },
            ),
          ),
        ),
      ),
    );
  }
}

/// Elige el idioma de la app a partir de los idiomas del móvil (en orden de
/// preferencia): el más parecido que tengamos ("es-MX" usa "es"). Si ninguno
/// coincide, inglés: sin esto Flutter usaría el PRIMERO de la lista
/// (el árabe, por orden alfabético), que es una sorpresa para casi todos.
Locale resolveLocale(List<Locale>? preferred, Iterable<Locale> supported) {
  final Set<String> codes = supported.map((Locale l) => l.languageCode).toSet();
  final bool anyMatch = (preferred ?? const <Locale>[]).any(
    (Locale l) => codes.contains(l.languageCode),
  );
  if (!anyMatch) return const Locale('en');
  return basicLocaleListResolution(preferred, supported);
}
