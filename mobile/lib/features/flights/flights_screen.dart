// Vuelos (maqueta "Cazador de vuelos"): los chollos de hoy desde tu
// aeropuerto, el mejor arriba en grande ("¡VUELO CAZADO!"), las rutas que
// vigilas y los atajos para planear el viaje.
//
// Todo sale del price-consumer (FaresApi). Los precios cambian a menudo, así
// que se puede "tirar hacia abajo" para recargar.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/api_client.dart';
import '../../core/money.dart';
import '../../core/router.dart';
import '../../core/services.dart';
import '../../core/theme.dart';
import '../../l10n/generated/app_localizations.dart';
import '../home/feature.dart';
import 'fares_api.dart';
import 'flight_format.dart' hide currencyDigits;
import 'watch_sheet.dart';

/// Aeropuerto por defecto ("Empezar en Madrid", como en la maqueta). Más
/// adelante, el más cercano según el GPS.
const String defaultOrigin = 'MAD';

class FlightsScreen extends StatefulWidget {
  const FlightsScreen({super.key});

  @override
  State<FlightsScreen> createState() => _FlightsScreenState();
}

class _FlightsScreenState extends State<FlightsScreen> {
  late final AppServices _services = ServicesScope.of(context);
  late String _origin = _services.prefs.readFlightOrigin() ?? defaultOrigin;
  List<Deal>? _deals;
  List<Watch>? _watches;

  /// Invitado: ve los chollos (precios reales), pero vigilar rutas y recibir
  /// avisos necesita cuenta, porque se guardan a su nombre.
  bool _guest = false;
  ApiError? _error;
  bool _loading = true;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_deals == null && _error == null && _loading) unawaited(_load());
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final List<Deal> deals = await _services.fares.deals(_origin);
      List<Watch>? watches;
      try {
        (watches, _) = await _services.fares.watches();
      } on ApiException catch (e) {
        // Sin cuenta no hay "mis alertas": no es un error, solo se avisa.
        if (e.error != ApiError.signedOut) rethrow;
      }
      if (!mounted) return;
      setState(() {
        // Primero lo que más ha bajado; a igual bajada, lo más barato.
        _deals = deals
          ..sort((Deal a, Deal b) {
            final int byDrop = b.dropBasisPoints.compareTo(a.dropBasisPoints);
            return byDrop != 0
                ? byDrop
                : a.fare.price.amountMinor.compareTo(b.fare.price.amountMinor);
          });
        _watches = watches;
        _guest = watches == null;
        _error = null;
        _loading = false;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.error;
        _loading = false;
      });
    }
  }

  Future<void> _pickOrigin() async {
    final String? picked = await showOriginSheet(context, current: _origin);
    if (picked == null || picked == _origin) return;
    await _services.prefs.writeFlightOrigin(picked);
    setState(() {
      _origin = picked;
      _deals = null;
    });
    await _load();
  }

  Future<void> _openRoute(FareRoute route, {Fare? fare}) async {
    await context.push(Routes.fareRoute(route.key), extra: fare);
    if (mounted) unawaited(_load()); // quizá empezó o dejó de vigilarla
  }

  Future<void> _watch(Fare fare) async {
    if (_guest) {
      await context.push(Routes.signIn);
      return;
    }
    final bool done = await showWatchSheet(
      context,
      route: fare.route,
      currency: fare.price.currency,
    );
    if (done && mounted) unawaited(_load());
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    final TextTheme text = Theme.of(context).textTheme;
    return Scaffold(
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: _load,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 120),
            children: <Widget>[
              Row(
                children: <Widget>[
                  Expanded(
                    child: Text(t.flightsTitle, style: text.headlineMedium),
                  ),
                  IconButton(
                    tooltip: t.flightsAlertsTitle,
                    onPressed: () => context.push(Routes.fareAlerts),
                    icon: const Icon(
                      Icons.notifications_rounded,
                      color: NomadColors.flights,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              // El buscador normal: origen, destino, fechas y viajeros.
              Card(
                child: ListTile(
                  leading: const Icon(
                    Icons.search_rounded,
                    color: NomadColors.flights,
                  ),
                  title: Text(t.searchOpen),
                  subtitle: Text(t.searchOpenHint),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: () => context.push(Routes.fareSearch(origin: _origin)),
                ),
              ),
              const SizedBox(height: 8),
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: ActionChip(
                  avatar: const Icon(
                    Icons.flight_takeoff_rounded,
                    size: 18,
                    color: NomadColors.flights,
                  ),
                  label: Text(t.flightsFrom(_origin)),
                  tooltip: t.flightsChangeOrigin,
                  onPressed: _pickOrigin,
                ),
              ),
              const SizedBox(height: 16),
              ..._body(context, t),
              const SizedBox(height: 28),
              Text(t.planTitle, style: text.titleLarge),
              const SizedBox(height: 12),
              _PlanShortcuts(t: t, origin: _origin),
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _body(BuildContext context, AppLocalizations t) {
    final ApiError? error = _error;
    if (_loading && _deals == null) {
      return const <Widget>[
        Padding(
          padding: EdgeInsets.all(40),
          child: Center(child: CircularProgressIndicator()),
        ),
      ];
    }
    if (error == ApiError.signedOut) {
      return <Widget>[
        _Notice(
          text: t.flightsSignIn,
          action: t.signInFromGuest,
          onAction: () => unawaited(context.push(Routes.signIn)),
        ),
      ];
    }
    if (error != null) {
      return <Widget>[
        _Notice(
          text: switch (error) {
            ApiError.network => t.errorNetwork,
            ApiError.rateLimited => t.errorRateLimited,
            _ => t.errorUnavailable,
          },
          action: t.guideRetry,
          onAction: () => unawaited(_load()),
        ),
      ];
    }
    final List<Deal> deals = _deals ?? <Deal>[];
    final List<Watch> watches = _watches ?? <Watch>[];
    final TextTheme text = Theme.of(context).textTheme;
    return <Widget>[
      if (deals.isEmpty)
        _Notice(text: t.flightsNoDeals(_origin))
      else ...<Widget>[
        _HuntedCard(
          deal: deals.first,
          onBook: deals.first.fare.bookingUrl == null
              ? null
              : () => _book(deals.first.fare.bookingUrl!),
          onWatch: () => _watch(deals.first.fare),
          onOpen: () =>
              _openRoute(deals.first.fare.route, fare: deals.first.fare),
        ),
        if (deals.first.looksLikeErrorFare) ...<Widget>[
          const SizedBox(height: 10),
          // Las tarifas error a veces se cancelan: la línea de 48 h.
          ErrorFareTimeline(seenAt: deals.first.fare.observedAt),
        ],
        const SizedBox(height: 12),
        // "Buscar ganga de vuelo": el más barato de hoy hasta lo que digas.
        OutlinedButton.icon(
          onPressed: () => unawaited(_bargain(deals)),
          icon: const Icon(Icons.savings_rounded),
          label: Text(t.bargainButton),
        ),
        if (deals.length > 1) ...<Widget>[
          const SizedBox(height: 24),
          Text(t.flightsDeals, style: text.titleLarge),
          const SizedBox(height: 8),
          for (final Deal d in deals.skip(1))
            _FareTile(
              route: d.fare.route,
              price: d.fare.price,
              badge: dropPercent(d.dropBasisPoints) >= 1
                  ? t.flightsDrop('${dropPercent(d.dropBasisPoints)}')
                  : null,
              onTap: () => _openRoute(d.fare.route, fare: d.fare),
            ),
        ],
      ],
      const SizedBox(height: 24),
      Text(t.flightsMyAlerts, style: text.titleLarge),
      const SizedBox(height: 8),
      if (_guest)
        _Notice(
          text: t.flightsSignIn,
          action: t.signInFromGuest,
          onAction: () => unawaited(context.push(Routes.signIn)),
        )
      else if (watches.isEmpty)
        Text(
          t.flightsNoWatches,
          style: text.bodyMedium?.copyWith(color: NomadColors.textMuted),
        )
      else
        for (final Watch w in watches)
          _FareTile(
            route: w.route,
            price: w.latest?.price,
            subtitle: w.target == null
                ? null
                : t.flightsWatchTarget(priceText(context, w.target!)),
            // Como la maqueta: "EN OBJETIVO" si ya está por debajo de tu
            // precio, "AÚN LEJOS" si no (solo si se saben los dos).
            badge: switch (watchOnTarget(w)) {
              true => t.flightsOnTarget,
              false => t.flightsStillFar,
              null => null,
            },
            onTap: () => _openRoute(w.route, fare: w.latest),
          ),
    ];
  }

  /// Abre "Buscar ganga" con los chollos de hoy.
  Future<void> _bargain(List<Deal> deals) async {
    final Deal? pick = await showModalBottomSheet<Deal>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => BargainSheet(deals: deals, origin: _origin),
    );
    if (pick != null && mounted) {
      unawaited(_openRoute(pick.fare.route, fare: pick.fare));
    }
  }

  Future<void> _book(Uri url) async {
    final bool opened = await _services.openBooking(url);
    if (!opened && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(AppLocalizations.of(context).flightsBookFailed)),
      );
    }
  }
}

/// La tarjeta grande del mejor chollo ("¡VUELO CAZADO!").
class _HuntedCard extends StatelessWidget {
  const _HuntedCard({
    required this.deal,
    required this.onBook,
    required this.onWatch,
    required this.onOpen,
  });

  final Deal deal;
  final VoidCallback? onBook;
  final VoidCallback onWatch;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    final TextTheme text = Theme.of(context).textTheme;
    final Fare fare = deal.fare;
    final int percent = dropPercent(deal.dropBasisPoints);
    final String badge = deal.looksLikeErrorFare
        ? '${t.flightsHunted} · ${t.flightsErrorFareBadge}'
        : percent >= 1
        ? '${t.flightsHunted} · ${t.flightsDrop('$percent')}'
        : t.flightsHunted;
    return Card(
      color: NomadColors.surfaceHigh,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onOpen,
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                badge,
                style: const TextStyle(
                  color: NomadColors.flights,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.6,
                ),
              ),
              const SizedBox(height: 12),
              Directionality(
                textDirection: TextDirection.ltr,
                child: Text(routeText(fare.route), style: text.displaySmall),
              ),
              const SizedBox(height: 6),
              Text(
                tripText(context, t, fare.route),
                style: text.bodyMedium?.copyWith(color: NomadColors.textMuted),
              ),
              const SizedBox(height: 16),
              Wrap(
                crossAxisAlignment: WrapCrossAlignment.end,
                spacing: 12,
                children: <Widget>[
                  Text(
                    priceText(context, fare.price),
                    style: text.displaySmall?.copyWith(
                      color: NomadColors.flights,
                    ),
                  ),
                  if (deal.usualMinor > fare.price.amountMinor)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Text(
                        t.flightsUsual(
                          priceText(
                            context,
                            Money(deal.usualMinor, fare.price.currency),
                          ),
                        ),
                        style: text.bodyMedium?.copyWith(
                          color: NomadColors.textMuted,
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 20),
              if (onBook != null) ...<Widget>[
                FilledButton.icon(
                  onPressed: onBook,
                  icon: const Icon(Icons.open_in_new_rounded),
                  label: Text(t.flightsBook),
                ),
                const SizedBox(height: 10),
              ],
              OutlinedButton.icon(
                onPressed: onWatch,
                icon: const Icon(Icons.notifications_active_rounded),
                label: Text(t.flightsNotify),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Una fila de la lista: ruta, fecha y precio.
class _FareTile extends StatelessWidget {
  const _FareTile({
    required this.route,
    required this.price,
    required this.onTap,
    this.badge,
    this.subtitle,
  });

  final FareRoute route;
  final Money? price;
  final String? badge;
  final String? subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    final TextTheme text = Theme.of(context).textTheme;
    final Money? p = price;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Card(
        clipBehavior: Clip.antiAlias,
        child: ListTile(
          onTap: onTap,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 4,
          ),
          title: Directionality(
            textDirection: TextDirection.ltr,
            child: Text(
              routeText(route),
              textAlign: Directionality.of(context) == TextDirection.rtl
                  ? TextAlign.right
                  : TextAlign.left,
              style: text.titleMedium,
            ),
          ),
          subtitle: Text(
            <String>[tripText(context, t, route), ?subtitle].join('\n'),
            style: const TextStyle(color: NomadColors.textMuted),
          ),
          trailing: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: <Widget>[
              Text(
                p == null ? t.flightsNoPriceYet : priceText(context, p),
                style: text.titleMedium?.copyWith(color: NomadColors.flights),
              ),
              if (badge != null)
                Text(
                  badge!,
                  style: const TextStyle(
                    color: NomadColors.mint,
                    fontWeight: FontWeight.w700,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Notice extends StatelessWidget {
  const _Notice({required this.text, this.action, this.onAction});

  final String text;
  final String? action;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text(text, style: Theme.of(context).textTheme.bodyLarge),
            if (action != null) ...<Widget>[
              const SizedBox(height: 16),
              FilledButton(onPressed: onAction, child: Text(action!)),
            ],
          ],
        ),
      ),
    );
  }
}

/// "Planea tu viaje": las herramientas que llegan en próximas versiones.
class _PlanShortcuts extends StatelessWidget {
  const _PlanShortcuts({required this.t, required this.origin});

  final AppLocalizations t;
  final String origin;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: <Widget>[
        for (final Feature f in const <Feature>[
          Feature.flightRoute,
          Feature.explore,
          Feature.cheapSleep,
          Feature.events,
          Feature.copyTrip,
        ])
          ActionChip(
            avatar: Icon(f.icon, size: 18, color: f.color),
            label: Text(f.label(t)),
            // Las que ya existen abren su pantalla; el resto, "muy pronto".
            onPressed: () => context.push(switch (f) {
              Feature.flightRoute => Routes.flightRoute(from: origin),
              Feature.explore => Routes.explore(origin: origin),
              Feature.copyTrip => Routes.copyTrip(),
              Feature.cheapSleep => Routes.stays(),
              Feature.events => Routes.events(),
              _ => Routes.home,
            }),
          ),
      ],
    );
  }
}

/// La hoja para elegir aeropuerto de salida (código IATA de 3 letras).
Future<String?> showOriginSheet(
  BuildContext context, {
  required String current,
}) {
  return showModalBottomSheet<String>(
    context: context,
    useRootNavigator: true,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (BuildContext sheet) => _OriginSheet(current: current),
  );
}

class _OriginSheet extends StatefulWidget {
  const _OriginSheet({required this.current});

  final String current;

  @override
  State<_OriginSheet> createState() => _OriginSheetState();
}

class _OriginSheetState extends State<_OriginSheet> {
  late final TextEditingController _code = TextEditingController(
    text: widget.current,
  );
  bool _invalid = false;

  static final RegExp _iata = RegExp(r'^[A-Z]{3}$');

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  void _save() {
    final String code = _code.text.trim().toUpperCase();
    if (!_iata.hasMatch(code)) {
      setState(() => _invalid = true);
      return;
    }
    Navigator.pop(context, code);
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(
        20,
        0,
        20,
        20 + MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text(
            t.flightsOriginTitle,
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _code,
            autofocus: true,
            maxLength: 3,
            textCapitalization: TextCapitalization.characters,
            decoration: InputDecoration(
              labelText: t.flightsOriginHint,
              errorText: _invalid ? t.flightsOriginInvalid : null,
            ),
            onSubmitted: (_) => _save(),
          ),
          const SizedBox(height: 8),
          FilledButton(onPressed: _save, child: Text(t.flightsOriginSave)),
        ],
      ),
    );
  }
}

/// ¿La ruta vigilada ya está en tu precio? null = no se sabe (falta el
/// precio de ahora o tu objetivo, o están en monedas distintas).
bool? watchOnTarget(Watch w) {
  final Money? target = w.target;
  final Money? now = w.latest?.price;
  if (target == null || now == null || target.currency != now.currency) {
    return null;
  }
  return now.amountMinor <= target.amountMinor;
}

/// "Tarifa error": HOY → +24 H → +48 H · YA PUEDES RESERVAR, con lo que va
/// pasando desde que se vio el precio (como la maqueta).
class ErrorFareTimeline extends StatelessWidget {
  const ErrorFareTimeline({super.key, required this.seenAt, this.now});

  final DateTime seenAt;

  /// Para las pruebas (si no, la hora de ahora).
  final DateTime? now;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    final Duration since = (now ?? DateTime.now()).difference(seenAt);
    final double done = (since.inMinutes / (48 * 60)).clamp(0.0, 1.0);
    final List<String> steps = <String>[
      t.errorFareToday,
      t.errorFare24h,
      t.errorFare48h,
    ];
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF2A2418),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: NomadColors.money),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            t.flightsErrorFareTip,
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 4),
          Text(
            t.errorFareSeen(_ago(t, since)),
            style: const TextStyle(fontSize: 12, color: NomadColors.textMuted),
          ),
          const SizedBox(height: 10),
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: LinearProgressIndicator(
              value: done,
              minHeight: 6,
              color: done >= 1 ? NomadColors.mint : NomadColors.money,
              backgroundColor: NomadColors.surfaceHigh,
            ),
          ),
          const SizedBox(height: 6),
          Row(
            children: <Widget>[
              for (int i = 0; i < steps.length; i++)
                Expanded(
                  child: Text(
                    steps[i],
                    textAlign: switch (i) {
                      0 => TextAlign.start,
                      1 => TextAlign.center,
                      _ => TextAlign.end,
                    },
                    style: TextStyle(
                      fontSize: 10.5,
                      fontWeight: FontWeight.w900,
                      color: done >= i / 2
                          ? (i == 2 ? NomadColors.mint : NomadColors.text)
                          : NomadColors.textMuted,
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  static String _ago(AppLocalizations t, Duration d) {
    if (d.inMinutes < 60) return t.cardsAgoMinutes(d.inMinutes.clamp(1, 59));
    if (d.inHours < 48) return t.cardsAgoHours(d.inHours);
    return t.cardsAgoDays(d.inDays);
  }
}

/// "Buscar ganga de vuelo" (maqueta): ¿cuánto quieres gastar como máximo?
/// Busca entre los chollos REALES de hoy desde tu aeropuerto el más barato
/// que no pase de ese precio. Si no hay, "Subir 100 € y reintentar".
class BargainSheet extends StatefulWidget {
  const BargainSheet({super.key, required this.deals, required this.origin});

  final List<Deal> deals;
  final String origin;

  @override
  State<BargainSheet> createState() => _BargainSheetState();
}

class _BargainSheetState extends State<BargainSheet> {
  /// El tope en unidades enteras de la moneda (euros, no céntimos).
  double _max = 600;

  /// null = aún no se buscó; vacío = no hay ganga hasta ese precio.
  List<Deal>? _found;

  String get _currency => widget.deals.first.fare.price.currency;

  int get _maxMinor {
    int scale = 1;
    for (int i = 0; i < currencyDigits(_currency); i++) {
      scale *= 10;
    }
    return _max.round() * scale;
  }

  void _search() {
    final List<Deal> ok =
        widget.deals
            .where(
              (Deal d) =>
                  d.fare.price.currency == _currency &&
                  d.fare.price.amountMinor <= _maxMinor,
            )
            .toList()
          ..sort(
            (Deal a, Deal b) =>
                a.fare.price.amountMinor.compareTo(b.fare.price.amountMinor),
          );
    setState(() => _found = ok);
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    final TextTheme text = Theme.of(context).textTheme;
    final String label = formatMoney(
      _maxMinor,
      _currency,
      localeOf(context),
      compact: true,
    );
    final List<Deal>? found = _found;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text(t.bargainQuestion, style: text.titleLarge),
          const SizedBox(height: 4),
          Text(
            t.bargainFrom(widget.origin),
            style: text.bodySmall?.copyWith(color: NomadColors.textMuted),
          ),
          const SizedBox(height: 12),
          Text(
            label,
            textAlign: TextAlign.center,
            style: text.displaySmall?.copyWith(
              fontWeight: FontWeight.w900,
              color: NomadColors.flights,
            ),
          ),
          Slider(
            value: _max,
            max: 1200,
            divisions: 120,
            label: label,
            onChanged: (double v) => setState(() => (_max = v, _found = null)),
          ),
          FilledButton.icon(
            onPressed: _search,
            icon: const Icon(Icons.search_rounded),
            label: Text(t.bargainSearch),
          ),
          const SizedBox(height: 12),
          if (found != null && found.isEmpty) ...<Widget>[
            Text(t.bargainNone(label), style: text.bodyLarge),
            const SizedBox(height: 8),
            OutlinedButton(
              onPressed: _max >= 1200
                  ? null
                  : () {
                      setState(() => _max = (_max + 100).clamp(0, 1200));
                      _search();
                    },
              child: Text(t.bargainRaise),
            ),
          ] else if (found != null)
            for (final Deal d in found.take(3))
              Card(
                child: ListTile(
                  leading: const Icon(
                    Icons.flight_rounded,
                    color: NomadColors.flights,
                  ),
                  title: Directionality(
                    textDirection: TextDirection.ltr,
                    child: Text(routeText(d.fare.route)),
                  ),
                  trailing: Text(
                    priceText(context, d.fare.price),
                    style: const TextStyle(
                      fontWeight: FontWeight.w900,
                      fontSize: 16,
                    ),
                  ),
                  onTap: () => Navigator.of(context).pop(d),
                ),
              ),
        ],
      ),
    );
  }
}
