// "Avisar si baja": la hoja para vigilar una ruta, con un precio objetivo
// opcional ("avísame si baja de 300 €"). Sin objetivo, Flyra avisa de
// cualquier bajada importante o tarifa error.
import 'package:flutter/material.dart';

import '../../core/api_client.dart';
import '../../core/services.dart';
import '../../l10n/generated/app_localizations.dart';
import 'fares_api.dart';
import 'flight_format.dart';

/// true si quedó vigilada (para recargar la pantalla de debajo).
Future<bool> showWatchSheet(
  BuildContext context, {
  required FareRoute route,
  required String currency,
  Money? target,
}) async {
  final bool? saved = await showModalBottomSheet<bool>(
    context: context,
    useRootNavigator: true,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (BuildContext sheet) =>
        _WatchSheet(route: route, currency: currency, target: target),
  );
  return saved ?? false;
}

class _WatchSheet extends StatefulWidget {
  const _WatchSheet({
    required this.route,
    required this.currency,
    required this.target,
  });

  final FareRoute route;
  final String currency;
  final Money? target;

  @override
  State<_WatchSheet> createState() => _WatchSheetState();
}

class _WatchSheetState extends State<_WatchSheet> {
  final TextEditingController _amount = TextEditingController();
  String? _error;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final Money? target = widget.target;
    if (target != null) {
      // Lo que ya tenía puesto, sin símbolo (es un campo de número).
      final int digits = currencyDigits(target.currency, 'en');
      int factor = 1;
      for (int i = 0; i < digits; i++) {
        factor *= 10;
      }
      _amount.text = target.amountMinor % factor == 0
          ? '${target.amountMinor ~/ factor}'
          : (target.amountMinor / factor).toStringAsFixed(digits);
    }
  }

  @override
  void dispose() {
    _amount.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final AppLocalizations t = AppLocalizations.of(context);
    final String locale = localeOf(context);
    Money? target;
    if (_amount.text.trim().isNotEmpty) {
      final int? minor = parseAmount(_amount.text, widget.currency, locale);
      if (minor == null) {
        setState(() => _error = t.flightsTargetInvalid);
        return;
      }
      target = Money(minor, widget.currency);
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    final AppServices services = ServicesScope.of(context);
    try {
      await services.fares.watch(widget.route.key, target: target);
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(t.flightsWatchAdded)));
      Navigator.pop(context, true);
    } on ApiException catch (e) {
      if (!mounted) return;
      int max = 50;
      if (e.error == ApiError.conflict) {
        try {
          max = (await services.fares.watches()).$2;
        } on ApiException {
          // nos quedamos con el valor por defecto
        }
      }
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = switch (e.error) {
          ApiError.conflict => t.flightsWatchLimit('$max'),
          ApiError.invalidInput => t.flightsWatchTooLate,
          ApiError.network => t.errorNetwork,
          _ => t.errorUnavailable,
        };
      });
    }
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
            t.flightsTargetTitle,
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 4),
          Directionality(
            textDirection: TextDirection.ltr,
            child: Text(routeText(widget.route)),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _amount,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(
              labelText: t.flightsTargetHint(widget.currency),
              helperText: t.flightsTargetAny,
              helperMaxLines: 2,
              errorText: _error,
              errorMaxLines: 3,
            ),
            onSubmitted: (_) => _save(),
          ),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: _saving ? null : _save,
            child: Text(t.flightsTargetSave),
          ),
        ],
      ),
    );
  }
}
