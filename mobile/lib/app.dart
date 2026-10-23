// La app en sí: une el tema, los idiomas, los ajustes y las rutas.
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:go_router/go_router.dart';

import 'auth/session.dart';
import 'core/router.dart';
import 'core/services.dart';
import 'core/settings.dart';
import 'core/theme.dart';
import 'l10n/generated/app_localizations.dart';

class NomadIqApp extends StatefulWidget {
  const NomadIqApp({
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
  State<NomadIqApp> createState() => _NomadIqAppState();
}

class _NomadIqAppState extends State<NomadIqApp> {
  // Se crea UNA vez: si se recreara en cada dibujado, se perdería la pantalla actual.
  late final GoRouter _router =
      widget.router ?? buildRouter(session: widget.session);

  @override
  void dispose() {
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
