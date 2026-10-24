// Papeles y derechos (maqueta "Papeles"): antes de salir se revisan los
// documentos de la Bóveda para el viaje y, si un vuelo sale mal, se calcula
// lo que te deben por la norma europea y se escribe la carta de reclamación.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../core/services.dart';
import '../../core/theme.dart';
import '../../l10n/generated/app_localizations.dart';
import '../../core/money.dart';
import '../route/flight3d.dart' show CountryCodes;
import '../route/world_data.dart';
import '../vault/vault.dart';
import '../vault/vault_store.dart';
import 'eu261.dart';
import 'trip_check.dart';

class PapersScreen extends StatefulWidget {
  const PapersScreen({super.key});

  @override
  State<PapersScreen> createState() => _PapersScreenState();
}

class _PapersScreenState extends State<PapersScreen> {
  late final AppServices _services = ServicesScope.of(context);
  Airports? _airports;
  CountryCodes? _codes;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final WorldData world = await WorldData.load();
      final CountryCodes codes = await CountryCodes.load();
      if (!mounted) return;
      setState(() {
        _airports = world.airports;
        _codes = codes;
      });
    } on Object {
      // Sin los datos del mundo no se pueden buscar aeropuertos: la
      // pantalla lo dice en cada campo ("no conocemos ese aeropuerto").
    }
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    final TextTheme text = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(title: Text(t.papersTitle)),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
        children: <Widget>[
          Text(
            t.papersSubtitle,
            style: text.bodyMedium?.copyWith(color: NomadColors.textMuted),
          ),
          _Section(t.papersBeforeTitle),
          _BeforeYouGo(
            airports: _airports,
            codes: _codes,
            vault: _services.vault,
            openLink: _services.openLink,
          ),
          _Section(t.papersRightsTitle),
          _Rights(
            airports: _airports,
            codes: _codes,
            openLink: _services.openLink,
          ),
        ],
      ),
    );
  }
}

String _day(BuildContext context, DateTime d) =>
    DateFormat.yMMMd(Localizations.localeOf(context).toLanguageTag()).format(d);

/// Busca un aeropuerto por su código (null si no existe o aún no se cargó).
Airport? _airport(Airports? all, String code) {
  final String c = code.trim();
  if (all == null || c.length != 3) return null;
  return all[c];
}

class _BeforeYouGo extends StatefulWidget {
  const _BeforeYouGo({
    required this.airports,
    required this.codes,
    required this.vault,
    required this.openLink,
  });

  final Airports? airports;
  final CountryCodes? codes;
  final Vault vault;
  final Future<bool> Function(Uri) openLink;

  @override
  State<_BeforeYouGo> createState() => _BeforeYouGoState();
}

class _BeforeYouGoState extends State<_BeforeYouGo> {
  final TextEditingController _to = TextEditingController();
  DateTime? _back;
  TripChecks? _checks;
  String? _country;

  @override
  void dispose() {
    _to.dispose();
    super.dispose();
  }

  Future<void> _pickBack() async {
    final DateTime now = DateTime.now();
    final DateTime? d = await showDatePicker(
      context: context,
      firstDate: DateTime(now.year, now.month, now.day),
      lastDate: DateTime(now.year + 2, now.month, now.day),
      initialDate: _back ?? now.add(const Duration(days: 7)),
    );
    if (d != null && mounted) setState(() => _back = d);
  }

  Future<void> _check() async {
    final AppLocalizations t = AppLocalizations.of(context);
    final Airport? to = _airport(widget.airports, _to.text);
    final DateTime? back = _back;
    if (to == null || back == null) return;
    if (!widget.vault.isOpen) {
      final UnlockResult r = await widget.vault.open(t.vaultUnlockReason);
      if (r != UnlockResult.ok || !mounted) return;
    }
    setState(() {
      _checks = checkTrip(widget.vault.docs, back);
      _country = widget.codes?[to.country];
    });
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    final Airport? to = _airport(widget.airports, _to.text);
    final bool badAirport = _to.text.trim().length == 3 && to == null;
    final TripChecks? c = _checks;
    final (String, String)? permit = entryPermits[_country];
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            TextField(
              controller: _to,
              maxLength: 3,
              textCapitalization: TextCapitalization.characters,
              onChanged: (_) => setState(() => _checks = null),
              decoration: InputDecoration(
                labelText: t.papersDestination,
                counterText: '',
                errorText: badAirport ? t.papersUnknownAirport : null,
                helperText: to == null ? null : '${to.city} · ${to.country}',
              ),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              icon: const Icon(Icons.event_rounded),
              label: Text(
                _back == null
                    ? t.papersPickReturn
                    : t.papersReturn(_day(context, _back!)),
              ),
              onPressed: _pickBack,
            ),
            const SizedBox(height: 8),
            FilledButton.icon(
              icon: const Icon(Icons.fingerprint_rounded),
              label: Text(t.papersCheck),
              onPressed: to == null || _back == null ? null : _check,
            ),
            if (c != null) ...<Widget>[
              const SizedBox(height: 12),
              Text(
                c.issues == 0 ? t.papersAllGood : t.papersIssues(c.issues),
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  color: c.issues == 0 ? NomadColors.mint : NomadColors.money,
                ),
              ),
              _CheckLine(
                state: c.passport,
                text: switch (c.passport) {
                  CheckState.ok => t.papersPassportOk(
                    _day(context, c.passportExpires!),
                  ),
                  CheckState.warning =>
                    c.passportExpires == null
                        ? t.papersPassportNoDate
                        : t.papersPassportShort(
                            _day(context, c.passportExpires!),
                          ),
                  CheckState.missing => t.papersPassportMissing,
                },
              ),
              _CheckLine(
                state: c.insurance,
                text: switch (c.insurance) {
                  CheckState.ok => t.papersInsuranceOk,
                  CheckState.warning => t.papersInsuranceExpired,
                  CheckState.missing => t.papersInsuranceMissing,
                },
              ),
              if (permit != null)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(
                    Icons.assignment_rounded,
                    color: NomadColors.flights,
                  ),
                  title: Text(t.papersPermit(permit.$1)),
                  trailing: TextButton(
                    onPressed: () => widget.openLink(Uri.parse(permit.$2)),
                    child: Text(t.papersOfficialSite),
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }
}

class _CheckLine extends StatelessWidget {
  const _CheckLine({required this.state, required this.text});

  final CheckState state;
  final String text;

  @override
  Widget build(BuildContext context) => ListTile(
    contentPadding: EdgeInsets.zero,
    leading: Icon(switch (state) {
      CheckState.ok => Icons.check_circle_rounded,
      CheckState.warning => Icons.warning_amber_rounded,
      CheckState.missing => Icons.help_outline_rounded,
    }, color: state == CheckState.ok ? NomadColors.mint : NomadColors.money),
    title: Text(text),
  );
}

class _Rights extends StatefulWidget {
  const _Rights({
    required this.airports,
    required this.codes,
    required this.openLink,
  });

  final Airports? airports;
  final CountryCodes? codes;
  final Future<bool> Function(Uri) openLink;

  @override
  State<_Rights> createState() => _RightsState();
}

class _RightsState extends State<_Rights> {
  final TextEditingController _from = TextEditingController();
  final TextEditingController _to = TextEditingController();
  bool _euAirline = true;
  Disruption _what = Disruption.delay;
  int _hours = 4;

  @override
  void dispose() {
    _from.dispose();
    _to.dispose();
    super.dispose();
  }

  Eu261Result? _result(Airport? from, Airport? to) {
    if (from == null || to == null || from.iata == to.iata) return null;
    return eu261(
      fromCountry: widget.codes?[from.country],
      toCountry: widget.codes?[to.country],
      from: from.position,
      to: to.position,
      euAirline: _euAirline,
      what: _what,
      delayMinutes: _hours * 60,
    );
  }

  Future<void> _claim(Airport from, Airport to, Eu261Result r) async {
    final AppLocalizations t = AppLocalizations.of(context);
    final ClaimDetails? details = await showDialog<ClaimDetails>(
      context: context,
      builder: (BuildContext context) => _ClaimDialog(
        from: from,
        to: to,
        what: _what,
        delayMinutes: _hours * 60,
        euros: r.euros,
      ),
    );
    if (details == null || !mounted) return;
    final bool opened = await widget.openLink(claimEmail(details));
    if (!opened && mounted) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(t.papersNoEmailApp)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    final TextTheme text = Theme.of(context).textTheme;
    final Airport? from = _airport(widget.airports, _from.text);
    final Airport? to = _airport(widget.airports, _to.text);
    final Eu261Result? r = _result(from, to);

    Widget airportField(TextEditingController c, String label, Airport? a) =>
        Expanded(
          child: TextField(
            controller: c,
            maxLength: 3,
            textCapitalization: TextCapitalization.characters,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              labelText: label,
              counterText: '',
              helperText: a?.city,
              errorText: c.text.trim().length == 3 && a == null
                  ? t.papersUnknownAirport
                  : null,
            ),
          ),
        );

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text(t.papersRightsIntro),
            const SizedBox(height: 12),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                airportField(_from, t.papersFrom, from),
                const SizedBox(width: 12),
                airportField(_to, t.papersTo, to),
              ],
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(t.papersEuAirline),
              value: _euAirline,
              onChanged: (bool v) => setState(() => _euAirline = v),
            ),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: <Widget>[
                for (final (Disruption d, String label)
                    in <(Disruption, String)>[
                      (Disruption.delay, t.papersDelay),
                      (Disruption.cancelled, t.papersCancelled),
                      (Disruption.deniedBoarding, t.papersDenied),
                    ])
                  ChoiceChip(
                    label: Text(label),
                    selected: _what == d,
                    onSelected: (_) => setState(() => _what = d),
                  ),
              ],
            ),
            if (_what == Disruption.delay) ...<Widget>[
              const SizedBox(height: 8),
              Text(t.papersDelayHours(_hours)),
              Slider(
                min: 0,
                max: 12,
                divisions: 12,
                value: _hours.toDouble(),
                label: '$_hours h',
                onChanged: (double v) => setState(() => _hours = v.round()),
              ),
            ],
            if (r != null) ...<Widget>[
              const SizedBox(height: 8),
              if (r.covered) ...<Widget>[
                Text(
                  t.papersYouMayGet(
                    formatMoney(
                      r.euros * 100,
                      'EUR',
                      Localizations.localeOf(context).toLanguageTag(),
                      compact: true,
                    ),
                  ),
                  style: text.headlineSmall?.copyWith(color: NomadColors.mint),
                ),
                Text(t.papersDistance(r.km), style: text.bodySmall),
                const SizedBox(height: 8),
                Text(
                  t.papersExtraordinary,
                  style: text.bodySmall?.copyWith(color: NomadColors.textMuted),
                ),
                const SizedBox(height: 12),
                FilledButton.icon(
                  icon: const Icon(Icons.mail_rounded),
                  label: Text(t.papersClaim),
                  onPressed: () => _claim(from!, to!, r),
                ),
                const SizedBox(height: 8),
                Text(
                  t.papersClaimNote,
                  style: text.bodySmall?.copyWith(color: NomadColors.textMuted),
                ),
              ] else
                Text(
                  r.reason == Eu261Reason.notEuRoute
                      ? t.papersNotEu
                      : t.papersShortDelay,
                ),
            ],
          ],
        ),
      ),
    );
  }
}

class _ClaimDialog extends StatefulWidget {
  const _ClaimDialog({
    required this.from,
    required this.to,
    required this.what,
    required this.delayMinutes,
    required this.euros,
  });

  final Airport from;
  final Airport to;
  final Disruption what;
  final int delayMinutes;
  final int euros;

  @override
  State<_ClaimDialog> createState() => _ClaimDialogState();
}

class _ClaimDialogState extends State<_ClaimDialog> {
  final TextEditingController _name = TextEditingController();
  final TextEditingController _booking = TextEditingController();
  final TextEditingController _flight = TextEditingController();
  DateTime _date = DateTime.now();
  bool _tried = false;

  @override
  void dispose() {
    _name.dispose();
    _booking.dispose();
    _flight.dispose();
    super.dispose();
  }

  void _send() {
    if (<TextEditingController>[
      _name,
      _booking,
      _flight,
    ].any((TextEditingController c) => c.text.trim().isEmpty)) {
      setState(() => _tried = true);
      return;
    }
    Navigator.pop(
      context,
      ClaimDetails(
        name: _name.text.trim(),
        booking: _booking.text.trim().toUpperCase(),
        flight: _flight.text.trim().toUpperCase(),
        date: _date,
        from: widget.from,
        to: widget.to,
        what: widget.what,
        delayMinutes: widget.delayMinutes,
        euros: widget.euros,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    return AlertDialog(
      title: Text(t.papersClaim),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            for (final (TextEditingController c, String label, int max)
                in <(TextEditingController, String, int)>[
                  (_name, t.papersName, 80),
                  (_booking, t.papersBooking, 12),
                  (_flight, t.papersFlight, 8),
                ])
              TextField(
                controller: c,
                maxLength: max,
                decoration: InputDecoration(labelText: label, counterText: ''),
              ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              icon: const Icon(Icons.event_rounded),
              label: Text(t.papersFlightDay(_day(context, _date))),
              onPressed: () async {
                final DateTime now = DateTime.now();
                final DateTime? d = await showDatePicker(
                  context: context,
                  // Se puede reclamar hasta años después (depende del país).
                  firstDate: DateTime(now.year - 6),
                  lastDate: now,
                  initialDate: _date,
                );
                if (d != null && mounted) setState(() => _date = d);
              },
            ),
            if (_tried)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  t.papersFillAll,
                  style: const TextStyle(color: NomadColors.safety),
                ),
              ),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(MaterialLocalizations.of(context).cancelButtonLabel),
        ),
        FilledButton(
          style: FilledButton.styleFrom(minimumSize: const Size(0, 48)),
          onPressed: _send,
          child: Text(t.papersSendEmail),
        ),
      ],
    );
  }
}

class _Section extends StatelessWidget {
  const _Section(this.label);

  final String label;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(4, 24, 4, 8),
    child: Text(
      label,
      style: Theme.of(context).textTheme.labelMedium
          ?.copyWith(color: NomadColors.textMuted, letterSpacing: 1.2),
    ),
  );
}
