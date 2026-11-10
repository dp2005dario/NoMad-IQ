// Abrir el Vuelo 3D desde cualquier sitio (Vuelos, Widgets...).
//
// La simulación es la de TU viaje: si tienes un vuelo guardado (el "Tu
// próximo vuelo" de Mi viaje), se vuela ese. Si no, la ruta que estabas
// mirando (por ejemplo el chollo de arriba en Vuelos).
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/router.dart';
import '../../core/services.dart';
import '../widgets/widget_snapshots.dart' show FlightPlan;
import '../widgets/widget_sync.dart' show savedFlightPlan;
import 'flight3d.dart';
import 'world_data.dart';

Future<void> openFlight3d(
  BuildContext context, {
  String? from,
  String? to,
}) async {
  final AppServices s = ServicesScope.of(context);
  final NavigatorState nav = Navigator.of(context, rootNavigator: true);
  final GoRouter? router = GoRouter.maybeOf(context);
  final FlightPlan? plan = await savedFlightPlan(s);
  Airport? a = plan?.from;
  Airport? b = plan?.to;
  if (a == null || b == null) {
    try {
      final Airports airports = await s.loadAirports();
      a = from == null ? null : airports[from];
      b = to == null ? null : airports[to];
    } on Object {
      a = b = null;
    }
  }
  final WebSceneBuilder? scene = s.scene3d ?? s.webScene;
  if (a == null || b == null || a.iata == b.iata || scene == null) {
    // Sin ruta completa: la Ruta del vuelo, que pregunta el destino.
    if (from != null) await router?.push(Routes.flightRoute(from: from));
    return;
  }
  final Airport origin = a;
  final Airport dest = b;
  await nav.push<bool>(
    MaterialPageRoute<bool>(
      fullscreenDialog: true,
      builder: (BuildContext context) =>
          Flight3dScreen(from: origin, to: dest, scene: scene),
    ),
  );
}
