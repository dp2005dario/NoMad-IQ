// Inicio (maqueta 2): saludo, la caja para preguntar a Flyra y los atajos.
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../auth/session.dart';
import '../../core/router.dart';
import '../../core/theme.dart';
import '../../l10n/generated/app_localizations.dart';
import '../../widgets/flyra_avatar.dart';
import '../coming_soon/coming_soon_screen.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    final TextTheme text = Theme.of(context).textTheme;
    final SessionController session = SessionScope.of(context);
    final String? name = displayName(session.user?.email);
    return Scaffold(
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 24, 20, 120),
          children: <Widget>[
            Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    name == null
                        ? t.homeGreetingGuest
                        : t.homeGreetingName(name),
                    style: text.headlineMedium,
                  ),
                ),
                _AccountButton(session: session, name: name),
              ],
            ),
            const SizedBox(height: 20),
            _AskFlyra(
              hint: t.homeFlyraPrompt,
              label: t.talkToFlyra,
              onTap: () => context.push(Routes.flyra()),
            ),
            const SizedBox(height: 28),
            Text(t.shortcutsTitle, style: text.titleLarge),
            const SizedBox(height: 12),
            // Rejilla que se adapta: 2 columnas en móvil, más en tablet. La
            // altura de cada atajo NO es fija: con letra grande (accesibilidad)
            // o escrituras altas (árabe, hindi) crece en vez de cortarse.
            LayoutBuilder(
              builder: (BuildContext context, BoxConstraints box) {
                const double gap = 12;
                final int columns = (box.maxWidth / 200).floor().clamp(2, 6);
                final double width =
                    (box.maxWidth - gap * (columns - 1)) / columns;
                final List<Widget> tiles = <Widget>[
                  // SOS el primero: en un apuro no hay que buscarlo.
                  _Shortcut(
                    icon: Icons.sos_rounded,
                    color: const Color(0xFFE53935),
                    label: t.sosTitle,
                    onTap: () => context.push(Routes.sos),
                  ),
                  _Shortcut(
                    icon: Feature.vault.icon,
                    color: Feature.vault.color,
                    label: Feature.vault.label(t),
                    onTap: () => context.push(Routes.vault),
                  ),
                  _Shortcut(
                    icon: Icons.assignment_turned_in_rounded,
                    color: NomadColors.flights,
                    label: t.papersTitle,
                    onTap: () => context.push(Routes.papers),
                  ),
                  // Gastos: los botes compartidos (Dinero → Tu dinero).
                  _Shortcut(
                    icon: Feature.expenses.icon,
                    color: Feature.expenses.color,
                    label: Feature.expenses.label(t),
                    onTap: () => context.push(Routes.money()),
                  ),
                  // Los sellos de los monumentos que reconoce la cámara.
                  _Shortcut(
                    icon: Icons.approval_rounded,
                    color: const Color(0xFFE9C46A),
                    label: t.passportTitle,
                    onTap: () => context.push(Routes.passport),
                  ),
                  // Las audioguías viven en el Mapa: se abren al tocar una zona.
                  _Shortcut(
                    icon: Feature.audioguides.icon,
                    color: Feature.audioguides.color,
                    label: Feature.audioguides.label(t),
                    onTap: () => context.go(Routes.map),
                  ),
                  _Shortcut(
                    icon: Icons.translate_rounded,
                    color: NomadColors.flights,
                    label: t.shortcutLanguage,
                    onTap: () => context.push(Routes.language),
                  ),
                ];
                return Wrap(
                  spacing: gap,
                  runSpacing: gap,
                  children: <Widget>[
                    for (final Widget tile in tiles)
                      SizedBox(width: width, child: tile),
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

/// "dario.perez@gmail.com" -> "Dario". Solo para el saludo: la app aún no
/// pide el nombre (llegará con el perfil). Nunca se envía a ningún sitio.
String? displayName(String? email) {
  final String local = (email ?? '')
      .split('@')
      .first
      .split(RegExp(r'[._+-]'))
      .first;
  if (local.isEmpty) return null;
  return local[0].toUpperCase() + local.substring(1);
}

/// El círculo con tu inicial (maquetas: "tu avatar D en cada pantalla").
/// Abre Ajustes: idioma, Bóveda, cerrar sesión, borrar la cuenta...
class _AccountButton extends StatelessWidget {
  const _AccountButton({required this.session, required this.name});

  final SessionController session;
  final String? name;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    final String? initial = name?.characters.first;
    return IconButton(
      tooltip: t.accountMenu,
      onPressed: () => context.push(Routes.settings),
      icon: CircleAvatar(
        backgroundColor: NomadColors.group,
        foregroundColor: NomadColors.background,
        child: initial == null
            ? const Icon(Icons.person_rounded)
            : Text(initial),
      ),
    );
  }
}

class _AskFlyra extends StatelessWidget {
  const _AskFlyra({
    required this.hint,
    required this.label,
    required this.onTap,
  });

  final String hint;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: label,
      excludeSemantics: true,
      child: Material(
        color: NomadColors.surfaceHigh,
        shape: const StadiumBorder(),
        child: InkWell(
          customBorder: const StadiumBorder(),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Row(
              children: <Widget>[
                const FlyraAvatar(size: 40),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    hint,
                    style: const TextStyle(color: NomadColors.textMuted),
                  ),
                ),
                const Padding(
                  padding: EdgeInsetsDirectional.only(end: 8),
                  child: Icon(Icons.mic_rounded, color: NomadColors.mint),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Shortcut extends StatelessWidget {
  const _Shortcut({
    required this.icon,
    required this.color,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final Color color;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Icon(icon, color: color, size: 28),
              const SizedBox(height: 20),
              Text(
                label,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
