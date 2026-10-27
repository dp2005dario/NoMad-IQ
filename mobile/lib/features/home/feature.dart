// Las funciones de la app con su icono, color y nombre traducido.
// (Antes había aquí una pantalla "muy pronto"; ya no hace falta: todas
// las funciones tienen pantalla propia.)
import 'package:flutter/material.dart';

import '../../core/theme.dart';
import '../../l10n/generated/app_localizations.dart';

/// Funciones de la app que todavía no tienen pantalla propia.
enum Feature {
  map(Icons.map_rounded, NomadColors.mint),
  camera(Icons.photo_camera_rounded, NomadColors.mint),
  flights(Icons.flight_rounded, NomadColors.flights),
  group(Icons.groups_rounded, NomadColors.group),
  vault(Icons.lock_rounded, NomadColors.safety),
  expenses(Icons.receipt_long_rounded, NomadColors.money),
  audioguides(Icons.headphones_rounded, NomadColors.mint),
  flyra(Icons.auto_awesome_rounded, NomadColors.group),
  // Atajos de la pantalla del Mapa.
  nearby(Icons.near_me_rounded, NomadColors.mint),
  transport(Icons.directions_transit_rounded, NomadColors.flights),
  radar(Icons.radar_rounded, NomadColors.money),
  queues(Icons.timer_rounded, NomadColors.group),
  assistant(Icons.support_agent_rounded, NomadColors.safety),
  // "Planea tu viaje" en Vuelos.
  explore(Icons.travel_explore_rounded, NomadColors.flights),
  cheapSleep(Icons.hotel_rounded, NomadColors.money),
  stopover(Icons.connecting_airports_rounded, NomadColors.flights),
  events(Icons.celebration_rounded, NomadColors.group),
  copyTrip(Icons.content_copy_rounded, NomadColors.mint),
  flightRoute(Icons.public_rounded, NomadColors.flights);

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
    Feature.nearby => t.mapNearby,
    Feature.transport => t.mapTransport,
    Feature.radar => t.mapRadar,
    Feature.queues => t.mapQueues,
    Feature.assistant => t.mapAssistant,
    Feature.explore => t.planExplore,
    Feature.cheapSleep => t.planCheapSleep,
    Feature.stopover => t.planStopover,
    Feature.events => t.planEvents,
    Feature.copyTrip => t.planCopyTrip,
    Feature.flightRoute => t.planFlightRoute,
  };
}
