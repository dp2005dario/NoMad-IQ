// "Copia este viaje" (maqueta "Copiar"): escribes el código que te pasó
// alguien, ves su viaje con el precio de cada cosa, eliges tu presupuesto y
// Flyra cambia lo caro por opciones más baratas. "Copiar a mis viajes" lo
// guarda en tu móvil.
//
// Sin código, la pantalla enseña tus viajes copiados y los que has
// compartido tú (con su código y cuánta gente los ha copiado).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';

import '../../core/api_client.dart';
import '../../core/money.dart';
import '../../core/router.dart';
import '../../core/services.dart';
import '../../core/theme.dart';
import '../../l10n/generated/app_localizations.dart';
import 'copied_trips.dart';
import 'shared_trip_api.dart';

/// El icono de cada tipo de línea.
IconData tripKindIcon(TripKind k) => switch (k) {
  TripKind.flight => Icons.flight_rounded,
  TripKind.stay => Icons.hotel_rounded,
  TripKind.transport => Icons.train_rounded,
  TripKind.food => Icons.restaurant_rounded,
  TripKind.activity => Icons.local_activity_rounded,
  TripKind.other => Icons.more_horiz_rounded,
};

String tripKindLabel(AppLocalizations t, TripKind k) => switch (k) {
  TripKind.flight => t.copyKindFlight,
  TripKind.stay => t.copyKindStay,
  TripKind.transport => t.copyKindTransport,
  TripKind.food => t.copyKindFood,
  TripKind.activity => t.copyKindActivity,
  TripKind.other => t.copyKindOther,
};

/// Los presupuestos que se ofrecen: el del original, 3/4 y la mitad
/// (redondeados a decenas para que se lean bien: 1.800 €, no 1.793 €).
List<int> budgetSteps(int totalMinor, String currency) {
  final int ten = wholeToMinor(10, currency);
  int round(int v) => v < ten ? v : (v ~/ ten) * ten;
  return <int>[
    totalMinor,
    if (totalMinor >= 4 * ten) round(totalMinor * 3 ~/ 4),
    if (totalMinor >= 4 * ten) round(totalMinor ~/ 2),
  ];
}

class CopyTripScreen extends StatefulWidget {
  const CopyTripScreen({super.key, this.code});

  /// Si llega un código (un enlace), se abre directamente ese viaje.
  final String? code;

  @override
  State<CopyTripScreen> createState() => _CopyTripScreenState();
}

class _CopyTripScreenState extends State<CopyTripScreen> {
  late final AppServices _services = ServicesScope.of(context);
  late final CopiedTrips _copied = CopiedTrips(_services.prefs);
  final TextEditingController _code = TextEditingController();

  SharedTrip? _trip;
  bool _opening = false;
  String? _error;
  Future<List<SharedTrip>>? _mine;

  @override
  void initState() {
    super.initState();
    final String? code = widget.code;
    if (code != null) {
      _code.text = code;
      WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_open()));
    }
  }

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  String _errorText(AppLocalizations t, Object e) => switch (e) {
    ApiException(error: ApiError.notFound) => t.copyNotFound,
    ApiException(error: ApiError.network) => t.copyOffline,
    _ => t.copyFailed,
  };

  Future<void> _open() async {
    final AppLocalizations t = AppLocalizations.of(context);
    final String? code = normalizeTripCode(_code.text);
    if (code == null) {
      setState(() => _error = t.copyBadCode);
      return;
    }
    setState(() {
      _opening = true;
      _error = null;
    });
    try {
      final SharedTrip trip = await _services.sharedTrips.get(code);
      if (mounted) setState(() => _trip = trip);
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = _errorText(t, e));
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  Future<void> _share() async {
    final SharedTrip? shared = await context.push<SharedTrip>(Routes.shareTrip);
    if (shared != null && mounted) {
      setState(() => _mine = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    final SharedTrip? trip = _trip;
    if (trip != null) {
      return _TripView(
        trip: trip,
        copied: _copied,
        onClose: () => setState(() {
          _trip = null;
          _mine = null;
        }),
      );
    }
    final TextTheme text = Theme.of(context).textTheme;
    final String locale = Localizations.localeOf(context).toLanguageTag();
    final List<CopiedTrip> copied = _copied.all();
    final Future<List<SharedTrip>> mine = _mine ??= _services.sharedTrips
        .mine();
    return Scaffold(
      appBar: AppBar(title: Text(t.copyTitle)),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => unawaited(_share()),
        icon: const Icon(Icons.ios_share_rounded),
        label: Text(t.copyShareMine),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 96),
        children: <Widget>[
          Text(
            t.copySubtitle,
            style: text.bodyMedium?.copyWith(color: NomadColors.textMuted),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _code,
            textCapitalization: TextCapitalization.characters,
            inputFormatters: <TextInputFormatter>[
              LengthLimitingTextInputFormatter(12),
            ],
            onSubmitted: (_) => unawaited(_open()),
            decoration: InputDecoration(
              labelText: t.copyCodeLabel,
              hintText: '7K2M-9QXD',
              errorText: _error,
            ),
          ),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: _opening ? null : () => unawaited(_open()),
            child: _opening
                ? const SizedBox.square(
                    dimension: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Text(t.copyOpen),
          ),
          const SizedBox(height: 24),
          Text(t.copyMyCopies, style: text.labelLarge),
          const SizedBox(height: 8),
          if (copied.isEmpty)
            Text(
              t.copyNoCopies,
              style: const TextStyle(color: NomadColors.textMuted),
            ),
          for (final CopiedTrip c in copied)
            Card(
              child: ExpansionTile(
                leading: const Icon(Icons.bookmark_rounded),
                title: Text(c.title),
                subtitle: Text(
                  t.copyTripLine(
                    c.destination,
                    c.days,
                    formatMoney(
                      c.totalMinor,
                      c.currency,
                      locale,
                      compact: true,
                    ),
                  ),
                ),
                children: <Widget>[
                  for (final TripLine l in c.lines)
                    ListTile(
                      dense: true,
                      leading: Icon(tripKindIcon(l.kind), size: 20),
                      title: Text(l.title),
                      trailing: Text(
                        formatMoney(l.priceMinor, c.currency, locale),
                      ),
                    ),
                  TextButton.icon(
                    onPressed: () async {
                      await _copied.remove(c.code);
                      if (mounted) setState(() {});
                    },
                    icon: const Icon(Icons.delete_outline_rounded),
                    label: Text(t.copyRemove),
                  ),
                ],
              ),
            ),
          const SizedBox(height: 24),
          Text(t.copySharedByMe, style: text.labelLarge),
          const SizedBox(height: 8),
          FutureBuilder<List<SharedTrip>>(
            future: mine,
            builder: (BuildContext context, AsyncSnapshot<List<SharedTrip>> s) {
              if (s.connectionState != ConnectionState.done) {
                return const LinearProgressIndicator();
              }
              final List<SharedTrip>? trips = s.data;
              if (trips == null) {
                return Text(
                  t.copyOffline,
                  style: const TextStyle(color: NomadColors.textMuted),
                );
              }
              if (trips.isEmpty) {
                return Text(
                  t.copyNoShared,
                  style: const TextStyle(color: NomadColors.textMuted),
                );
              }
              return Column(
                children: <Widget>[
                  for (final SharedTrip m in trips)
                    Card(
                      child: ListTile(
                        leading: const Icon(Icons.public_rounded),
                        title: Text(m.title),
                        subtitle: Text(
                          '${_pretty(m.code)} · ${t.copyCopies(m.copies)}',
                        ),
                        trailing: const Icon(Icons.chevron_right_rounded),
                        onTap: () => setState(() => _trip = m),
                      ),
                    ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}

/// "7K2M9QXD" → "7K2M-9QXD" (más fácil de dictar).
String _pretty(String code) =>
    code.length == 8 ? '${code.substring(0, 4)}-${code.substring(4)}' : code;

class _TripView extends StatefulWidget {
  const _TripView({
    required this.trip,
    required this.copied,
    required this.onClose,
  });

  final SharedTrip trip;
  final CopiedTrips copied;
  final VoidCallback onClose;

  @override
  State<_TripView> createState() => _TripViewState();
}

class _TripViewState extends State<_TripView> {
  late final AppServices _services = ServicesScope.of(context);
  late final List<int> _steps = budgetSteps(
    widget.trip.totalMinor,
    widget.trip.currency,
  );
  late TripAdaptation _shown = TripAdaptation.original(widget.trip);

  /// Las adaptaciones ya pedidas (volver a un chip no gasta otro uso).
  final Map<int, TripAdaptation> _done = <int, TripAdaptation>{};
  int _step = 0;
  bool _adapting = false;
  bool _saved = false;
  String? _error;

  Future<void> _pick(int i) async {
    final AppLocalizations t = AppLocalizations.of(context);
    setState(() {
      _step = i;
      _saved = false;
      _error = null;
    });
    if (i == 0) {
      setState(() => _shown = TripAdaptation.original(widget.trip));
      return;
    }
    final TripAdaptation? cached = _done[i];
    if (cached != null) {
      setState(() => _shown = cached);
      return;
    }
    setState(() => _adapting = true);
    try {
      final TripAdaptation a = await _services.sharedTrips.adapt(
        widget.trip.code,
        budgetMinor: _steps[i],
        language: Localizations.localeOf(context).languageCode,
      );
      _done[i] = a;
      if (mounted && _step == i) setState(() => _shown = a);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(
        () => _error = switch (e.error) {
          ApiError.rateLimited => t.copyQuotaGone,
          ApiError.network => t.copyOffline,
          _ => t.copyFlyraBusy,
        },
      );
    } finally {
      if (mounted) setState(() => _adapting = false);
    }
  }

  Future<void> _save() async {
    final SharedTrip trip = widget.trip;
    await widget.copied.add(
      CopiedTrip(
        code: trip.code,
        title: trip.title,
        destination: trip.destination,
        days: trip.days,
        currency: trip.currency,
        lines: <TripLine>[for (final AdaptedLine l in _shown.lines) l.line],
        copiedAt: DateTime.now(),
      ),
    );
    if (mounted) setState(() => _saved = true);
    // Contar la copia es solo para el "copiado N veces": si falla (sin red),
    // el viaje ya está en tu móvil igualmente.
    try {
      await _services.sharedTrips.copy(trip.code);
    } on ApiException {
      // Nada: no es importante.
    }
  }

  Future<void> _unshare() async {
    final AppLocalizations t = AppLocalizations.of(context);
    try {
      await _services.sharedTrips.unshare(widget.trip.code);
      widget.onClose();
    } on ApiException {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(t.copyFailed)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    final TextTheme text = Theme.of(context).textTheme;
    final String locale = Localizations.localeOf(context).toLanguageTag();
    final SharedTrip trip = widget.trip;
    String money(int minor, {bool compact = false}) =>
        formatMoney(minor, trip.currency, locale, compact: compact);
    final TripAdaptation a = _shown;
    final bool fits = _step == 0 || a.totalMinor <= _steps[_step];
    return Scaffold(
      appBar: AppBar(
        leading: BackButton(onPressed: widget.onClose),
        title: Text(t.copyTitle),
        actions: <Widget>[
          IconButton(
            tooltip: t.copyCopyCode,
            icon: const Icon(Icons.copy_rounded),
            onPressed: () => unawaited(
              Clipboard.setData(ClipboardData(text: _pretty(trip.code))),
            ),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
        children: <Widget>[
          Text(trip.title, style: text.headlineSmall),
          const SizedBox(height: 4),
          Text(
            t.copyBy(
              trip.author,
              money(trip.totalMinor, compact: true),
              trip.copies,
            ),
            style: const TextStyle(color: NomadColors.textMuted),
          ),
          Text(
            t.copyTripLine(
              trip.destination,
              trip.days,
              money(trip.totalMinor, compact: true),
            ),
            style: const TextStyle(color: NomadColors.textMuted),
          ),
          const SizedBox(height: 20),
          Text(t.copyYourBudget, style: text.labelLarge),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              for (int i = 0; i < _steps.length; i++)
                ChoiceChip(
                  label: Text(money(_steps[i], compact: true)),
                  selected: _step == i,
                  onSelected: _adapting ? null : (_) => unawaited(_pick(i)),
                ),
            ],
          ),
          if (_step > 0) ...<Widget>[
            const SizedBox(height: 6),
            Text(
              t.copyFlyraAdapts,
              style: text.bodySmall?.copyWith(color: NomadColors.textMuted),
            ),
          ],
          const SizedBox(height: 12),
          if (_adapting) const LinearProgressIndicator(),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(
                _error!,
                style: const TextStyle(color: NomadColors.safety),
              ),
            ),
          for (final AdaptedLine l in a.lines)
            Card(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
                side: BorderSide(
                  color: l.changed
                      ? NomadColors.mint.withValues(alpha: 0.5)
                      : NomadColors.outline,
                ),
              ),
              child: ListTile(
                leading: Icon(
                  tripKindIcon(l.line.kind),
                  color: l.changed ? NomadColors.mint : NomadColors.textMuted,
                ),
                title: Text(l.line.title),
                subtitle: Text(
                  l.changed ? t.copyWas(trip.author, l.wasTitle) : t.copySame,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: <Widget>[
                    Text(money(l.line.priceMinor)),
                    if (l.changed)
                      Text(
                        money(l.wasPriceMinor),
                        style: const TextStyle(
                          fontSize: 11,
                          color: NomadColors.textMuted,
                          decoration: TextDecoration.lineThrough,
                        ),
                      ),
                  ],
                ),
              ),
            ),
          const SizedBox(height: 12),
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  a.changes == 0
                      ? t.copyAsIs(trip.author)
                      : t.copyChanges(a.changes, money(_steps[_step])),
                ),
              ),
              Text(
                money(a.totalMinor),
                style: text.titleLarge?.copyWith(
                  color: fits ? NomadColors.mint : NomadColors.safety,
                ),
              ),
            ],
          ),
          if (!fits)
            Text(
              t.copyDoesNotFit,
              style: const TextStyle(color: NomadColors.safety),
            ),
          const SizedBox(height: 16),
          if (_saved)
            OutlinedButton.icon(
              onPressed: null,
              icon: const Icon(Icons.check_rounded),
              label: Text(t.copySaved),
            )
          else
            FilledButton.icon(
              onPressed: _adapting ? null : () => unawaited(_save()),
              icon: const Icon(Icons.bookmark_add_rounded),
              label: Text(t.copySave),
            ),
          const SizedBox(height: 12),
          Text(
            t.copyPricesNote,
            style: text.bodySmall?.copyWith(color: NomadColors.textMuted),
          ),
          if (trip.mine) ...<Widget>[
            const SizedBox(height: 16),
            TextButton.icon(
              onPressed: () => unawaited(_unshare()),
              icon: const Icon(Icons.public_off_rounded),
              label: Text(t.copyUnshare),
            ),
          ],
        ],
      ),
    );
  }
}
