// Widgets (maqueta "Widgets"): la maqueta tal cual
// (assets/widgets/widgets.html) con ECLIPTA fuera de la app:
//   - Móvil: los tres widgets de Android (tu vuelo, el chollo de hoy y el
//     presupuesto) tal y como se verán, y "Añadir al escritorio";
//   - Avisos: el aviso "en directo" del día del vuelo (se puede apagar);
//   - Reloj: un reloj Wear OS enseña esos mismos avisos (Android los pasa
//     solo), así que no hace falta otra app.
// Abajo, Antes / En vuelo / Aterrizado enseñan cada momento de TU vuelo (el
// del Modo fácil, que se cambia aquí mismo).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../core/router.dart';
import '../../core/services.dart';
import '../../l10n/generated/app_localizations.dart';
import '../easy/easy_home_screen.dart' show EasyTripSheet;
import '../easy/easy_mode.dart';
import '../money/money_screen.dart' show MoneyTab;
import '../route/web_scene.dart';
import 'home_widgets.dart';
import '../route/open_flight3d.dart';
import 'widget_snapshots.dart';
import 'widget_sync.dart';
import 'widgets_page.dart';

enum _Phase { before, flight, landed }

class WidgetsScreen extends StatefulWidget {
  const WidgetsScreen({super.key});

  /// La última conexión con la página (para las pruebas).
  static WebSceneBridge? lastBridge;

  @override
  State<WidgetsScreen> createState() => _WidgetsScreenState();
}

class _WidgetsScreenState extends State<WidgetsScreen> {
  late final AppServices _services = ServicesScope.of(context);
  final WebSceneBridge _bridge = WidgetsScreen.lastBridge = WebSceneBridge();

  // La página se lee una vez y se guarda (como String, no como Future).
  static String? _pageCache;
  String? _html;
  String? _sent;

  PublishedWidgets? _state;
  FlightPlan? _plan;
  bool _canPin = false;
  bool _live = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_open()));
  }

  Future<void> _open() async {
    try {
      _pageCache ??= await rootBundle.loadString(widgetsPage, cache: false);
    } on Object {
      return;
    }
    await _sync();
  }

  Future<void> _sync() async {
    final AppLocalizations t = AppLocalizations.of(context);
    final String locale = Localizations.localeOf(context).toLanguageTag();
    _live = liveFlightOn(_services.prefs);
    final PublishedWidgets state = await syncWidgets(_services, t, locale);
    final FlightPlan? plan = await savedFlightPlan(_services);
    final bool pin = await _services.homeWidgets.canPin();
    if (!mounted) return;
    setState(() {
      _state = state;
      _plan = plan;
      _canPin = pin;
    });
  }

  Future<void> _editFlight() async {
    final EasyTrip? trip = await showModalBottomSheet<EasyTrip>(
      context: context,
      isScrollControlled: true,
      useRootNavigator: true,
      builder: (_) => EasyTripSheet(trip: loadEasyTrip(_services.prefs)),
    );
    if (trip == null) return;
    await saveEasyTrip(_services.prefs, trip);
    await _sync();
  }

  /// El momento que enseña cada botón de abajo.
  static DateTime _at(FlightPlan p, _Phase phase) => switch (phase) {
    _Phase.before => p.departure.subtract(const Duration(hours: 2)),
    _Phase.flight => p.departure.add(p.arrival.difference(p.departure) * 0.46),
    _Phase.landed => p.arrival.add(const Duration(minutes: 10)),
  };

  void _onMessage(String m) {
    final int i = m.indexOf(':');
    final String what = i < 0 ? m : m.substring(0, i);
    final String arg = i < 0 ? '' : m.substring(i + 1);
    switch (what) {
      case 'back':
        if (context.canPop()) context.pop();
      case 'edit':
        unawaited(_editFlight());
      case 'pin':
        final HomeWidgetKind? kind = switch (arg) {
          'flight' => HomeWidgetKind.flight,
          'deal' => HomeWidgetKind.deal,
          'budget' => HomeWidgetKind.budget,
          _ => null,
        };
        if (kind != null && _canPin) {
          unawaited(_services.homeWidgets.pin(kind));
        }
      case 'live':
        final bool on = !_live;
        setState(() => _live = on);
        unawaited(setLiveFlight(_services.prefs, on).then((_) => _sync()));
      case 'open':
        unawaited(
          context.push(switch (arg) {
            'budget' => Routes.money(tab: MoneyTab.expenses),
            _ => Routes.flights,
          }),
        );
      case 'fly3d':
        final FlightPlan? p = _plan;
        if (p != null) {
          unawaited(openFlight3d(context, from: p.from.iata, to: p.to.iata));
        }
      case 'boarding':
        unawaited(context.push(Routes.vault));
    }
  }

  Map<String, Object?> _phase(
    AppLocalizations t,
    String locale,
    FlightPlan p,
    _Phase phase,
  ) {
    final DateTime at = _at(p, phase);
    final WidgetSnapshot? snap = pickSnapshot(
      _state?.flight ?? const <WidgetSnapshot>[],
      at,
    );
    LiveStep? live;
    for (final LiveStep s in _state?.live ?? const <LiveStep>[]) {
      if (!s.at.isAfter(at)) live = s;
    }
    // Al llegar, la hora y el día de allí.
    final DateTime clock = phase == _Phase.landed
        ? wallClockIn(p.to.timeZone, at)
        : at;
    final String where = phase == _Phase.landed ? p.to.city : p.from.city;
    final String day = DateFormat('EEEE, d MMM', locale).format(clock);
    final DateFormat hm = DateFormat.Hm(locale);
    final String color = snap?.color ?? '#3DDC97';
    final int pct = switch (phase) {
      _Phase.before => 8,
      _Phase.flight => 46,
      _Phase.landed => 100,
    };
    return <String, Object?>{
      'key': switch (phase) {
        _Phase.before => t.widgetsPhaseBefore,
        _Phase.flight => t.widgetsPhaseFlight,
        _Phase.landed => t.widgetsPhaseLanded,
      },
      'color': color,
      'tag': snap?.tag ?? '',
      'pct': snap != null && snap.pct >= 0 ? snap.pct : pct,
      'shade': switch (phase) {
        _Phase.before => 36,
        _Phase.flight => 48,
        _Phase.landed => 82,
      },
      'clock': hm.format(clock),
      'date': '${day[0].toUpperCase()}${day.substring(1)} · $where',
      'dateShort': DateFormat.MMMEd(locale).format(clock),
      'facts': <Object?>[
        <String>['SALIDA', hm.format(p.departure)],
        <String>['LLEGADA', hm.format(wallClockIn(p.to.timeZone, p.arrival))],
        <String>['PUERTA', p.gate ?? '—'],
      ],
      'title': live?.title ?? snap?.title ?? '',
      'body': live?.body ?? snap?.small ?? '',
      'chip': snap?.big ?? '',
      'watch': <String>[snap?.tag ?? '', snap?.big ?? '', snap?.small ?? ''],
    };
  }

  Map<String, Object?> _small(
    List<WidgetSnapshot>? list,
    String empty,
    String tag,
  ) {
    final WidgetSnapshot? s = pickSnapshot(
      list ?? const <WidgetSnapshot>[],
      DateTime.now(),
    );
    return <String, Object?>{
      'tag': s?.tag ?? tag,
      'title': s?.title ?? '',
      'big': s?.big ?? '',
      'small': s?.small ?? '',
      'empty': empty,
    };
  }

  Map<String, Object?> _data(AppLocalizations t) {
    final String locale = Localizations.localeOf(context).toLanguageTag();
    final FlightPlan? p = _plan;
    final EasyTrip trip = loadEasyTrip(_services.prefs);
    final DateTime now = DateTime.now();
    final String today = DateFormat('EEEE, d MMM', locale).format(now);
    String arrival(FlightPlan p) {
      final DateTime there = wallClockIn(p.to.timeZone, p.arrival);
      final int days = DateTime(there.year, there.month, there.day)
          .difference(
            DateTime(p.departure.year, p.departure.month, p.departure.day),
          )
          .inDays;
      return '${DateFormat.Hm(locale).format(there)}${days > 0 ? ' (+$days)' : ''}';
    }

    return <String, Object?>{
      't': <String, Object?>{
        'back': MaterialLocalizations.of(context).backButtonTooltip,
        'title': t.widgetsTitle,
        'views': t.widgetsIntro,
        'home': 'Móvil',
        'shade': 'Avisos',
        'watch': t.widgetsWatch,
        'openApp': 'Abrir ECLIPTA',
        'flightName': t.widgetsYourFlight.toUpperCase(),
        'pin': t.widgetsAdd,
        'howTo': '${t.widgetsHowTo} ${t.widgetsUpdates}',
        'liveTag': 'ECLIPTA · en directo',
        'stops': <String>['Casa', 'Aeropuerto', 'En vuelo', 'Hotel'],
        'fly3d': 'Ver el vuelo en 3D',
        'boarding': 'Tarjeta de embarque',
        'liveH': t.widgetsLive,
        'liveP': t.widgetsLiveHint,
        'liveOffH': t.widgetLiveChannel,
        'liveOffP': 'Está apagado: enciéndelo aquí abajo.',
        'watchHint': t.widgetsWatchHint,
        'qr': 'Tarjeta de embarque',
      },
      'clock': DateFormat.Hm(locale).format(now),
      'date': '${today[0].toUpperCase()}${today.substring(1)}',
      'dateShort': DateFormat.MMMEd(locale).format(now),
      'hasFlight': p != null,
      'noFlightTxt': trip.hasFlight
          ? t.widgetsUnknownAirport
          : t.widgetsNoFlight,
      'editTxt': trip.hasFlight ? t.widgetsEditFlight : t.widgetsAddFlight,
      if (p != null) ...<String, Object?>{
        'route': '${p.from.city} → ${p.to.city}',
        'flightRight': '${p.from.city} → ${p.to.city}',
        'fromCode': p.from.iata,
        'toCode': p.to.iata,
        'depTime': DateFormat.MMMd(locale).add_Hm().format(p.departure),
        'arrTime': arrival(p),
      },
      'phases': <Object?>[
        if (p != null)
          for (final _Phase ph in _Phase.values) _phase(t, locale, p, ph),
      ],
      'deal': _small(_state?.deal, t.widgetDealEmpty, t.widgetDealTag),
      'budget': _small(_state?.budget, t.widgetBudgetEmpty, t.widgetBudgetTag),
      'canPin': _canPin,
      'live': _live,
    };
  }

  @override
  Widget build(BuildContext context) {
    final String? page = _pageCache;
    if (page == null || _state == null) {
      return const Scaffold(
        backgroundColor: Color(0xFF1B2D5A),
        body: SizedBox.expand(),
      );
    }
    final Map<String, Object?> data = _data(AppLocalizations.of(context));
    final String push = widgetsPushScript(data);
    if (_html == null) {
      _html = widgetsPageWith(page, data);
      _sent = push;
    } else if (push != _sent) {
      _sent = push;
      unawaited(_bridge.run(push));
    }
    final String html = _html!;
    final AppServices services = ServicesScope.of(context);
    return Scaffold(
      backgroundColor: const Color(0xFF1B2D5A),
      body: SafeArea(
        bottom: false,
        child:
            services.webScene?.call(html, _onMessage) ??
            WebScene(html: html, onMessage: _onMessage, bridge: _bridge),
      ),
    );
  }
}
