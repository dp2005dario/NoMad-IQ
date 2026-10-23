// Detalle de una ruta: la gráfica de su precio en los últimos días, el
// último precio, el botón de reservar y "Avisar si baja" / "Dejar de vigilar".
//
// Se abre desde un chollo, desde una ruta vigilada o desde un aviso. Si llega
// con el precio ya conocido (extra), lo enseña al momento; si no (por
// ejemplo, al tocar una notificación), lo saca del historial.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/api_client.dart';
import '../../core/router.dart';
import '../../core/services.dart';
import '../../core/theme.dart';
import '../../l10n/generated/app_localizations.dart';
import 'fares_api.dart';
import 'flight_format.dart';
import 'price_chart.dart';
import 'watch_sheet.dart';

class FareRouteScreen extends StatefulWidget {
  const FareRouteScreen({super.key, required this.routeKey, this.fare});

  final String routeKey;

  /// El último precio, si quien abre la pantalla ya lo tenía.
  final Fare? fare;

  @override
  State<FareRouteScreen> createState() => _FareRouteScreenState();
}

class _FareRouteScreenState extends State<FareRouteScreen> {
  late final AppServices _services = ServicesScope.of(context);
  late final FareRoute? _route = FareRoute.fromKey(widget.routeKey);
  PriceHistory? _history;
  Watch? _watch;
  bool _loading = true;
  bool _guest = false; // invitado: ve precios, pero no puede vigilar
  ApiError? _error;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_loading && _history == null && _error == null) unawaited(_load());
  }

  Future<void> _load() async {
    if (_route == null) {
      setState(() {
        _error = ApiError.notFound;
        _loading = false;
      });
      return;
    }
    setState(() => _loading = true);
    try {
      final PriceHistory history = await _services.fares.history(
        widget.routeKey,
      );
      // El historial lo ve cualquiera; si vigilas la ruta, solo con cuenta.
      List<Watch> watches = <Watch>[];
      bool guest = false;
      try {
        (watches, _) = await _services.fares.watches();
      } on ApiException catch (e) {
        if (e.error != ApiError.signedOut) rethrow;
        guest = true;
      }
      if (!mounted) return;
      setState(() {
        _history = history;
        _guest = guest;
        _watch = watches
            .where((Watch w) => w.route.key == widget.routeKey)
            .firstOrNull;
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

  /// El precio a enseñar: el que nos dieron, el de la ruta vigilada o el
  /// último punto del historial.
  Money? get _price {
    final Fare? fare = widget.fare ?? _watch?.latest;
    if (fare != null) return fare.price;
    final PriceHistory? h = _history;
    if (h == null || h.points.isEmpty || h.currency.isEmpty) return null;
    return Money(h.points.last.minMinor, h.currency);
  }

  Uri? get _booking => (widget.fare ?? _watch?.latest)?.bookingUrl;

  Future<void> _book(Uri url) async {
    final bool opened = await _services.openBooking(url);
    if (!opened && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(AppLocalizations.of(context).flightsBookFailed)),
      );
    }
  }

  Future<void> _toggleWatch() async {
    // Invitado: para vigilar hace falta cuenta (los avisos van a tu nombre).
    if (_guest) {
      await context.push(Routes.signIn);
      if (mounted) unawaited(_load());
      return;
    }
    final FareRoute route = _route!;
    final Watch? watch = _watch;
    if (watch != null) {
      try {
        await _services.fares.unwatch(route.key);
      } on ApiException {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(AppLocalizations.of(context).errorNetwork)),
          );
        }
        return;
      }
      if (mounted) setState(() => _watch = null);
      return;
    }
    final bool saved = await showWatchSheet(
      context,
      route: route,
      currency: _price?.currency ?? 'EUR',
    );
    if (saved && mounted) unawaited(_load());
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    final TextTheme text = Theme.of(context).textTheme;
    final FareRoute? route = _route;
    return Scaffold(
      appBar: AppBar(
        title: route == null
            ? Text(t.flightsTitle)
            : Directionality(
                textDirection: TextDirection.ltr,
                child: Text(routeText(route)),
              ),
      ),
      body: SafeArea(
        child: route == null
            ? Center(child: Text(t.errorUnavailable))
            : RefreshIndicator(
                onRefresh: _load,
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
                  children: <Widget>[
                    Text(
                      tripText(context, t, route),
                      style: text.bodyLarge?.copyWith(
                        color: NomadColors.textMuted,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      _price == null
                          ? t.flightsNoPriceYet
                          : priceText(context, _price!),
                      style: text.displaySmall?.copyWith(
                        color: NomadColors.flights,
                      ),
                    ),
                    if (_watch?.target != null)
                      Text(
                        t.flightsWatchTarget(
                          priceText(context, _watch!.target!),
                        ),
                        style: const TextStyle(color: NomadColors.textMuted),
                      ),
                    const SizedBox(height: 24),
                    Text(t.flightsHistory, style: text.titleLarge),
                    const SizedBox(height: 12),
                    _chart(context, t),
                    const SizedBox(height: 28),
                    if (_booking != null) ...<Widget>[
                      FilledButton.icon(
                        onPressed: () => _book(_booking!),
                        icon: const Icon(Icons.open_in_new_rounded),
                        label: Text(t.flightsBook),
                      ),
                      const SizedBox(height: 10),
                    ],
                    if (_guest)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Text(
                          t.flightsSignIn,
                          style: const TextStyle(color: NomadColors.textMuted),
                        ),
                      ),
                    if (_error != ApiError.signedOut)
                      OutlinedButton.icon(
                        onPressed: _loading ? null : _toggleWatch,
                        icon: Icon(
                          _watch == null
                              ? Icons.notifications_active_rounded
                              : Icons.notifications_off_rounded,
                        ),
                        label: Text(
                          _watch == null
                              ? t.flightsNotify
                              : t.flightsStopWatching,
                        ),
                      ),
                  ],
                ),
              ),
      ),
    );
  }

  Widget _chart(BuildContext context, AppLocalizations t) {
    final TextStyle muted = const TextStyle(color: NomadColors.textMuted);
    if (_loading && _history == null) {
      return const SizedBox(
        height: 160,
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (_error != null) {
      return Text(switch (_error!) {
        ApiError.signedOut => t.flightsSignIn,
        ApiError.network => t.errorNetwork,
        _ => t.errorUnavailable,
      }, style: muted);
    }
    final PriceHistory h = _history!;
    if (h.points.length < 2 || h.currency.isEmpty) {
      return Text(t.flightsHistoryEmpty, style: muted);
    }
    final int lowest = h.points
        .map((PricePoint p) => p.minMinor)
        .reduce((int a, int b) => a < b ? a : b);
    final String lowText = priceText(context, Money(lowest, h.currency));
    final String lastText = priceText(
      context,
      Money(h.points.last.minMinor, h.currency),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        PriceChart(
          points: h.points,
          semanticLabel: t.flightsChartLabel(
            '${h.points.length}',
            lowText,
            lastText,
          ),
        ),
        const SizedBox(height: 8),
        Text(t.flightsLowest(lowText), style: muted),
      ],
    );
  }
}
