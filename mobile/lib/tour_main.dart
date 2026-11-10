// SOLO PARA LA PRUEBA AUTOMÁTICA CON CAPTURAS (no es la app de la tienda).
//
// El robot de GitHub (.github/workflows/capturas.yml) compila la app con
// este archivo como entrada ("-t lib/tour_main.dart"), la instala en un
// móvil Android de mentira (emulador) y la deja abrir sola, una tras otra,
// todas las pantallas. Antes de cada captura escribe en el registro del
// móvil "ECLIPTA_SHOT:nombre"; el script tool/capturas.sh lo lee y hace la
// foto de la pantalla en ese momento. Al acabar escribe "ECLIPTA_SHOT:FIN".
//
// La app es la de verdad (servidor real, páginas web reales): así se ve lo
// que verías tú en el móvil, con los WebView incluidos.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:go_router/go_router.dart';

import 'auth/session.dart';
import 'core/router.dart';
import 'main.dart';

/// Las pantallas que se visitan: (nombre de la captura, dirección).
final List<(String, String)> tourStops = <(String, String)>[
  ('01-inicio', Routes.home),
  ('02-mapa', Routes.map),
  ('03-vuelos', Routes.flights),
  ('04-buscar-vuelos', Routes.fareSearch()),
  ('05-ruta-del-vuelo', Routes.flightRoute(from: 'MAD', to: 'NRT')),
  ('06-explorar', Routes.explore()),
  ('07-hoteles', Routes.stays()),
  ('08-que-pasa', Routes.events(iata: 'LIS')),
  ('09-grupo', Routes.group),
  ('10-nuevo-viaje-grupo', Routes.groupNew),
  ('11-flyra', Routes.flyra()),
  ('12-cerca-de-ti', Routes.nearby),
  ('13-radar', Routes.radar()),
  ('14-dinero', Routes.money()),
  ('15-boveda', Routes.vault),
  ('16-pasaporte', Routes.passport),
  ('17-recuerdos', Routes.memories),
  ('18-sos', Routes.sos),
  ('19-ajustes', Routes.settings),
  ('20-idioma', Routes.language),
  ('21-menu', Routes.menu),
  ('22-antes-de-viajar', Routes.before),
  ('23-sin-conexion', Routes.offline),
  ('24-viajar-con', Routes.travelWith),
  ('25-ayuda', Routes.help),
  ('26-tarjetas', Routes.cards),
  ('27-widgets', Routes.widgets),
  ('28-coche', Routes.drive),
  ('29-traductor', Routes.assistant),
  ('30-voz', Routes.voice),
  ('31-aeropuerto', Routes.airport(iata: 'MAD')),
  ('32-visados', Routes.visa(to: 'JP')),
  ('33-alertas-de-precio', Routes.fareAlerts),
  ('34-copiar-viaje', Routes.copyTrip()),
  ('35-avisos', Routes.notices),
  ('36-privacidad', Routes.privacy),
];

/// Cuánto se espera en cada pantalla antes de la foto (las páginas web y
/// el servidor tardan un poco en un emulador).
const Duration tourWait = Duration(seconds: 9);

Future<void> main() => startApp(
  router: (SessionController session) {
    final GoRouter router = buildRouter(session: session);
    unawaited(_tour(router, session));
    return router;
  },
);

Future<void> _tour(GoRouter router, SessionController session) async {
  // Sin cuenta en el emulador: se entra como invitado.
  await Future<void>.delayed(const Duration(seconds: 6));
  if (session.status == SessionStatus.signedOut) session.continueAsGuest();
  await Future<void>.delayed(const Duration(seconds: 3));
  for (final (String name, String location) in tourStops) {
    router.go(location);
    await Future<void>.delayed(tourWait);
    debugPrint('ECLIPTA_SHOT:$name');
    // Tiempo para que el script haga la foto antes de cambiar.
    await Future<void>.delayed(const Duration(seconds: 3));
  }
  debugPrint('ECLIPTA_SHOT:FIN');
}
