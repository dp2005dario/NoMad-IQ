// El "mapa de direcciones" de la app: qué pantalla se abre en cada ruta.
// Funciona como las direcciones de una web (/home, /map...). Ventaja: un aviso
// push o un enlace pueden abrir directamente cualquier pantalla.
import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';

import '../features/coming_soon/coming_soon_screen.dart';
import '../features/home/home_screen.dart';
import '../features/settings/language_screen.dart';
import '../features/shell/app_shell.dart';
import '../features/welcome/welcome_screen.dart';

/// Rutas con nombre fijo: si algún día cambia una dirección, se cambia aquí.
abstract final class Routes {
  static const String welcome = '/welcome';
  static const String home = '/home';
  static const String map = '/map';
  static const String camera = '/camera';
  static const String flights = '/flights';
  static const String group = '/group';
  static const String language = '/settings/language';

  /// Pantalla "Muy pronto" de una función aún sin construir.
  static String soon(Feature feature) => '/soon/${feature.name}';
}

GoRouter buildRouter({String initialLocation = Routes.welcome}) => GoRouter(
  initialLocation: initialLocation,
  routes: <RouteBase>[
    GoRoute(
      path: Routes.welcome,
      builder: (BuildContext context, GoRouterState state) =>
          const WelcomeScreen(),
    ),
    // Las 5 pestañas de abajo. "indexedStack" mantiene viva cada pestaña:
    // si vas al Mapa y vuelves a Inicio, Inicio sigue donde lo dejaste.
    StatefulShellRoute.indexedStack(
      builder: (
        BuildContext context,
        GoRouterState state,
        StatefulNavigationShell shell,
      ) => AppShell(shell: shell),
      branches: <StatefulShellBranch>[
        _tab(Routes.home, (_) => const HomeScreen()),
        _tab(Routes.map, (_) => const ComingSoonScreen(feature: Feature.map)),
        _tab(
          Routes.camera,
          (_) => const ComingSoonScreen(feature: Feature.camera),
        ),
        _tab(
          Routes.flights,
          (_) => const ComingSoonScreen(feature: Feature.flights),
        ),
        _tab(
          Routes.group,
          (_) => const ComingSoonScreen(feature: Feature.group),
        ),
      ],
    ),
    GoRoute(
      path: Routes.language,
      builder: (BuildContext context, GoRouterState state) =>
          const LanguageScreen(),
    ),
    GoRoute(
      path: '/soon/:feature',
      builder: (BuildContext context, GoRouterState state) {
        // Si alguien escribe una dirección inventada, se va a Inicio
        // en vez de romper la app.
        final Feature? feature = Feature.values
            .asNameMap()[state.pathParameters['feature']];
        return feature == null
            ? const HomeScreen()
            : ComingSoonScreen(feature: feature, standalone: true);
      },
    ),
  ],
);

StatefulShellBranch _tab(String path, Widget Function(BuildContext) page) =>
    StatefulShellBranch(
      routes: <RouteBase>[
        GoRoute(
          path: path,
          builder: (BuildContext context, GoRouterState state) => page(context),
        ),
      ],
    );
