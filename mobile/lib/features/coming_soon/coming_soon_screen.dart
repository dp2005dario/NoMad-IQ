// Pantalla provisional para las funciones que llegan en los próximos PRs.
// Así la navegación completa ya funciona y cada PR solo sustituye una de estas.
import 'package:flutter/material.dart';

import '../../core/theme.dart';
import '../../l10n/generated/app_localizations.dart';
import '../../widgets/flyra_avatar.dart';

/// Funciones de la app que todavía no tienen pantalla propia.
enum Feature {
  map(Icons.map_rounded, NomadColors.mint),
  camera(Icons.photo_camera_rounded, NomadColors.mint),
  flights(Icons.flight_rounded, NomadColors.flights),
  group(Icons.groups_rounded, NomadColors.group),
  vault(Icons.lock_rounded, NomadColors.safety),
  expenses(Icons.receipt_long_rounded, NomadColors.money),
  audioguides(Icons.headphones_rounded, NomadColors.mint),
  flyra(Icons.auto_awesome_rounded, NomadColors.group);

  const Feature(this.icon, this.color);

  final IconData icon;
  final Color color;

  /// Nombre traducido (los textos SIEMPRE salen de los archivos .arb).
  String label(AppLocalizations t) => switch (this) {
    Feature.map => t.navMap,
    Feature.camera => t.navCamera,
    Feature.flights => t.navFlights,
    Feature.group => t.navGroup,
    Feature.vault => t.shortcutVault,
    Feature.expenses => t.shortcutExpenses,
    Feature.audioguides => t.shortcutAudioguides,
    Feature.flyra => t.talkToFlyra,
  };
}

class ComingSoonScreen extends StatelessWidget {
  const ComingSoonScreen({
    super.key,
    required this.feature,
    this.standalone = false,
  });

  final Feature feature;

  /// true si se abre fuera de las pestañas (necesita su propia flecha "atrás").
  final bool standalone;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    final TextTheme text = Theme.of(context).textTheme;
    return Scaffold(
      appBar: standalone ? AppBar(title: Text(feature.label(t))) : null,
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Icon(feature.icon, size: 72, color: feature.color),
                const SizedBox(height: 24),
                Text(
                  t.comingSoonTitle,
                  style: text.headlineMedium,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 12),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    const FlyraAvatar(size: 28),
                    const SizedBox(width: 10),
                    Flexible(
                      child: Text(
                        t.comingSoonBody(feature.label(t)),
                        style: text.bodyLarge?.copyWith(
                          color: NomadColors.textMuted,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
