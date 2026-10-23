// El "marco" que rodea las pestañas principales: la barra de abajo con
// Inicio, Mapa, la CÁMARA en grande en el centro, Vuelos y Grupo (maquetas).
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme.dart';
import '../../l10n/generated/app_localizations.dart';

class AppShell extends StatelessWidget {
  const AppShell({super.key, required this.shell});

  /// Sabe qué pestaña está abierta y cómo cambiar a otra.
  final StatefulNavigationShell shell;

  // Posiciones de las pestañas (mismo orden que las ramas en router.dart).
  static const int _home = 0;
  static const int _map = 1;
  static const int _camera = 2;
  static const int _flights = 3;
  static const int _group = 4;

  void _go(int index) => shell.goBranch(
    index,
    // Pulsar la pestaña en la que ya estás vuelve a su pantalla inicial.
    initialLocation: index == shell.currentIndex,
  );

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    return Scaffold(
      body: shell,
      floatingActionButtonLocation: FloatingActionButtonLocation.centerDocked,
      floatingActionButton: FloatingActionButton.large(
        onPressed: () => _go(_camera),
        tooltip: t.navCamera,
        backgroundColor: NomadColors.mint,
        foregroundColor: NomadColors.background,
        shape: const CircleBorder(),
        child: const Icon(Icons.photo_camera_rounded, size: 36),
      ),
      bottomNavigationBar: BottomAppBar(
        color: NomadColors.surface,
        shape: const CircularNotchedRectangle(), // el hueco para la cámara
        notchMargin: 8,
        child: Row(
          children: <Widget>[
            _Tab(Icons.home_rounded, t.navHome, _home, shell.currentIndex, _go),
            _Tab(Icons.map_rounded, t.navMap, _map, shell.currentIndex, _go),
            const SizedBox(width: 88), // espacio bajo el botón de la cámara
            _Tab(
              Icons.flight_rounded,
              t.navFlights,
              _flights,
              shell.currentIndex,
              _go,
            ),
            _Tab(
              Icons.groups_rounded,
              t.navGroup,
              _group,
              shell.currentIndex,
              _go,
            ),
          ],
        ),
      ),
    );
  }
}

class _Tab extends StatelessWidget {
  const _Tab(this.icon, this.label, this.index, this.current, this.onTap);

  final IconData icon;
  final String label;
  final int index;
  final int current;
  final void Function(int) onTap;

  @override
  Widget build(BuildContext context) {
    final bool selected = index == current;
    final Color color = selected ? NomadColors.mint : NomadColors.textMuted;
    return Expanded(
      child: Semantics(
        selected: selected,
        button: true,
        child: InkResponse(
          onTap: () => onTap(index),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(icon, color: color),
              const SizedBox(height: 2),
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis, // por si el idioma es largo
                style: TextStyle(color: color, fontSize: 12),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
