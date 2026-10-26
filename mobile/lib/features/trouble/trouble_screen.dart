// "Si algo falla" (maqueta "Incidencias"), con dos pestañas:
//
//   - Mi maleta: no ha llegado o llegó rota. Lista de pasos, tus datos del
//     parte (PIR), los plazos del Convenio de Montreal y la carta para la
//     aerolínea ya escrita.
//   - Escala perdida: qué hacer según tengas una sola reserva o billetes
//     sueltos, tus derechos y buscar el siguiente vuelo.
//
// La maqueta "veía" la maleta en el mapa con una etiqueta Bluetooth y
// reservaba sola el vuelo alternativo. Eso necesita los sistemas de las
// aerolíneas (WorldTracer, reservas), que no son públicos ni gratis. Lo que
// sí hacemos: si llevas un AirTag, SmartTag o Tile, pegas aquí el enlace para
// compartir su ubicación y va en la carta (muchas aerolíneas ya lo aceptan).
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../core/router.dart';
import '../../core/services.dart';
import '../../core/settings.dart';
import '../../core/theme.dart';
import '../../l10n/generated/app_localizations.dart';
import '../easy/easy_mode.dart';
import 'bag_claim.dart';

enum _Tab { bag, connection }

class TroubleScreen extends StatefulWidget {
  const TroubleScreen({super.key});

  @override
  State<TroubleScreen> createState() => _TroubleScreenState();
}

class _TroubleScreenState extends State<TroubleScreen> {
  late final AppServices _services = ServicesScope.of(context);
  _Tab _tab = _Tab.bag;

  late BagClaim _claim = BagClaim.parse(
    _services.prefs.readData(LocalData.bagClaim),
  );
  late final TextEditingController _name = TextEditingController(
    text: _services.prefs.readGroupName() ?? '',
  );
  late final Map<String, TextEditingController> _fields =
      <String, TextEditingController>{
        'airline': TextEditingController(text: _claim.airline),
        'reference': TextEditingController(text: _claim.reference),
        'tag': TextEditingController(text: _claim.tag),
        'flight': TextEditingController(text: _claim.flight),
        'trackerLink': TextEditingController(text: _claim.trackerLink),
        'spent': TextEditingController(text: _claim.spent),
      };

  // Escala perdida.
  late final EasyTrip _trip = loadEasyTrip(_services.prefs);
  late final TextEditingController _hub = TextEditingController();
  late final TextEditingController _final = TextEditingController(
    text: _trip.to ?? '',
  );
  bool _oneBooking = true;

  @override
  void dispose() {
    _name.dispose();
    _hub.dispose();
    _final.dispose();
    for (final TextEditingController c in _fields.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save(BagClaim c) async {
    setState(() => _claim = c);
    await _services.prefs.writeData(LocalData.bagClaim, jsonEncode(c.toJson()));
  }

  /// Lo escrito en los campos, junto con lo demás.
  BagClaim get _current => _claim.copyWith(
    airline: _fields['airline']!.text.trim(),
    reference: _fields['reference']!.text.trim().toUpperCase(),
    tag: _fields['tag']!.text.trim(),
    flight: _fields['flight']!.text.trim().toUpperCase(),
    trackerLink: _fields['trackerLink']!.text.trim(),
    spent: _fields['spent']!.text.trim(),
  );

  Future<DateTime?> _pickDay(DateTime? initial) {
    final DateTime now = DateTime.now();
    return showDatePicker(
      context: context,
      initialDate: initial ?? now,
      firstDate: now.subtract(const Duration(days: 365)),
      lastDate: now,
    );
  }

  Future<void> _write() async {
    final BagClaim c = _current;
    await _save(c);
    final String name = _name.text.trim();
    if (name.isNotEmpty) await _services.prefs.writeGroupName(name);
    await _services.openBooking(
      bagEmail(c, name: name.isEmpty ? '—' : name, now: DateTime.now()),
    );
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(t.troubleTitle)),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 32),
        children: <Widget>[
          SegmentedButton<_Tab>(
            segments: <ButtonSegment<_Tab>>[
              ButtonSegment<_Tab>(
                value: _Tab.bag,
                label: Text(t.troubleBagTab),
                icon: const Icon(Icons.luggage_rounded),
              ),
              ButtonSegment<_Tab>(
                value: _Tab.connection,
                label: Text(t.troubleConnTab),
                icon: const Icon(Icons.connecting_airports_rounded),
              ),
            ],
            selected: <_Tab>{_tab},
            onSelectionChanged: (Set<_Tab> s) => setState(() => _tab = s.first),
          ),
          const SizedBox(height: 16),
          ...switch (_tab) {
            _Tab.bag => _bag(t),
            _Tab.connection => _connection(t),
          },
        ],
      ),
    );
  }

  List<Widget> _bag(AppLocalizations t) {
    final TextTheme text = Theme.of(context).textTheme;
    final String locale = Localizations.localeOf(context).toLanguageTag();
    final DateFormat day = DateFormat.yMMMd(locale);
    final BagDeadline? deadline = deadlineOf(_claim);
    final int? left = deadline?.daysLeft(DateTime.now());
    final List<String> steps = <String>[
      t.troubleStepPir,
      t.troubleStepSave,
      t.troubleStepReceipts,
      t.troubleStepClaim,
    ];
    return <Widget>[
      Wrap(
        spacing: 8,
        children: <Widget>[
          ChoiceChip(
            label: Text(t.troubleBagDelayed),
            selected: _claim.problem == BagProblem.delayed,
            onSelected: (_) =>
                _save(_current.copyWith(problem: BagProblem.delayed)),
          ),
          ChoiceChip(
            label: Text(t.troubleBagDamaged),
            selected: _claim.problem == BagProblem.damaged,
            onSelected: (_) =>
                _save(_current.copyWith(problem: BagProblem.damaged)),
          ),
        ],
      ),
      const SizedBox(height: 12),
      // El plazo, bien grande: es lo que más se olvida.
      Card(
        color: left != null && left <= 3
            ? NomadColors.safety.withValues(alpha: 0.18)
            : null,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                deadline == null
                    ? t.troubleNeedDate
                    : switch (deadline.kind) {
                        DeadlineKind.damaged => t.troubleDeadlineDamaged(
                          day.format(deadline.date),
                        ),
                        DeadlineKind.delayed => t.troubleDeadlineDelayed(
                          day.format(deadline.date),
                        ),
                        DeadlineKind.lostFrom => t.troubleDeadlineLost(
                          day.format(deadline.date),
                        ),
                      },
                style: text.titleMedium,
              ),
              if (left != null) ...<Widget>[
                const SizedBox(height: 4),
                Text(
                  left < 0 ? t.troubleDaysPast : t.troubleDaysLeft(left),
                  style: text.bodyMedium?.copyWith(
                    color: NomadColors.textMuted,
                  ),
                ),
              ],
              const SizedBox(height: 8),
              Text(t.troubleLimit, style: text.bodySmall),
            ],
          ),
        ),
      ),
      const SizedBox(height: 12),
      for (int i = 0; i < steps.length; i++)
        CheckboxListTile(
          contentPadding: EdgeInsets.zero,
          controlAffinity: ListTileControlAffinity.leading,
          value: _claim.done.contains(i),
          title: Text(steps[i]),
          onChanged: (bool? on) => _save(
            _current.copyWith(
              done: on == true
                  ? <int>{..._claim.done, i}
                  : (<int>{..._claim.done}..remove(i)),
            ),
          ),
        ),
      const SizedBox(height: 8),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: <Widget>[
          ActionChip(
            avatar: const Icon(Icons.flight_land_rounded, size: 18),
            label: Text(
              _claim.arrived == null
                  ? t.troubleArrived
                  : '${t.troubleArrived}: ${day.format(_claim.arrived!)}',
            ),
            onPressed: () async {
              final DateTime? d = await _pickDay(_claim.arrived);
              if (d != null) await _save(_current.copyWith(arrived: d));
            },
          ),
          ActionChip(
            avatar: const Icon(Icons.luggage_rounded, size: 18),
            label: Text(
              _claim.delivered == null
                  ? t.troubleDelivered
                  : '${t.troubleDelivered}: ${day.format(_claim.delivered!)}',
            ),
            onPressed: () async {
              final DateTime? d = await _pickDay(_claim.delivered);
              if (d != null) await _save(_current.copyWith(delivered: d));
            },
          ),
        ],
      ),
      const SizedBox(height: 8),
      _field(_fields['airline']!, t.troubleAirline),
      _field(_fields['flight']!, t.troubleFlight),
      _field(_fields['reference']!, t.troubleReference, hint: 'MADIB12345'),
      _field(_fields['tag']!, t.troubleTag),
      _field(
        _fields['trackerLink']!,
        t.troubleTracker,
        helper: t.troubleTrackerHelp,
      ),
      _field(_fields['spent']!, t.troubleSpent, helper: t.troubleSpentHelp),
      _field(_name, t.meetupsYourName),
      const SizedBox(height: 12),
      FilledButton.icon(
        icon: const Icon(Icons.mail_rounded),
        label: Text(t.troubleWriteClaim),
        onPressed: _write,
      ),
      const SizedBox(height: 8),
      OutlinedButton.icon(
        icon: const Icon(Icons.receipt_long_rounded),
        label: Text(t.troubleLogExpenses),
        onPressed: () => unawaited(context.push(Routes.money())),
      ),
    ];
  }

  Widget _field(
    TextEditingController c,
    String label, {
    String? hint,
    String? helper,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: TextField(
      controller: c,
      maxLength: 300,
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        helperText: helper,
        helperMaxLines: 3,
        counterText: '',
      ),
      // Se guarda al salir del campo: nada se pierde si cierras la app.
      onEditingComplete: () => unawaited(_save(_current)),
      onTapOutside: (_) => unawaited(_save(_current)),
    ),
  );

  List<Widget> _connection(AppLocalizations t) {
    final TextTheme text = Theme.of(context).textTheme;
    final String today = DateFormat('yyyy-MM-dd').format(DateTime.now());
    bool ok(String s) => RegExp(r'^[A-Za-z]{3}$').hasMatch(s.trim());
    return <Widget>[
      Text(t.troubleConnIntro, style: text.bodyMedium),
      const SizedBox(height: 8),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: Text(t.troubleOneBooking),
        subtitle: Text(t.troubleOneBookingHelp),
        value: _oneBooking,
        onChanged: (bool v) => setState(() => _oneBooking = v),
      ),
      const SizedBox(height: 8),
      Card(
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                _oneBooking ? t.troubleRebookTitle : t.troubleSelfTitle,
                style: text.titleMedium,
              ),
              const SizedBox(height: 6),
              Text(_oneBooking ? t.troubleRebookBody : t.troubleSelfBody),
            ],
          ),
        ),
      ),
      const SizedBox(height: 8),
      Card(
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(t.troubleRightsTitle, style: text.titleMedium),
              const SizedBox(height: 6),
              Text(t.troubleRightsBody),
            ],
          ),
        ),
      ),
      const SizedBox(height: 12),
      Text(t.troubleSayTitle, style: text.titleSmall),
      const SizedBox(height: 4),
      SelectableText(
        _oneBooking
            ? 'I missed my connection because my first flight was late. '
                  'All flights are on one booking: please rebook me on the '
                  'next flight to my final destination and give me meal '
                  'vouchers${_final.text.trim().isEmpty ? '' : ' (final destination: ${_final.text.trim().toUpperCase()})'}.'
            : 'I missed my next flight because this one was late. '
                  'Can you tell me the next available flight and fare?',
        style: text.bodyMedium?.copyWith(fontStyle: FontStyle.italic),
      ),
      const SizedBox(height: 16),
      Row(
        children: <Widget>[
          Expanded(
            child: TextField(
              controller: _hub,
              maxLength: 3,
              textCapitalization: TextCapitalization.characters,
              decoration: InputDecoration(
                labelText: t.troubleWhereNow,
                counterText: '',
              ),
              onChanged: (_) => setState(() {}),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: TextField(
              controller: _final,
              maxLength: 3,
              textCapitalization: TextCapitalization.characters,
              decoration: InputDecoration(
                labelText: t.troubleFinal,
                counterText: '',
              ),
              onChanged: (_) => setState(() {}),
            ),
          ),
        ],
      ),
      const SizedBox(height: 8),
      FilledButton.icon(
        icon: const Icon(Icons.search_rounded),
        label: Text(t.troubleSearchNext),
        onPressed: ok(_hub.text) && ok(_final.text)
            ? () => unawaited(
                context.push(
                  Routes.fareSearch(
                    origin: _hub.text.trim().toUpperCase(),
                    destination: _final.text.trim().toUpperCase(),
                    departure: today,
                  ),
                ),
              )
            : null,
      ),
      const SizedBox(height: 8),
      OutlinedButton.icon(
        icon: const Icon(Icons.gavel_rounded),
        label: Text(t.troubleClaimDelay),
        onPressed: () => unawaited(context.push(Routes.papers)),
      ),
    ];
  }
}
