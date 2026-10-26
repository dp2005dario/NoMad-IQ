// Widgets (maqueta "Widgets"): ECLIPTA fuera de la app.
//   - Escritorio: tres widgets de Android (tu vuelo, el chollo de hoy y el
//     presupuesto) que cambian solos a su hora.
//   - Avisos: el aviso "en directo" del día del vuelo.
//   - Reloj: un reloj Wear OS enseña esos mismos avisos (Android los pasa
//     solo), así que no hace falta otra app.
// Aquí se ve una vista previa de cada momento (antes, en vuelo, aterrizado)
// y se pueden añadir los widgets al escritorio.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../core/services.dart';
import '../../core/theme.dart';
import '../../l10n/generated/app_localizations.dart';
import '../easy/easy_home_screen.dart' show EasyTripSheet;
import '../easy/easy_mode.dart';
import 'home_widgets.dart';
import 'widget_snapshots.dart';
import 'widget_sync.dart';

enum _Phase { before, flight, landed }

class WidgetsScreen extends StatefulWidget {
  const WidgetsScreen({super.key});

  @override
  State<WidgetsScreen> createState() => _WidgetsScreenState();
}

class _WidgetsScreenState extends State<WidgetsScreen> {
  late final AppServices _services = ServicesScope.of(context);
  PublishedWidgets? _state;
  FlightPlan? _plan;
  bool _canPin = false;
  bool _live = true;
  _Phase _phase = _Phase.before;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_sync()));
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

  /// El momento que enseña la vista previa.
  DateTime _previewAt() {
    final FlightPlan? p = _plan;
    if (p == null) return DateTime.now();
    return switch (_phase) {
      _Phase.before => p.departure.subtract(const Duration(hours: 2)),
      _Phase.flight => p.departure.add(
        p.arrival.difference(p.departure) * 0.46,
      ),
      _Phase.landed => p.arrival.add(const Duration(minutes: 10)),
    };
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    final String locale = Localizations.localeOf(context).toLanguageTag();
    final PublishedWidgets? state = _state;
    final FlightPlan? plan = _plan;
    final DateTime at = _previewAt();
    final DateTime now = DateTime.now();
    final EasyTrip trip = loadEasyTrip(_services.prefs);
    LiveStep? live;
    for (final LiveStep s in state?.live ?? const <LiveStep>[]) {
      if (!s.at.isAfter(at)) live = s;
    }
    return Scaffold(
      appBar: AppBar(title: Text(t.widgetsTitle)),
      body: state == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 40),
              children: <Widget>[
                Text(t.widgetsIntro),
                const SizedBox(height: 16),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          t.widgetsYourFlight,
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        const SizedBox(height: 6),
                        if (plan != null)
                          Text(
                            '${plan.from.city} → ${plan.to.city} · '
                            '${DateFormat.MMMd(locale).add_Hm().format(plan.departure)}',
                            style: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w800,
                            ),
                          )
                        else
                          Text(
                            trip.hasFlight
                                ? t.widgetsUnknownAirport
                                : t.widgetsNoFlight,
                          ),
                        const SizedBox(height: 4),
                        Text(
                          t.widgetsSameAsEasy,
                          style: const TextStyle(color: NomadColors.textMuted),
                        ),
                        const SizedBox(height: 8),
                        OutlinedButton.icon(
                          onPressed: () => unawaited(_editFlight()),
                          icon: const Icon(Icons.flight_takeoff_rounded),
                          label: Text(
                            trip.hasFlight
                                ? t.widgetsEditFlight
                                : t.widgetsAddFlight,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                if (plan != null) ...<Widget>[
                  const SizedBox(height: 12),
                  Text(
                    t.widgetsPreviewHint,
                    style: const TextStyle(color: NomadColors.textMuted),
                  ),
                  const SizedBox(height: 8),
                  SegmentedButton<_Phase>(
                    segments: <ButtonSegment<_Phase>>[
                      ButtonSegment<_Phase>(
                        value: _Phase.before,
                        label: Text(t.widgetsPhaseBefore),
                      ),
                      ButtonSegment<_Phase>(
                        value: _Phase.flight,
                        label: Text(t.widgetsPhaseFlight),
                      ),
                      ButtonSegment<_Phase>(
                        value: _Phase.landed,
                        label: Text(t.widgetsPhaseLanded),
                      ),
                    ],
                    selected: <_Phase>{_phase},
                    onSelectionChanged: (Set<_Phase> s) =>
                        setState(() => _phase = s.first),
                  ),
                ],
                const SizedBox(height: 20),
                _Header(icon: Icons.widgets_rounded, text: t.widgetsHome),
                _PreviewCard(
                  name: t.widgetsFlightName,
                  snapshot: pickSnapshot(
                    state.flight ?? const <WidgetSnapshot>[],
                    at,
                  ),
                  empty: t.widgetFlightEmpty,
                  onPin: _canPin
                      ? () => unawaited(
                          _services.homeWidgets.pin(HomeWidgetKind.flight),
                        )
                      : null,
                ),
                _PreviewCard(
                  name: t.widgetsDealName,
                  snapshot: pickSnapshot(
                    state.deal ?? const <WidgetSnapshot>[],
                    now,
                  ),
                  empty: t.widgetDealEmpty,
                  onPin: _canPin
                      ? () => unawaited(
                          _services.homeWidgets.pin(HomeWidgetKind.deal),
                        )
                      : null,
                ),
                _PreviewCard(
                  name: t.widgetsBudgetName,
                  snapshot: pickSnapshot(
                    state.budget ?? const <WidgetSnapshot>[],
                    now,
                  ),
                  empty: t.widgetBudgetEmpty,
                  onPin: _canPin
                      ? () => unawaited(
                          _services.homeWidgets.pin(HomeWidgetKind.budget),
                        )
                      : null,
                ),
                Text(t.widgetsHowTo),
                const SizedBox(height: 4),
                Text(
                  t.widgetsUpdates,
                  style: const TextStyle(color: NomadColors.textMuted),
                ),
                const SizedBox(height: 20),
                _Header(
                  icon: Icons.notifications_active_rounded,
                  text: t.widgetLiveChannel,
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: _live,
                  title: Text(t.widgetsLive),
                  subtitle: Text(t.widgetsLiveHint),
                  onChanged: (bool on) async {
                    setState(() => _live = on);
                    await setLiveFlight(_services.prefs, on);
                    await _sync();
                  },
                ),
                if (_live && live != null) _NoticePreview(step: live),
                const SizedBox(height: 20),
                _Header(icon: Icons.watch_rounded, text: t.widgetsWatch),
                Text(t.widgetsWatchHint),
              ],
            ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Row(
      children: <Widget>[
        Icon(icon, color: NomadColors.mint),
        const SizedBox(width: 8),
        Text(text, style: Theme.of(context).textTheme.titleMedium),
      ],
    ),
  );
}

Color _hex(String hex) {
  final int? v = int.tryParse(hex.replaceFirst('#', ''), radix: 16);
  return v == null ? NomadColors.mint : Color(0xFF000000 | v);
}

/// Cómo se verá el widget en el escritorio (lo mismo que pinta Android).
class _PreviewCard extends StatelessWidget {
  const _PreviewCard({
    required this.name,
    required this.snapshot,
    required this.empty,
    required this.onPin,
  });

  final String name;
  final WidgetSnapshot? snapshot;
  final String empty;
  final VoidCallback? onPin;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    final WidgetSnapshot? s = snapshot;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(name, style: const TextStyle(color: NomadColors.textMuted)),
          const SizedBox(height: 4),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: NomadColors.background,
              borderRadius: BorderRadius.circular(24),
              border: Border.all(color: NomadColors.outline),
            ),
            child: s == null
                ? Text(empty, textAlign: TextAlign.center)
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        s.tag,
                        style: TextStyle(
                          color: _hex(s.color),
                          fontSize: 11,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 1,
                        ),
                      ),
                      Text(
                        s.title,
                        style: const TextStyle(fontWeight: FontWeight.w800),
                      ),
                      Text(
                        s.big,
                        style: const TextStyle(
                          fontSize: 28,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                      Text(
                        s.small,
                        style: const TextStyle(color: NomadColors.textMuted),
                      ),
                      if (s.pct >= 0) ...<Widget>[
                        const SizedBox(height: 8),
                        LinearProgressIndicator(
                          value: s.pct / 100,
                          minHeight: 6,
                          color: _hex(s.color),
                          backgroundColor: NomadColors.outline,
                          borderRadius: BorderRadius.circular(3),
                        ),
                      ],
                    ],
                  ),
          ),
          if (onPin != null)
            TextButton.icon(
              onPressed: onPin,
              icon: const Icon(Icons.add_to_home_screen_rounded),
              label: Text(t.widgetsAdd),
            ),
        ],
      ),
    );
  }
}

/// Cómo se verá el aviso en la barra de notificaciones (y en el reloj).
class _NoticePreview extends StatelessWidget {
  const _NoticePreview({required this.step});

  final LiveStep step;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: NomadColors.surfaceHigh,
      borderRadius: BorderRadius.circular(16),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        const Icon(Icons.flight_rounded, color: NomadColors.mint),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                step.title,
                style: const TextStyle(fontWeight: FontWeight.w800),
              ),
              Text(step.body),
            ],
          ),
        ),
      ],
    ),
  );
}
