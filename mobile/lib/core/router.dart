// El "mapa de direcciones" de la app: qué pantalla se abre en cada ruta.
// Funciona como las direcciones de una web (/home, /map...). Ventaja: un aviso
// push o un enlace pueden abrir directamente cualquier pantalla.
import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';

import '../auth/session.dart';
import '../features/vault/vault_screen.dart';
import '../features/audioguide/audioguide_screen.dart';
import '../features/camera/camera_screen.dart';
import '../features/auth/sign_in_screen.dart';
import '../features/coming_soon/coming_soon_screen.dart';
import '../features/flights/explore_screen.dart';
import '../features/flights/fare_alerts_screen.dart';
import '../features/flights/fare_route_screen.dart';
import '../features/flights/flight_search_screen.dart';
import '../features/route/flight_route_screen.dart';
import '../features/flights/fares_api.dart';
import '../features/flights/flights_screen.dart';
import '../features/flyra/flyra_chat_screen.dart';
import '../features/group/group_screen.dart';
import '../features/group/trip_create_screen.dart';
import '../features/group/trip_screen.dart';
import '../features/plans/plans_screen.dart';
import '../features/home/home_screen.dart';
import '../features/map/map_screen.dart';
import '../features/money/expense_group_screen.dart';
import '../features/money/money_screen.dart';
import '../features/settings/language_screen.dart';
import '../features/offline/offline_screen.dart';
import '../features/easy/easy_home_screen.dart';
import '../features/cards/cards_screen.dart';
import '../features/memories/memories_screen.dart';
import '../features/memories/travel_camera_screen.dart';
import '../features/airport/airport_screen.dart';
import '../features/stopover/stopover_screen.dart';
import '../features/widgets/widgets_screen.dart';
import '../features/copy_trip/copy_trip_screen.dart';
import '../features/copy_trip/share_trip_screen.dart';
import '../features/family/family_screen.dart';
import '../features/help/help_screen.dart';
import '../features/nearby/nearby_screen.dart';
import '../features/meetups/meetups_screen.dart';
import '../features/drive/drive_screen.dart';
import '../features/trouble/trouble_screen.dart';
import '../features/assistant/assistant_screen.dart';
import '../features/voice/voice_screen.dart';
import '../features/papers/papers_screen.dart';
import '../features/visa/visa_screen.dart';
import '../features/travel_with/travel_with_screen.dart';
import '../features/passport/passport_screen.dart';
import '../features/menu/menu_screen.dart';
import '../features/trip/before_screen.dart';
import '../features/push/notices_screen.dart';
import '../features/settings/privacy_screen.dart';
import '../features/settings/settings_screen.dart';
import '../features/sos/sos_screen.dart';
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
  static const String vault = '/vault';
  static const String settings = '/settings';
  static const String sos = '/sos';
  static const String papers = '/papers';
  static const String passport = '/passport';
  static const String notices = '/notices';
  static const String menu = '/menu';
  static const String before = '/before';
  static const String offline = '/offline';
  static const String travelWith = '/travel-with';
  static const String help = '/help';
  static const String family = '/family';
  static const String shareTrip = '/copy-trip/share';
  static const String cards = '/cards';
  static const String memories = '/memories';
  static const String travelCamera = '/memories/camera';
  static const String widgets = '/widgets';
  static const String nearby = '/nearby';
  static const String drive = '/drive';
  static const String trouble = '/trouble';
  static const String assistant = '/assistant';
  static const String voice = '/voice';
  static String meetups({String? city}) => Uri(
    path: '/meetups',
    queryParameters: <String, String>{'city': ?city},
  ).toString();

  /// "Copia este viaje"; con [code] abre directamente ese viaje.
  static String copyTrip({String? code}) => Uri(
    path: '/copy-trip',
    queryParameters: code == null ? null : <String, String>{'code': code},
  ).toString();

  /// Explorar: precio por meses y clima. `from` = aeropuerto de salida.
  static String explore({String? origin}) => Uri(
    path: '/explore',
    queryParameters: origin == null ? null : <String, String>{'from': origin},
  ).toString();
  static const String privacy = '/settings/privacy';

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

  /// Aeropuerto: flecha a tu puerta, al baño o a un café.
  static String airport({String? iata, String? gate}) => Uri(
    path: '/airport',
    queryParameters: <String, String>{'iata': ?iata, 'gate': ?gate},
  ).toString();

  /// Visado: qué te piden para entrar en [to] (código de país, "US").
  static String visa({String? to}) => Uri(
    path: '/visa',
    queryParameters: <String, String>{'to': ?to},
  ).toString();

  /// Escala de regalo: dónde parar unos días de camino a [to].
  static String stopover({String? from, String? to}) => Uri(
    path: '/stopover',
    queryParameters: <String, String>{'from': ?from, 'to': ?to},
  ).toString();

  /// La Ruta del vuelo en el mapamundi (sin destino, se pregunta).
  static String flightRoute({required String from, String? to}) => Uri(
    path: '/fares/map',
    queryParameters: <String, String>{'from': from, 'to': ?to},
  ).toString();

  /// El detalle de una ruta de vuelo ("MAD-NRT:2026-12-15:ECONOMY").
  static String fareRoute(String routeKey) =>
      '/fares/route/${Uri.encodeComponent(routeKey)}';

  /// Crear un viaje en grupo (al terminar devuelve el id del viaje).
  static const String groupNew = '/group/new';

  /// Un viaje en grupo por dentro (también al tocar el aviso del resultado).
  static String groupTrip(String id) =>
      '/group/trip/${Uri.encodeComponent(id)}';

  /// Elegid planes del viaje [id]; [city] es el destino elegido ("Lisboa").
  static String groupPlans(String id, {String? city}) => Uri(
    path: '/group/trip/${Uri.encodeComponent(id)}/plans',
    queryParameters: <String, String>{'city': ?city},
  ).toString();

  /// El chat con Flyra. Con `question`, la escribe ya en la caja.
  static String flyra({String? question}) => Uri(
    path: '/flyra',
    queryParameters: question == null ? null : <String, String>{'q': question},
  ).toString();

  /// Dinero (gastos, divisas...). [tab] abre una pestaña concreta.
  static String money({MoneyTab? tab}) => Uri(
    path: '/money',
    queryParameters: tab == null ? null : <String, String>{'tab': tab.name},
  ).toString();

  /// Un bote de gastos compartidos por dentro.
  static String expenseGroup(String id) =>
      '/money/group/${Uri.encodeComponent(id)}';

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
        _tab(Routes.home, (_) => const HomeOrEasy()),
        _tab(Routes.map, (_) => const MapScreen()),
        _tab(Routes.camera, (_) => const CameraScreen()),
        _tab(Routes.flights, (_) => const FlightsScreen()),
        _tab(Routes.group, (_) => const GroupScreen()),
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
      path: '/flyra',
      builder: (BuildContext context, GoRouterState state) =>
          FlyraChatScreen(draft: state.uri.queryParameters['q']),
    ),
    GoRoute(
      path: '/money',
      builder: (BuildContext context, GoRouterState state) => MoneyScreen(
        tab:
            MoneyTab.values.asNameMap()[state.uri.queryParameters['tab']] ??
            MoneyTab.expenses,
      ),
    ),
    GoRoute(
      path: '/money/group/:id',
      builder: (BuildContext context, GoRouterState state) =>
          ExpenseGroupScreen(groupId: state.pathParameters['id'] ?? ''),
    ),
    GoRoute(
      path: Routes.groupNew,
      builder: (BuildContext context, GoRouterState state) =>
          const TripCreateScreen(),
    ),
    GoRoute(
      path: '/group/trip/:id',
      builder: (BuildContext context, GoRouterState state) =>
          TripScreen(tripId: state.pathParameters['id'] ?? ''),
    ),
    GoRoute(
      path: '/group/trip/:id/plans',
      builder: (BuildContext context, GoRouterState state) => PlansScreen(
        tripId: state.pathParameters['id'] ?? '',
        city: state.uri.queryParameters['city'],
      ),
    ),
    GoRoute(
      path: Routes.settings,
      builder: (BuildContext context, GoRouterState state) =>
          const SettingsScreen(),
    ),
    GoRoute(
      path: Routes.privacy,
      builder: (BuildContext context, GoRouterState state) =>
          const PrivacyScreen(),
    ),
    GoRoute(
      path: Routes.papers,
      builder: (BuildContext context, GoRouterState state) =>
          const PapersScreen(),
    ),
    GoRoute(
      path: '/explore',
      builder: (BuildContext context, GoRouterState state) =>
          ExploreScreen(origin: state.uri.queryParameters['from'] ?? ''),
    ),
    GoRoute(
      path: Routes.before,
      builder: (BuildContext context, GoRouterState state) =>
          const BeforeTripScreen(),
    ),
    GoRoute(
      path: Routes.menu,
      builder: (BuildContext context, GoRouterState state) =>
          const MenuScreen(),
    ),
    GoRoute(
      path: Routes.notices,
      builder: (BuildContext context, GoRouterState state) =>
          const NoticesScreen(),
    ),
    GoRoute(
      path: Routes.passport,
      builder: (BuildContext context, GoRouterState state) =>
          const PassportScreen(),
    ),
    GoRoute(
      path: Routes.help,
      builder: (BuildContext context, GoRouterState state) =>
          const HelpScreen(),
    ),
    GoRoute(
      path: '/airport',
      builder: (BuildContext context, GoRouterState state) => AirportScreen(
        iata: state.uri.queryParameters['iata'],
        gate: state.uri.queryParameters['gate'],
      ),
    ),
    GoRoute(
      path: Routes.nearby,
      builder: (BuildContext context, GoRouterState state) =>
          const NearbyScreen(),
    ),
    GoRoute(
      path: Routes.voice,
      builder: (BuildContext context, GoRouterState state) =>
          const VoiceScreen(),
    ),
    GoRoute(
      path: Routes.assistant,
      builder: (BuildContext context, GoRouterState state) =>
          const AssistantScreen(),
    ),
    GoRoute(
      path: Routes.trouble,
      builder: (BuildContext context, GoRouterState state) =>
          const TroubleScreen(),
    ),
    GoRoute(
      path: Routes.drive,
      builder: (BuildContext context, GoRouterState state) =>
          const DriveScreen(),
    ),
    GoRoute(
      path: '/meetups',
      builder: (BuildContext context, GoRouterState state) =>
          MeetupsScreen(city: state.uri.queryParameters['city']),
    ),
    GoRoute(
      path: '/visa',
      builder: (BuildContext context, GoRouterState state) =>
          VisaScreen(to: state.uri.queryParameters['to']),
    ),
    GoRoute(
      path: '/stopover',
      builder: (BuildContext context, GoRouterState state) => StopoverScreen(
        from: state.uri.queryParameters['from'],
        to: state.uri.queryParameters['to'],
      ),
    ),
    GoRoute(
      path: Routes.widgets,
      builder: (BuildContext context, GoRouterState state) =>
          const WidgetsScreen(),
    ),
    GoRoute(
      path: Routes.memories,
      builder: (BuildContext context, GoRouterState state) =>
          const MemoriesScreen(),
    ),
    GoRoute(
      path: Routes.travelCamera,
      builder: (BuildContext context, GoRouterState state) =>
          const TravelCameraScreen(),
    ),
    GoRoute(
      path: Routes.cards,
      builder: (BuildContext context, GoRouterState state) =>
          const CardsScreen(),
    ),
    GoRoute(
      path: '/copy-trip',
      builder: (BuildContext context, GoRouterState state) =>
          CopyTripScreen(code: state.uri.queryParameters['code']),
    ),
    GoRoute(
      path: Routes.shareTrip,
      builder: (BuildContext context, GoRouterState state) =>
          const ShareTripScreen(),
    ),
    GoRoute(
      path: Routes.family,
      builder: (BuildContext context, GoRouterState state) =>
          const FamilyScreen(),
    ),
    GoRoute(
      path: Routes.travelWith,
      builder: (BuildContext context, GoRouterState state) =>
          const TravelWithScreen(),
    ),
    GoRoute(
      path: Routes.offline,
      builder: (BuildContext context, GoRouterState state) =>
          const OfflineScreen(),
    ),
    GoRoute(
      path: Routes.sos,
      builder: (BuildContext context, GoRouterState state) => const SosScreen(),
    ),
    GoRoute(
      path: Routes.vault,
      builder: (BuildContext context, GoRouterState state) =>
          const VaultScreen(),
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
