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
                // La campana: el historial de avisos (solo en el móvil).
                IconButton(
                  tooltip: t.noticesTitle,
                  onPressed: () => context.push(Routes.notices),
                  icon: const Icon(Icons.notifications_none_rounded),
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
                  // Todo lo que hay que tener listo antes de un viaje.
                  _Shortcut(
                    icon: Icons.luggage_rounded,
                    color: NomadColors.mint,
                    label: t.beforeTitle,
                    onTap: () => context.push(Routes.before),
                  ),
                  // Viajar con tu mascota o estando embarazada.
                  _Shortcut(
                    icon: Icons.pets_rounded,
                    color: NomadColors.money,
                    label: t.twTitle,
                    onTap: () => context.push(Routes.travelWith),
                  ),
                  // Quién viaja contigo: alergias, edades y gustos.
                  _Shortcut(
                    icon: Icons.family_restroom_rounded,
                    color: NomadColors.group,
                    label: t.famTitle,
                    onTap: () => context.push(Routes.family),
                  ),
                  // Copiar el viaje de otra persona (Flyra lo adapta).
                  _Shortcut(
                    icon: Icons.content_copy_rounded,
                    color: NomadColors.mint,
                    label: t.copyTitle,
                    onTap: () => context.push(Routes.copyTrip()),
                  ),
                  // Tus fotos y vídeos del viaje y la historia automática.
                  _Shortcut(
                    icon: Icons.photo_library_rounded,
                    color: NomadColors.mint,
                    label: t.memTitle,
                    onTap: () => context.push(Routes.memories),
                  ),
                  // Flecha a tu puerta, al baño o a un café en el aeropuerto.
                  _Shortcut(
                    icon: Icons.local_airport_rounded,
                    color: NomadColors.flights,
                    label: t.airportTitle,
                    onTap: () => context.push(Routes.airport()),
                  ),
                  // Qué te piden para entrar en otro país (ESTA, eTA...).
                  _Shortcut(
                    icon: Icons.verified_user_rounded,
                    color: NomadColors.flights,
                    label: t.visaTitle,
                    onTap: () => context.push(Routes.visa()),
                  ),
                  // Maleta perdida o escala perdida: qué hacer y la reclamación.
                  _Shortcut(
                    icon: Icons.report_problem_rounded,
                    color: NomadColors.safety,
                    label: t.troubleShort,
                    onTap: () => context.push(Routes.trouble),
                  ),
                  // Gasolineras, aparcamientos y zonas ZTL mientras conduces.
                  _Shortcut(
                    icon: Icons.directions_car_rounded,
                    color: NomadColors.money,
                    label: t.driveShort,
                    onTap: () => context.push(Routes.drive),
                  ),
                  // Planes abiertos con otros viajeros de la misma ciudad.
                  _Shortcut(
                    icon: Icons.diversity_3_rounded,
                    color: NomadColors.group,
                    label: t.meetupsShort,
                    onTap: () => context.push(Routes.meetups()),
                  ),
                  // Tu vuelo, el chollo y el presupuesto en el escritorio.
                  _Shortcut(
                    icon: Icons.widgets_rounded,
                    color: NomadColors.flights,
                    label: t.widgetsTitle,
                    onTap: () => context.push(Routes.widgets),
                  ),
                  // Liga y cambios de cromos con tus amigos.
                  _Shortcut(
                    icon: Icons.style_rounded,
                    color: NomadColors.group,
                    label: t.cardsTitle,
                    onTap: () => context.push(Routes.cards),
                  ),
                  // La carta del restaurante, traducida y explicada.
                  _Shortcut(
                    icon: Icons.restaurant_menu_rounded,
                    color: NomadColors.money,
                    label: t.menuTitle,
                    onTap: () => context.push(Routes.menu),
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
