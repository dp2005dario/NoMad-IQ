// El "mapa de direcciones" de la app: qué pantalla se abre en cada ruta.
// Funciona como las direcciones de una web (/home, /map...). Ventaja: un aviso
// push o un enlace pueden abrir directamente cualquier pantalla.
import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';

import '../auth/session.dart';
import '../features/audioguide/audioguide_screen.dart';
import '../features/auth/sign_in_screen.dart';
import '../features/coming_soon/coming_soon_screen.dart';
import '../features/flights/fare_alerts_screen.dart';
import '../features/flights/fare_route_screen.dart';
import '../features/flights/flight_search_screen.dart';
import '../features/route/flight_route_screen.dart';
import '../features/flights/fares_api.dart';
import '../features/flights/flights_screen.dart';
import '../features/home/home_screen.dart';
import '../features/map/map_screen.dart';
import '../features/settings/language_screen.dart';
import '../features/shell/app_shell.dart';
import '../features/welcome/welcome_screen.dart';
import 'services.dart';

/// Rutas con nombre fijo: si algún día cambia una dirección, se cambia aquí.
abstract final class Routes {
  static const String welcome = '/welcome';
  static const String home = '/home';
  static const String map = '/map';
  static const String camera = '/camera';
  static const String flights = '/flights';
  static const String group = '/group';
  static const String language = '/settings/language';
  static const String signIn = '/signin';

  /// La audioguía de una zona. El nombre va en la dirección para poder
  /// enseñarlo en el título mientras se carga el resto.
  static String audioguide(String zoneId, String zoneName) => Uri(
    path: '/audioguide/${Uri.encodeComponent(zoneId)}',
    queryParameters: <String, String>{'name': zoneName},
  ).toString();

  /// Tus alertas de precio de vuelos (también al tocar la notificación).
  static const String fareAlerts = '/fares/alerts';

  /// El buscador de vuelos. Todo es opcional: rellena el formulario de
  /// entrada (from/to = aeropuertos, dep/ret = días "2026-12-15").
  static String fareSearch({
    String? origin,
    String? destination,
    String? departure,
    String? returnDate,
  }) {
    final Map<String, String> q = <String, String>{
      'from': ?origin,
      'to': ?destination,
      'dep': ?departure,
      'ret': ?returnDate,
    };
    return Uri(
      path: '/fares/search',
      queryParameters: q.isEmpty ? null : q,
    ).toString();
  }

  /// La Ruta del vuelo en el mapamundi (sin destino, se pregunta).
  static String flightRoute({required String from, String? to}) => Uri(
    path: '/fares/map',
    queryParameters: <String, String>{'from': from, 'to': ?to},
  ).toString();

  /// El detalle de una ruta de vuelo ("MAD-NRT:2026-12-15:ECONOMY").
  static String fareRoute(String routeKey) =>
      '/fares/route/${Uri.encodeComponent(routeKey)}';

  /// Pantalla "Muy pronto" de una función aún sin construir.
  static String soon(Feature feature) => '/soon/${feature.name}';
}

/// "2026-12-15" → fecha (solo ese formato; cualquier otra cosa, null).
DateTime? _day(String? raw) =>
    raw != null && RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(raw)
    ? DateTime.tryParse(raw)
    : null;

/// Pantallas que se pueden ver sin haber entrado (ni como invitado).
const Set<String> _public = <String>{
  Routes.welcome,
  Routes.signIn,
  Routes.language,
};

GoRouter buildRouter({
  required SessionController session,
  String initialLocation = Routes.welcome,
}) => GoRouter(
  initialLocation: initialLocation,
  // Cada vez que la sesión cambia (entrar, salir, caducar), el router
  // vuelve a pasar por "redirect" y lleva a la pantalla que toca.
  refreshListenable: session,
  redirect: (BuildContext context, GoRouterState state) =>
      sessionRedirect(session.status, state.matchedLocation),
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
        _tab(Routes.map, (_) => const MapScreen()),
        _tab(
          Routes.camera,
          (_) => const ComingSoonScreen(feature: Feature.camera),
        ),
        _tab(Routes.flights, (_) => const FlightsScreen()),
        _tab(
          Routes.group,
          (_) => const ComingSoonScreen(feature: Feature.group),
        ),
      ],
    ),
    GoRoute(
      path: Routes.signIn,
      builder: (BuildContext context, GoRouterState state) =>
          const SignInScreen(),
    ),
    GoRoute(
      path: Routes.language,
      builder: (BuildContext context, GoRouterState state) =>
          const LanguageScreen(),
    ),
    GoRoute(
      path: '/audioguide/:zoneId',
      builder: (BuildContext context, GoRouterState state) => AudioguideScreen(
        zoneId: state.pathParameters['zoneId'] ?? '',
        zoneName: state.uri.queryParameters['name'] ?? '',
      ),
    ),
    GoRoute(
      path: Routes.fareAlerts,
      builder: (BuildContext context, GoRouterState state) =>
          const FareAlertsScreen(),
    ),
    GoRoute(
      path: '/fares/map',
      builder: (BuildContext context, GoRouterState state) {
        final String? to = state.uri.queryParameters['to'];
        final AppServices services = ServicesScope.of(context);
        return FlightRouteScreen(
          from: state.uri.queryParameters['from'] ?? '',
          to: to == null || to.isEmpty ? null : to,
          places: services.places.get,
          openLink: services.openBooking,
          scene3d: services.webScene,
        );
      },
    ),
    GoRoute(
      path: '/fares/search',
      builder: (BuildContext context, GoRouterState state) =>
          FlightSearchScreen(
            origin: state.uri.queryParameters['from'],
            destination: state.uri.queryParameters['to'],
            departure: _day(state.uri.queryParameters['dep']),
            returnDate: _day(state.uri.queryParameters['ret']),
          ),
    ),
    GoRoute(
      path: '/fares/route/:key',
      builder: (BuildContext context, GoRouterState state) => FareRouteScreen(
        routeKey: state.pathParameters['key'] ?? '',
        // "extra" solo existe si se abrió desde la app (no al reabrirla).
        fare: state.extra is Fare ? state.extra! as Fare : null,
      ),
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

/// El "portero": decide a dónde va cada uno según su sesión.
/// - Sin sesión: solo Bienvenida, Iniciar sesión e Idioma.
/// - Con sesión: la Bienvenida y el login ya no pintan nada, a Inicio.
/// - Invitado: puede ir a Iniciar sesión para crear su cuenta.
String? sessionRedirect(SessionStatus status, String location) {
  switch (status) {
    case SessionStatus.signedOut:
      return _public.contains(location) ? null : Routes.welcome;
    case SessionStatus.guest:
      return location == Routes.welcome ? Routes.home : null;
    case SessionStatus.signedIn:
      return location == Routes.welcome || location == Routes.signIn
          ? Routes.home
          : null;
  }
}
