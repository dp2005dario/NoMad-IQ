// Pone al día los widgets del escritorio y el aviso "en directo".
//
// Se llama al abrir la app (desde Inicio), al volver a ella y desde la
// pantalla Widgets. Cada vez:
//   - Vuelo: con "Tu próximo vuelo" (el mismo del Modo fácil), en el móvil.
//   - Chollo: UNA petición a /v1/fares/deals (la misma que hace Vuelos y que
//     el servidor ya tiene en caché), así que miles de widgets no cuestan.
//   - Presupuesto: UNA petición al bote del presupuesto, solo si lo tienes.
// Si no hay red, los widgets se quedan con lo último que tenían.
import 'package:intl/intl.dart';

import '../../core/api_client.dart';
import '../../core/services.dart';
import '../../core/settings.dart';
import '../../l10n/generated/app_localizations.dart';
import '../easy/easy_mode.dart';
import '../flights/fares_api.dart';
import '../flights/flights_screen.dart' show defaultOrigin;
import '../money/expenses_api.dart';
import '../money/trip_budget.dart';
import '../route/world_data.dart';
import 'home_widgets.dart';
import 'widget_snapshots.dart';

/// ¿Quieres el aviso "en directo" el día del vuelo? Encendido por defecto
/// (es útil y no gasta: se programa en el móvil).
bool liveFlightOn(SettingsStore prefs) =>
    prefs.readData(LocalData.liveFlight) != '0';

Future<void> setLiveFlight(SettingsStore prefs, bool on) =>
    prefs.writeData(LocalData.liveFlight, on ? null : '0');

/// Los pasos del aviso: salir de casa, embarque, en vuelo y llegada.
List<LiveStep> liveSteps(FlightPlan p, AppLocalizations t, String locale) {
  final DateFormat hm = DateFormat.Hm(locale);
  final DateTime leave = leaveHomeAt(p.departure);
  final String route = '${p.from.city} → ${p.to.city}';
  final String? gate = p.gate;
  final String arrival = hm.format(wallClockIn(p.to.timeZone, p.arrival));
  final String? hotel = p.hotelName;
  return <LiveStep>[
    LiveStep(
      at: leave,
      title: t.widgetLiveLeave(route),
      body: t.widgetLiveLeaveBody(
        hm.format(p.boarding),
        hm.format(p.departure),
      ),
      lasts: p.boarding.difference(leave),
    ),
    LiveStep(
      at: p.boarding,
      title: gate == null
          ? t.widgetLiveBoarding(route)
          : t.widgetLiveBoardingGate(gate),
      body: t.widgetDepartsAt(hm.format(p.departure)),
      lasts: const Duration(minutes: 40),
    ),
    LiveStep(
      at: p.departure,
      title: t.widgetLiveInFlight(route),
      body: t.widgetLandsAt(arrival, p.to.city),
      lasts: p.arrival.difference(p.departure),
      quiet: true,
    ),
    LiveStep(
      at: p.arrival,
      title: t.widgetLiveArrived(p.to.city),
      body: hotel == null ? t.widgetWelcome : t.widgetHotel(hotel),
      lasts: const Duration(hours: 3),
    ),
  ];
}

/// El plan del vuelo guardado, o null si no hay (o falta un aeropuerto).
Future<FlightPlan?> savedFlightPlan(AppServices s) async {
  final EasyTrip trip = loadEasyTrip(s.prefs);
  if (!trip.hasFlight) return null;
  try {
    return flightPlanOf(trip, await s.loadAirports());
  } on Object {
    return null;
  }
}

/// Lo que se ha publicado (para la vista previa de la pantalla Widgets).
class PublishedWidgets {
  const PublishedWidgets({this.flight, this.deal, this.budget, this.live});

  final List<WidgetSnapshot>? flight;
  final List<WidgetSnapshot>? deal;
  final List<WidgetSnapshot>? budget;
  final List<LiveStep>? live;
}

Future<PublishedWidgets> syncWidgets(
  AppServices s,
  AppLocalizations t,
  String locale, {
  DateTime? now,
}) async {
  final DateTime at = now ?? DateTime.now();

  // 1. El vuelo (sin red).
  final FlightPlan? plan = await savedFlightPlan(s);
  final List<WidgetSnapshot> flight = plan == null
      ? const <WidgetSnapshot>[]
      : flightSnapshots(plan, t, locale);
  await s.homeWidgets.publish(
    HomeWidgetKind.flight,
    flight,
    empty: t.widgetFlightEmpty,
  );
  List<LiveStep>? live;
  if (plan != null && liveFlightOn(s.prefs)) {
    live = liveSteps(plan, t, locale);
    await s.liveFlight.schedule(live, channelName: t.widgetLiveChannel);
  } else {
    await s.liveFlight.cancel();
  }

  // 2. El chollo de hoy desde tu aeropuerto (el que tengas en Vuelos).
  List<WidgetSnapshot>? deal;
  try {
    final List<Deal> deals = await s.fares.deals(
      s.prefs.readFlightOrigin() ?? defaultOrigin,
    );
    if (deals.isNotEmpty) {
      final Deal best = deals.reduce(
        (Deal a, Deal b) => b.dropBasisPoints > a.dropBasisPoints ? b : a,
      );
      Airports? airports;
      try {
        airports = await s.loadAirports();
      } on Object {
        airports = null;
      }
      deal = dealSnapshots(best, airports, t, locale, at);
    } else {
      deal = const <WidgetSnapshot>[];
    }
    await s.homeWidgets.publish(
      HomeWidgetKind.deal,
      deal,
      empty: t.widgetDealEmpty,
    );
  } on ApiException {
    // Sin red: se queda el chollo de antes (caduca solo al día y medio).
  }

  // 3. El presupuesto (solo si lo tienes puesto en Dinero).
  List<WidgetSnapshot>? budget;
  final TripBudget? b = TripBudget.load(s.prefs);
  if (b == null) {
    budget = const <WidgetSnapshot>[];
  } else {
    try {
      final ExpenseGroup pot = await s.expenses.get(b.potId);
      budget = budgetSnapshots(
        b,
        forecast(b, pot, at).spentMinor,
        pot.currency,
        t,
        locale,
        at,
      );
    } on ApiException catch (e) {
      // Sin sesión: vacío. Sin red: se queda lo de antes.
      if (e.error == ApiError.signedOut || e.error == ApiError.notFound) {
        budget = const <WidgetSnapshot>[];
      }
    }
  }
  if (budget != null) {
    await s.homeWidgets.publish(
      HomeWidgetKind.budget,
      budget,
      empty: t.widgetBudgetEmpty,
    );
  }
  return PublishedWidgets(
    flight: flight,
    deal: deal,
    budget: budget,
    live: live,
  );
}
