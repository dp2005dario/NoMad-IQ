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
import '../../core/router.dart';
import '../../core/services.dart';
import '../../core/theme.dart';
import '../../l10n/generated/app_localizations.dart';
import '../coming_soon/coming_soon_screen.dart';
import 'fares_api.dart';
import 'flight_format.dart';
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
              _PlanShortcuts(t: t),
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
          const SizedBox(height: 8),
          Text(
            t.flightsErrorFareTip,
            style: text.bodySmall?.copyWith(color: NomadColors.textMuted),
          ),
        ],
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
            onTap: () => _openRoute(w.route, fare: w.latest),
          ),
    ];
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
  const _PlanShortcuts({required this.t});

  final AppLocalizations t;

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
          Feature.stopover,
          Feature.events,
          Feature.copyTrip,
        ])
          ActionChip(
            avatar: Icon(f.icon, size: 18, color: f.color),
            label: Text(f.label(t)),
            onPressed: () => context.push(Routes.soon(f)),
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
