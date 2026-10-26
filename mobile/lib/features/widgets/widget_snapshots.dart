// Lo que enseñan los widgets del escritorio, ya calculado y traducido.
//
// Un widget de Android no puede ejecutar Dart cuando la app está cerrada.
// Por eso aquí se preparan de golpe TODAS las "fotos fijas" que va a
// enseñar (con la hora desde la que vale cada una) y el widget, en Kotlin,
// solo elige la que toca (ver android/.../NomadWidgets.kt). Así cambia solo
// de "Sales en 3 h" a "En vuelo · 46 %" y a "Has llegado" sin Internet ni
// servidor.
import 'package:intl/intl.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import '../../core/money.dart';
import '../../l10n/generated/app_localizations.dart';
import '../easy/easy_mode.dart';
import '../flights/fares_api.dart';
import '../money/trip_budget.dart';
import '../route/geo.dart';
import '../route/world_data.dart';

/// Los colores de la maqueta: ámbar antes, menta en vuelo, azul al llegar.
const String widgetAmber = '#FFB86B';
const String widgetMint = '#3DDC97';
const String widgetBlue = '#6CA8FF';
const String widgetRed = '#FF8A65';

/// Una "foto fija" del widget, válida desde [at].
class WidgetSnapshot {
  const WidgetSnapshot({
    required this.at,
    this.tag = '',
    this.title = '',
    this.big = '',
    this.small = '',
    this.pct = -1,
    this.color = widgetMint,
    this.empty = false,
  });

  /// "Ya no hay nada que enseñar" desde [at].
  const WidgetSnapshot.empty(this.at)
    : tag = '',
      title = '',
      big = '',
      small = '',
      pct = -1,
      color = widgetMint,
      empty = true;

  final DateTime at;
  final String tag;
  final String title;
  final String big;
  final String small;

  /// 0..100 = barra de progreso; -1 = sin barra.
  final int pct;
  final String color;
  final bool empty;

  Map<String, Object?> toJson() => empty
      ? <String, Object?>{'t': at.millisecondsSinceEpoch, 'empty': true}
      : <String, Object?>{
          't': at.millisecondsSinceEpoch,
          'tag': tag,
          'title': title,
          'big': big,
          'small': small,
          'pct': pct,
          'color': color,
        };
}

/// La misma elección que hace el widget en Android: la última foto cuya hora
/// ya ha llegado (null = vacío). Sirve para la vista previa de la app.
WidgetSnapshot? pickSnapshot(List<WidgetSnapshot> list, DateTime now) {
  WidgetSnapshot? best;
  for (final WidgetSnapshot s in list) {
    if (!s.at.isAfter(now) && (best == null || !s.at.isBefore(best.at))) {
      best = s;
    }
  }
  return best == null || best.empty ? null : best;
}

/// Tu vuelo con todo lo que hace falta para las cuentas.
class FlightPlan {
  const FlightPlan({
    required this.from,
    required this.to,
    required this.departure,
    required this.arrival,
    this.gate,
    this.hotelName,
  });

  final Airport from;
  final Airport to;
  final DateTime departure;

  /// Calculada: distancia en línea recta a velocidad de avión + 30 min.
  final DateTime arrival;
  final String? gate;
  final String? hotelName;

  /// La hora a la que se embarca (40 min antes, lo normal).
  DateTime get boarding => departure.subtract(const Duration(minutes: 40));
}

/// El vuelo del Modo fácil ("Tu próximo vuelo") → plan. null si falta algo
/// o el aeropuerto no se conoce.
FlightPlan? flightPlanOf(EasyTrip trip, Airports airports) {
  final DateTime? dep = trip.departure;
  final String? from = trip.from;
  final String? to = trip.to;
  if (dep == null || from == null || to == null) return null;
  final Airport? a = airports[from];
  final Airport? b = airports[to];
  if (a == null || b == null || a.iata == b.iata) return null;
  final double km = distanceKm(a.position, b.position);
  return FlightPlan(
    from: a,
    to: b,
    departure: dep,
    arrival: dep.add(estimatedFlightTime(km)),
    gate: trip.gate,
    hotelName: trip.hotelName,
  );
}

bool _tzReady = false;

/// La hora de reloj en [zone] ("Asia/Tokyo") en el instante [at]. Si la zona
/// no se conoce, la del móvil.
DateTime wallClockIn(String zone, DateTime at) {
  if (!_tzReady) {
    tzdata.initializeTimeZones();
    _tzReady = true;
  }
  try {
    final tz.TZDateTime z = tz.TZDateTime.from(at, tz.getLocation(zone));
    return DateTime(z.year, z.month, z.day, z.hour, z.minute);
  } on tz.LocationNotFoundException {
    return at.toLocal();
  }
}

String _hm(AppLocalizations t, Duration d) {
  final int m = d.inMinutes < 0 ? 0 : d.inMinutes;
  return t.widgetHoursMinutes(m ~/ 60, (m % 60).toString().padLeft(2, '0'));
}

/// Todas las fotos fijas del widget del vuelo: desde "Tu próximo vuelo"
/// hasta 6 horas después de aterrizar.
List<WidgetSnapshot> flightSnapshots(
  FlightPlan p,
  AppLocalizations t,
  String locale,
) {
  final DateFormat hm = DateFormat.Hm(locale);
  final String title = '${p.from.iata} → ${p.to.iata}';
  final String depTime = hm.format(p.departure);
  final DateTime leave = leaveHomeAt(p.departure);
  final String? gate = p.gate;
  final List<WidgetSnapshot> out = <WidgetSnapshot>[
    // Desde siempre (hasta que falte un día): cuándo es.
    WidgetSnapshot(
      at: DateTime.fromMillisecondsSinceEpoch(0),
      tag: t.widgetNextFlight,
      title: title,
      big: DateFormat.MMMd(locale).format(p.departure),
      small: t.widgetDepartsAt(depTime),
      color: widgetAmber,
    ),
    // El último día, hora a hora: "Sales en 5 h".
    for (int h = 24; h > 3; h--)
      WidgetSnapshot(
        at: p.departure.subtract(Duration(hours: h)),
        tag: t.widgetDepartsIn(h),
        title: title,
        big: depTime,
        small: t.widgetLeaveAt(hm.format(leave)),
        color: widgetAmber,
      ),
    // Hora de ir al aeropuerto y, cada media hora, cuánto falta para embarcar.
    for (final DateTime at in <DateTime>[
      leave,
      leave.add(const Duration(minutes: 30)),
      leave.add(const Duration(hours: 1)),
      leave.add(const Duration(minutes: 90)),
      leave.add(const Duration(hours: 2)),
    ])
      if (at.isBefore(p.boarding))
        WidgetSnapshot(
          at: at,
          tag: at == leave
              ? t.widgetLeaveNow
              : t.widgetBoardingIn(p.boarding.difference(at).inMinutes),
          title: title,
          big: gate ?? depTime,
          small: gate == null
              ? t.widgetBoardingAt(hm.format(p.boarding))
              : t.widgetGate(gate),
          color: widgetAmber,
        ),
    WidgetSnapshot(
      at: p.boarding,
      tag: t.widgetBoardingNow,
      title: title,
      big: gate ?? depTime,
      small: t.widgetDepartsAt(depTime),
      color: widgetAmber,
    ),
  ];

  // En vuelo: cada 15 minutos (cada 30 si el vuelo es muy largo), cuánto va
  // y cuánto falta. La hora de llegada, en la hora del sitio al que vas.
  final Duration total = p.arrival.difference(p.departure);
  final Duration step = total > const Duration(hours: 8)
      ? const Duration(minutes: 30)
      : const Duration(minutes: 15);
  final String landsAt = t.widgetLandsAt(
    hm.format(wallClockIn(p.to.timeZone, p.arrival)),
    p.to.city,
  );
  for (DateTime at = p.departure; at.isBefore(p.arrival); at = at.add(step)) {
    final int pct =
        (at.difference(p.departure).inSeconds * 100 / total.inSeconds)
            .floor()
            .clamp(0, 99);
    out.add(
      WidgetSnapshot(
        at: at,
        tag: t.widgetInFlight(pct),
        title: title,
        big: _hm(t, p.arrival.difference(at)),
        small: landsAt,
        pct: pct,
      ),
    );
  }

  final String? hotel = p.hotelName;
  out
    ..add(
      WidgetSnapshot(
        at: p.arrival,
        tag: t.widgetArrived(p.to.city.toUpperCase()),
        title: title,
        big: hm.format(wallClockIn(p.to.timeZone, p.arrival)),
        small: hotel == null ? t.widgetWelcome : t.widgetHotel(hotel),
        pct: 100,
        color: widgetBlue,
      ),
    )
    ..add(WidgetSnapshot.empty(p.arrival.add(const Duration(hours: 6))));
  return out;
}

/// El chollo de hoy. Pasado día y medio se quita (un precio viejo engaña).
List<WidgetSnapshot> dealSnapshots(
  Deal deal,
  Airports? airports,
  AppLocalizations t,
  String locale,
  DateTime now,
) {
  final FareRoute r = deal.fare.route;
  String city(String iata) => airports?[iata]?.city ?? iata;
  final String price = formatMoney(
    deal.fare.price.amountMinor,
    deal.fare.price.currency,
    locale,
  );
  final int drop = (deal.dropBasisPoints / 100).round();
  return <WidgetSnapshot>[
    WidgetSnapshot(
      at: now.subtract(const Duration(minutes: 1)),
      tag: t.widgetDealTag,
      title: '${city(r.origin)} → ${city(r.destination)}',
      big: price,
      small: drop > 0 && deal.usualMinor > 0
          ? t.widgetDealDrop(
              drop,
              formatMoney(deal.usualMinor, deal.fare.price.currency, locale),
            )
          : t.widgetDealCheck,
      color: widgetAmber,
    ),
    WidgetSnapshot.empty(now.add(const Duration(hours: 36))),
  ];
}

/// El presupuesto: cada día a medianoche, cuánto te queda para ese día si
/// sigues sin gastar más (lo que queda ÷ los días que faltan).
List<WidgetSnapshot> budgetSnapshots(
  TripBudget b,
  int spentMinor,
  String currency,
  AppLocalizations t,
  String locale,
  DateTime now,
) {
  final DateTime start = DateTime(b.start.year, b.start.month, b.start.day);
  final int days = b.days.clamp(1, 366);
  final int left = b.limitMinor - spentMinor;
  final DateTime today = DateTime(now.year, now.month, now.day);
  // Desde hoy (o desde el primer día, si el viaje aún no ha empezado), como
  // mucho 60 días por delante.
  final int first = (today.difference(start).inDays + 1).clamp(1, days + 1);
  final List<WidgetSnapshot> out = <WidgetSnapshot>[
    for (int d = first; d <= days && d < first + 60; d++)
      WidgetSnapshot(
        at: DateTime(start.year, start.month, start.day + d - 1),
        tag: t.widgetBudgetTag,
        title: t.widgetBudgetDay(d, days),
        big: formatMoney(
          left <= 0 ? 0 : left ~/ (days - d + 1),
          currency,
          locale,
        ),
        small: left < 0
            ? t.widgetBudgetOver(formatMoney(-left, currency, locale))
            : t.widgetBudgetLeftToday,
        color: left < 0 ? widgetRed : widgetMint,
      ),
  ];
  out.add(
    WidgetSnapshot.empty(DateTime(start.year, start.month, start.day + days)),
  );
  return out;
}
