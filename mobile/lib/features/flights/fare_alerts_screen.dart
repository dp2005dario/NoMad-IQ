// "Alertas de precio": los últimos avisos que te ha mandado Flyra (lo mismo
// que llegó como notificación, por si la borraste). Tocar uno abre la ruta.
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

class FareAlertsScreen extends StatefulWidget {
  const FareAlertsScreen({super.key});

  @override
  State<FareAlertsScreen> createState() => _FareAlertsScreenState();
}

class _FareAlertsScreenState extends State<FareAlertsScreen> {
  late final AppServices _services = ServicesScope.of(context);
  List<FareAlert>? _alerts;
  ApiError? _error;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_alerts == null && _error == null) unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final List<FareAlert> alerts = await _services.fares.alerts();
      if (mounted) {
        setState(() {
          _alerts = alerts;
          _error = null;
        });
      }
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.error);
    }
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    final List<FareAlert>? alerts = _alerts;
    final ApiError? error = _error;
    return Scaffold(
      appBar: AppBar(title: Text(t.flightsAlertsTitle)),
      body: SafeArea(
        child: error != null
            ? _Message(
                text: switch (error) {
                  ApiError.signedOut => t.flightsSignIn,
                  ApiError.network => t.errorNetwork,
                  _ => t.errorUnavailable,
                },
                action: error == ApiError.signedOut
                    ? t.signInFromGuest
                    : t.guideRetry,
                onAction: error == ApiError.signedOut
                    ? () => unawaited(context.push(Routes.signIn))
                    : () => unawaited(_load()),
              )
            : alerts == null
            ? const Center(child: CircularProgressIndicator())
            : alerts.isEmpty
            ? _Message(text: t.flightsNoAlerts)
            : RefreshIndicator(
                onRefresh: _load,
                child: ListView.separated(
                  padding: const EdgeInsets.all(16),
                  itemCount: alerts.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 8),
                  itemBuilder: (BuildContext context, int i) =>
                      _AlertTile(alert: alerts[i]),
                ),
              ),
      ),
    );
  }
}

class _AlertTile extends StatelessWidget {
  const _AlertTile({required this.alert});

  final FareAlert alert;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    final TextTheme text = Theme.of(context).textTheme;
    final String title = switch (alert.type) {
      FareAlertType.priceDrop => t.pushFareDropTitle,
      FareAlertType.errorFare => t.pushFareErrorTitle,
      FareAlertType.targetReached => t.pushFareTargetTitle,
    };
    final int percent = dropPercent(alert.dropBasisPoints);
    return Card(
      clipBehavior: Clip.antiAlias,
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        leading: Icon(
          alert.type == FareAlertType.errorFare
              ? Icons.local_fire_department_rounded
              : Icons.trending_down_rounded,
          color: alert.type == FareAlertType.errorFare
              ? NomadColors.money
              : NomadColors.mint,
        ),
        title: Text(title, style: text.titleMedium),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Directionality(
              textDirection: TextDirection.ltr,
              child: Text(routeText(alert.route)),
            ),
            Text(tripText(context, t, alert.route)),
            Text(
              t.flightsPriceChange(
                priceText(context, alert.reference),
                priceText(context, alert.current),
              ),
              style: const TextStyle(
                color: NomadColors.flights,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
        trailing: percent >= 1
            ? Text(
                t.flightsDrop('$percent'),
                style: const TextStyle(
                  color: NomadColors.mint,
                  fontWeight: FontWeight.w800,
                ),
              )
            : null,
        onTap: () => context.push(
          Routes.fareRoute(alert.route.key),
          extra: Fare(
            route: alert.route,
            price: alert.current,
            bookingUrl: alert.bookingUrl,
            observedAt: alert.observedAt,
          ),
        ),
      ),
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({required this.text, this.action, this.onAction});

  final String text;
  final String? action;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(
              text,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyLarge,
            ),
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
