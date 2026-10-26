// Bienvenida: lo primero que ve alguien que abre la app (maqueta v7, ECLIPTA).
// Un eclipse con Flyra dentro y el nombre ECLIPTA. Presenta a Flyra y ofrece entrar con Google, con correo o como invitado.
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../auth/session.dart';
import '../../core/router.dart';
import '../../core/theme.dart';
import '../../l10n/generated/app_localizations.dart';
import '../../widgets/flyra_avatar.dart';

class WelcomeScreen extends StatelessWidget {
  const WelcomeScreen({super.key});

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
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    final TextTheme text = Theme.of(context).textTheme;
    return Scaffold(
      body: SafeArea(
        // SingleChildScrollView: si la letra del móvil es gigante (accesibilidad)
        // o la pantalla es pequeña, se puede desplazar en vez de cortarse.
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(24, 48, 24, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: IconButton.filledTonal(
                  onPressed: () => context.push(Routes.language),
                  tooltip: t.languageTitle,
                  icon: const Icon(Icons.translate_rounded),
                ),
              ),
              const SizedBox(height: 24),
              // El eclipse: un círculo oscuro con el borde menta y un resplandor
              // detrás; dentro va Flyra.
              const Center(child: _Eclipse()),
              const SizedBox(height: 32),
              // El nombre de la app. letterSpacing separa las letras.
              Text(
                'ECLIPTA',
                textAlign: TextAlign.center,
                style: text.displaySmall?.copyWith(
                  fontSize: 44,
                  letterSpacing: 9,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                t.welcomeTagline,
                textAlign: TextAlign.center,
                style: text.titleMedium?.copyWith(color: NomadColors.textMuted),
              ),
              const SizedBox(height: 32),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Row(
                    children: <Widget>[
                      FlyraAvatar(size: 56, semanticLabel: t.talkToFlyra),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Text(t.welcomeFlyraIntro, style: text.bodyLarge),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 40),
              FilledButton.icon(
                onPressed: () => _googleSoon(context),
                icon: const Icon(Icons.account_circle_rounded),
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
                onPressed: () => SessionScope.read(context).continueAsGuest(),
                child: Text(t.continueAsGuest),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// El dibujo del eclipse (solo decoración, el lector de pantalla lo salta).
class _Eclipse extends StatelessWidget {
  const _Eclipse();

  @override
  Widget build(BuildContext context) {
    return ExcludeSemantics(
      child: SizedBox.square(
        dimension: 200,
        child: Stack(
          alignment: Alignment.center,
          children: <Widget>[
            // Resplandor: un círculo menta difuminado (blur) y suave.
            ImageFiltered(
              imageFilter: ImageFilter.blur(sigmaX: 28, sigmaY: 28),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: NomadColors.mint.withValues(alpha: 0.45),
                ),
                child: const SizedBox.square(dimension: 190),
              ),
            ),
            // La luna oscura con la corona menta.
            const DecoratedBox(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: NomadColors.background,
                border: Border.fromBorderSide(
                  BorderSide(color: NomadColors.mint, width: 3),
                ),
              ),
              child: SizedBox.square(dimension: 184),
            ),
            const FlyraAvatar(size: 124),
          ],
        ),
      ),
    );
  }
}
