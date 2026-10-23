// Utilidades compartidas por los tests: montan la app sin tocar el disco
// ni la red (el "servidor" es un MockClient que responde lo que le digamos).
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nomadiq/app.dart';
import 'package:nomadiq/auth/auth_api.dart';
import 'package:nomadiq/auth/session.dart';
import 'package:nomadiq/auth/token_store.dart';
import 'package:nomadiq/core/api_client.dart';
import 'package:nomadiq/core/router.dart';
import 'package:nomadiq/core/services.dart';
import 'package:nomadiq/features/audioguide/guide_player.dart';
import 'package:nomadiq/features/flights/booking.dart';
import 'package:nomadiq/features/map/geo.dart';
import 'package:nomadiq/features/map/geo_api.dart';
import 'package:nomadiq/features/map/location.dart';
import 'package:nomadiq/features/map/location_tracker.dart';
import 'package:nomadiq/features/map/position_reporter.dart';
import 'package:nomadiq/features/push/notices.dart';
import 'package:nomadiq/features/map/map_surface.dart';
import 'package:nomadiq/core/settings.dart';

/// Un auth-gateway falso, en memoria, que se comporta como el de verdad:
/// una cuenta, pases largos de un solo uso y errores con sus códigos HTTP.
class FakeGateway {
  final Map<String, String> accounts = <String, String>{};
  final Set<String> liveRefresh = <String>{};
  final List<String> calls = <String>[];
  int _n = 0;

  /// Si se pone, TODAS las llamadas responden este código (simula averías).
  int? failWith;

  /// Respuestas de los demás servicios (geo-engine, ai-orchestrator...), por
  /// ruta. Si una ruta no está aquí, 404.
  final Map<String, http.Response Function(http.Request)> services =
      <String, http.Response Function(http.Request)>{};

  /// Rutas que la puerta de entrada deja ver sin pase (como los chollos de
  /// vuelos): empiezan por alguno de estos prefijos y son GET.
  final Set<String> publicPrefixes = <String>{};

  late final http.Client client = MockClient((http.Request req) async {
    calls.add('${req.method} ${req.url.path}');
    if (failWith != null) return http.Response('', failWith!);
    final Map<String, Object?> body = req.body.isEmpty
        ? <String, Object?>{}
        : jsonDecode(req.body) as Map<String, Object?>;
    switch (req.url.path) {
      case '/v1/auth/register':
        final String email = body['email']! as String;
        if (accounts.containsKey(email)) return http.Response('{}', 409);
        accounts[email] = body['password']! as String;
        return _json(<String, Object?>{'id': 'u1', 'email': email}, 201);
      case '/v1/auth/login':
        if (accounts[body['email']] != body['password']) {
          return http.Response('{}', 401);
        }
        return _tokens();
      case '/v1/auth/refresh':
        if (!liveRefresh.remove(body['refresh_token'])) {
          return http.Response('{}', 401);
        }
        return _tokens();
      case '/v1/auth/logout':
        liveRefresh.remove(body['refresh_token']);
        return http.Response('', 204);
      case '/v1/me':
        return _json(<String, Object?>{
          'id': 'u1',
          'email': accounts.keys.isEmpty ? 'x@y.z' : accounts.keys.first,
        });
    }
    final http.Response Function(http.Request)? service =
        services[req.url.path];
    if (service != null) {
      // Como la puerta de entrada de verdad: sin pase válido, 401 (salvo en
      // las rutas públicas, que no miran el pase).
      final bool public =
          req.method == 'GET' &&
          publicPrefixes.any((String p) => req.url.path.startsWith(p));
      final String auth = req.headers['Authorization'] ?? '';
      if (!public && !auth.startsWith('Bearer a')) {
        return http.Response('', 401);
      }
      return service(req);
    }
    return http.Response('', 404);
  });

  http.Response _tokens() {
    final String refresh = 'r${_n++}';
    liveRefresh.add(refresh);
    return _json(<String, Object?>{
      'access_token': 'a$_n',
      'token_type': 'Bearer',
      'expires_in': 900,
      'refresh_token': refresh,
      'refresh_token_expires_in': 2592000,
    });
  }

  static http.Response json(Object body, [int status = 200]) => http.Response(
    jsonEncode(body),
    status,
    headers: <String, String>{
      'content-type': 'application/json; charset=utf-8',
    },
  );

  static http.Response _json(Map<String, Object?> body, [int status = 200]) =>
      http.Response(
        jsonEncode(body),
        status,
        headers: <String, String>{'content-type': 'application/json'},
      );

  AuthApi api() =>
      AuthApi(baseUrl: Uri.parse('http://gateway.test'), client: client);
}

/// La caja de herramientas de la app, con piezas falsas: el servidor es el
/// [gateway], el GPS es [location], el mapa no dibuja nada y el reproductor
/// no suena.
AppServices fakeServices(
  SessionController session, {
  FakeGateway? gateway,
  FakeLocation? location,
  FakeMap? map,
  List<FakePlayer>? players,
  NoticeCenter? notices,
  SettingsStore? prefs,
  OpenBooking? openBooking,
}) {
  final FakeGateway g = gateway ?? FakeGateway();
  final FakeMap m = map ?? FakeMap();
  return AppServices(
    api: ApiClient(
      baseUrl: Uri.parse('http://gateway.test'),
      session: session,
      client: g.client,
    ),
    location: location ?? FakeLocation(),
    mapSurface: m.build,
    newPlayer: () {
      final FakePlayer p = FakePlayer();
      players?.add(p);
      return p;
    },
    tilesUrl: Uri.parse('https://tiles.test/planet'),
    glyphsUrl: 'https://tiles.test/fonts/{fontstack}/{range}.pbf',
    notices: notices ?? FakeNotices(),
    prefs: prefs,
    openBooking: openBooking ?? (Uri _) async => true,
  );
}

/// Notificaciones falsas: el test decide el permiso y "toca" avisos.
class FakeNotices implements NoticeCenter {
  bool allow = true;
  int asked = 0;
  String? launch;
  final StreamController<String> tapsController =
      StreamController<String>.broadcast();

  @override
  Future<bool> requestPermission() async {
    asked++;
    return allow;
  }

  @override
  Stream<String> get taps => tapsController.stream;

  @override
  Future<String?> launchRoute() async => launch;
}

/// Un GPS falso: el test decide la respuesta al permiso y manda posiciones.
class FakeLocation implements LocationSource {
  LocationAccess access = LocationAccess.denied;

  /// Lo que se contestará cuando la app pregunte.
  LocationAccess onRequest = LocationAccess.granted;
  int requests = 0;

  /// Cuántas veces se abrió el GPS y si fue en modo viaje (con notificación).
  final List<bool> watches = <bool>[];
  final StreamController<PositionFix> fixes =
      StreamController<PositionFix>.broadcast();

  @override
  Future<LocationAccess> check() async => access;

  @override
  Future<LocationAccess> request() async {
    requests++;
    access = onRequest;
    return access;
  }

  @override
  Stream<PositionFix> watch({TrackingNotice? background}) {
    watches.add(background != null);
    return fixes.stream;
  }

  @override
  Future<void> openSettings() async {}
}

/// Un mapa falso: no dibuja, pero apunta lo que la pantalla le pide.
class FakeMap implements MapSurfaceController {
  MapSurfaceSpec? spec;
  Map<String, Object?>? zones;
  GeoPoint? me;
  final List<String> calls = <String>[];

  /// Lo que "se ve" en pantalla (por defecto, el centro de Madrid).
  GeoBox view = const GeoBox(
    minLon: -3.72,
    minLat: 40.40,
    maxLon: -3.69,
    maxLat: 40.43,
  );
  Map<String, Object?>? _readyFor;

  Widget build(MapSurfaceSpec s) {
    spec = s;
    // Como MapLibre: al cargar un estilo (nuevo) avisa de que está listo.
    if (!identical(_readyFor, s.style)) {
      _readyFor = s.style;
      WidgetsBinding.instance.addPostFrameCallback((_) => s.onReady(this));
    }
    return const ColoredBox(
      color: Color(0xFF0B1217),
      child: SizedBox.expand(key: Key('fake-map')),
    );
  }

  @override
  Future<void> showZones(Map<String, Object?> features) async {
    zones = features;
    calls.add('zones');
  }

  @override
  Future<void> showMe(GeoPoint? point) async => me = point;

  @override
  Future<void> flyTo(GeoPoint target, {double? zoom}) async =>
      calls.add('flyTo ${target.lat},${target.lon}');

  @override
  Future<void> setTilt(double degrees) async => calls.add('tilt $degrees');

  @override
  Future<GeoBox?> visibleBox() async => view;
}

/// Un reproductor falso que solo cambia su estado.
class FakePlayer implements GuidePlayer {
  final ValueNotifier<Playback> state = ValueNotifier<Playback>(
    const Playback(),
  );
  List<Uri> loaded = <Uri>[];
  double speed = 1;
  bool disposed = false;

  @override
  ValueListenable<Playback> get playback => state;

  @override
  Future<void> load(List<Uri> parts, {int part = 0, Duration? position}) async {
    loaded = parts;
    state.value = Playback(part: part, position: position ?? Duration.zero);
  }

  @override
  Future<void> play() async =>
      state.value = state.value.copyWith(playing: true);

  @override
  Future<void> pause() async =>
      state.value = state.value.copyWith(playing: false);

  @override
  Future<void> seek(Duration position, {int? part}) async => state.value = state
      .value
      .copyWith(position: position, part: part ?? state.value.part);

  @override
  Future<void> setSpeed(double value) async => speed = value;

  @override
  Future<void> dispose() async => disposed = true;
}

/// Un rastreador de ubicación con GPS falso, para probar el mapa y el modo
/// viaje sin móvil.
LocationTracker fakeTracker(
  SessionController session, {
  FakeLocation? location,
  FakeGateway? gateway,
  SettingsStore? prefs,
  Future<bool> Function()? askNotifications,
  PositionReporter Function(SendPositions send)? newReporter,
}) => LocationTracker(
  location: location ?? FakeLocation(),
  geo: GeoApi(
    ApiClient(
      baseUrl: Uri.parse('http://gateway.test'),
      session: session,
      client: (gateway ?? FakeGateway()).client,
    ),
  ),
  session: session,
  prefs: prefs ?? MemorySettingsStore(),
  askNotifications: askNotifications,
  newReporter: newReporter,
);

SessionController newSession([FakeGateway? gateway, TokenStore? store]) =>
    SessionController(
      api: (gateway ?? FakeGateway()).api(),
      store: store ?? MemoryTokenStore(),
    );

/// Una sesión con cuenta, ya dentro (para las pantallas solo de cuentas).
Future<SessionController> signedInSession(FakeGateway g) async {
  g.accounts['ana@example.com'] = 'una contraseña larga';
  final SessionController s = newSession(g);
  await s.signIn('ana@example.com', 'una contraseña larga');
  return s;
}

/// Un cliente de servicios con una cuenta ya dentro.
Future<ApiClient> apiFor(FakeGateway g) async => ApiClient(
  baseUrl: Uri.parse('http://gateway.test'),
  session: await signedInSession(g),
  client: g.client,
);

/// Monta la app con un idioma fijo y espera a que termine de dibujarse.
Future<SettingsController> pumpApp(
  WidgetTester tester, {
  String? locale,
  String initialLocation = Routes.welcome,
  SessionController? session,
  AppServices? services,
}) async {
  final SettingsController settings = SettingsController(
    MemorySettingsStore(locale),
  );
  final SessionController s = session ?? (newSession()..continueAsGuest());
  await tester.pumpWidget(
    NomadIqApp(
      settings: settings,
      session: s,
      services: services ?? fakeServices(s),
      router: buildRouter(session: s, initialLocation: initialLocation),
    ),
  );
  await tester.pumpAndSettle();
  return settings;
}

/// Simula un móvil configurado en el idioma [tag] (lo que llega del sistema).
void setDeviceLocale(WidgetTester tester, String tag) {
  tester.platformDispatcher.localesTestValue = <Locale>[Locale(tag)];
  addTearDown(tester.platformDispatcher.clearLocalesTestValue);
}
