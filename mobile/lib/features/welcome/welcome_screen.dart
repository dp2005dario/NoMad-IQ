// Bienvenida: lo primero que ve alguien que abre la app (maqueta 1).
// Presenta a Flyra y ofrece entrar con Google, con correo o como invitado.
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/router.dart';
import '../../core/theme.dart';
import '../../l10n/generated/app_localizations.dart';
import '../../widgets/flyra_avatar.dart';

class WelcomeScreen extends StatelessWidget {
  const WelcomeScreen({super.key});

  // Aún no hay inicio de sesión real (llega con el auth-gateway en otro PR):
  // de momento se explica con un aviso breve en vez de un botón que no hace nada.
  void _signInSoon(BuildContext context) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(AppLocalizations.of(context).signInSoon)),
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
              const SizedBox(height: 32),
              Text(t.appTitle, style: text.displaySmall),
              const SizedBox(height: 8),
              Text(
                t.welcomeTagline,
                style: text.titleMedium?.copyWith(color: NomadColors.textMuted),
              ),
              const SizedBox(height: 40),
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
                onPressed: () => _signInSoon(context),
                icon: const Icon(Icons.account_circle_rounded),
                label: Text(t.continueWithGoogle),
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: () => _signInSoon(context),
                icon: const Icon(Icons.mail_rounded),
                label: Text(t.continueWithEmail),
              ),
              const SizedBox(height: 12),
              TextButton(
                onPressed: () => context.go(Routes.home),
                child: Text(t.continueAsGuest),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
