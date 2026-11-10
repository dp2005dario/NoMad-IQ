// Pone la barra de abajo (Inicio, Mapa, Cámara, Vuelos, Grupo) también en
// las pantallas que se abren encima de las pestañas, como en cualquier app:
// desde Hoteles o la Bóveda puedes saltar a Inicio sin ir "atrás" mil veces.
//
// No sale en las propias pestañas (ya tienen la suya), ni en la bienvenida,
// el inicio de sesión, las cámaras a pantalla completa o el SOS. Tampoco
// mientras escribes (con el teclado abierto se esconde para dejar sitio).
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';

import '../../core/router.dart';
import 'app_shell.dart';

/// Las direcciones (exactas) donde NO va esta barra.
const Set<String> _noBar = <String>{
  '',
  '/',
  Routes.home,
  Routes.map,
  Routes.camera,
  Routes.flights,
  Routes.group,
  Routes.welcome,
  Routes.signIn,
  Routes.travelCamera,
  Routes.sos,
};

/// Las pestañas, en el orden de la barra.
const List<String> shellTabs = <String>[
  Routes.home,
  Routes.map,
  Routes.camera,
  Routes.flights,
  Routes.group,
];

/// ¿Lleva barra la pantalla de [path]?
bool showsGlobalTabBar(String path) => !_noBar.contains(path);

class GlobalTabBar extends StatelessWidget {
  const GlobalTabBar({
    super.key,
    required this.location,
    required this.onTab,
    required this.child,
  });

  /// La dirección de la pantalla de arriba (la apunta app.dart).
  final ValueListenable<String> location;
  final void Function(String path) onTab;
  final Widget child;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<String>(
    valueListenable: location,
    child: child,
    builder: (BuildContext context, String path, Widget? page) {
      final MediaQueryData mq = MediaQuery.of(context);
      final bool show = showsGlobalTabBar(path) && mq.viewInsets.bottom == 0;
      return ColoredBox(
        color: const Color(0xFF0B1217),
        child: Column(
          children: <Widget>[
            Expanded(
              child: MediaQuery.removePadding(
                context: context,
                removeBottom: show,
                child: page!,
              ),
            ),
            if (show) ShellTabBar(onTab: (int i) => onTab(shellTabs[i])),
          ],
        ),
      );
    },
  );
}
