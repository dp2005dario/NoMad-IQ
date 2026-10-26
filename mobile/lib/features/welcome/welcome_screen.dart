// Bienvenida: lo primero que ve alguien que abre la app.
// Un vídeo a pantalla completa en bucle (amigos, vuelos, el móvil de Flyra),
// con un degradado oscuro abajo para que se lean el logo, el nombre ECLIPTA,
// el titular y los botones de entrar. Si el vídeo no carga (o en los tests),
// se ve un fondo oscuro liso y todo lo demás funciona igual.
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../auth/session.dart';
import '../../core/router.dart';
import '../../core/services.dart';
import '../../core/theme.dart';
import '../../l10n/generated/app_localizations.dart';
import 'welcome_video.dart';

class WelcomeScreen extends StatefulWidget {
  const WelcomeScreen({super.key});

  @override
  State<WelcomeScreen> createState() => _WelcomeScreenState();
}

class _WelcomeScreenState extends State<WelcomeScreen> {
  WelcomeVideo? _video;
  bool _started = false;
  bool _muted = false;

  // El auth-gateway aún no sabe validar cuentas de Google (llega en otro PR):
  // de momento se explica con un aviso breve en vez de un botón que no hace nada.
  void _googleSoon(BuildContext context) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(AppLocalizations.of(context).googleSoon)),
      );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Se crea una sola vez, la primera que la pantalla puede leer los servicios.
    if (_started) return;
    _started = true;
    try {
      _video = ServicesScope.of(context).newWelcomeVideo?.call();
    } catch (_) {
      _video = null; // si falla, fondo oscuro
    }
  }

  @override
  void dispose() {
    _video?.dispose();
    super.dispose();
  }

  void _toggleMute() {
    setState(() => _muted = !_muted);
    _video?.setMuted(_muted);
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    final TextTheme text = Theme.of(context).textTheme;
    final WelcomeVideo? video = _video;
    return Scaffold(
      backgroundColor: NomadColors.background,
      body: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          // 1) El vídeo (aparece suave cuando ya está listo). Mientras tanto,
          // o si falla, se ve el color de fondo del Scaffold.
          if (video != null)
            ExcludeSemantics(
              child: ValueListenableBuilder<bool>(
                valueListenable: video.ready,
                builder: (BuildContext context, bool ready, Widget? _) =>
                    AnimatedOpacity(
                      opacity: ready ? 1 : 0,
                      duration: const Duration(milliseconds: 600),
                      child: ready
                          ? video.buildView()
                          : const SizedBox.expand(),
                    ),
              ),
            ),
          // 2) Degradado: transparente arriba, #0B1217 abajo.
          const ExcludeSemantics(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: <Color>[
                    Color(0x660B1217),
                    Color(0x000B1217),
                    Color(0xE60B1217),
                    NomadColors.background,
                  ],
                  stops: <double>[0, 0.3, 0.68, 0.9],
                ),
              ),
            ),
          ),
          // 3) El contenido. LayoutBuilder + minHeight: ocupa toda la altura
          // (el texto queda abajo) y, si la letra es gigante, se desplaza.
          SafeArea(
            child: LayoutBuilder(
              builder: (BuildContext context, BoxConstraints box) =>
                  SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
                    child: ConstrainedBox(
                      constraints: BoxConstraints(
                        minHeight: box.maxHeight - 32,
                      ),
                      child: IntrinsicHeight(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: <Widget>[
                            Row(
                              children: <Widget>[
                                IconButton.filledTonal(
                                  onPressed: () =>
                                      context.push(Routes.language),
                                  tooltip: t.languageTitle,
                                  icon: const Icon(Icons.translate_rounded),
                                ),
                                const Spacer(),
                                // Botón pequeño de silenciar: solo si hay vídeo.
                                if (video != null)
                                  ValueListenableBuilder<bool>(
                                    valueListenable: video.ready,
                                    builder:
                                        (
                                          BuildContext context,
                                          bool ready,
                                          Widget? _,
                                        ) => ready
                                        ? IconButton.filledTonal(
                                            onPressed: _toggleMute,
                                            tooltip: _muted
                                                ? t.welcomeUnmute
                                                : t.welcomeMute,
                                            icon: Icon(
                                              _muted
                                                  ? Icons.volume_off_rounded
                                                  : Icons.volume_up_rounded,
                                            ),
                                          )
                                        : const SizedBox.shrink(),
                                  ),
                              ],
                            ),
                            const Spacer(),
                            // El logo Eclipta Spark (la golondrina con la estrella).
                            ExcludeSemantics(
                              child: Image.asset(
                                'assets/brand/eclipta_spark.png',
                                height: 96,
                                errorBuilder: (_, _, _) =>
                                    const SizedBox(height: 96),
                              ),
                            ),
                            const SizedBox(height: 4),
                            // El nombre de la app. letterSpacing separa las letras.
                            Text(
                              t.appTitle,
                              textAlign: TextAlign.center,
                              style: text.displaySmall?.copyWith(
                                fontSize: 40,
                                letterSpacing: 9,
                              ),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              t.welcomeHeadline,
                              textAlign: TextAlign.center,
                              style: text.titleMedium?.copyWith(
                                color: NomadColors.text,
                              ),
                            ),
                            const SizedBox(height: 28),
                            // Botón de Google: blanco, con la G oficial multicolor.
                            FilledButton.icon(
                              onPressed: () => _googleSoon(context),
                              style: FilledButton.styleFrom(
                                backgroundColor: Colors.white,
                                foregroundColor: const Color(0xFF1F1F1F),
                              ),
                              icon: Image.asset(
                                'assets/brand/google_g.png',
                                width: 22,
                                height: 22,
                                excludeFromSemantics: true,
                                errorBuilder: (_, _, _) =>
                                    const Icon(Icons.account_circle_rounded),
                              ),
                              label: Text(t.continueWithGoogle),
                            ),
                            const SizedBox(height: 12),
                            OutlinedButton.icon(
                              onPressed: () => context.push(Routes.signIn),
                              icon: const Icon(Icons.mail_rounded),
                              label: Text(t.continueWithEmail),
                            ),
                            const SizedBox(height: 12),
                            TextButton(
                              // El router ve "invitado" y lleva a Inicio.
                              onPressed: () =>
                                  SessionScope.read(context).continueAsGuest(),
                              child: Text(t.continueAsGuest),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
            ),
          ),
        ],
      ),
    );
  }
}
