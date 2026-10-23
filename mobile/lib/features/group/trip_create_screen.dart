// "Nuevo viaje en grupo": el organizador pone un nombre, la divisa y las
// opciones entre las que se va a negociar (una ciudad, un piso, un hotel...)
// con su precio por persona y lo que ofrece cada una. Al crearlo recibe un
// código de invitación para su grupo.
//
// Los precios se escriben en números enteros (70, no 70,50): para decidir
// entre opciones sobran los céntimos y el teclado es más sencillo.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/api_client.dart';
import '../../core/money.dart';
import '../../core/services.dart';
import '../../core/theme.dart';
import '../../l10n/generated/app_localizations.dart';
import 'group_api.dart';
import 'group_widgets.dart';

/// Divisas que se ofrecen (las más usadas al viajar). El servidor admite
/// cualquier código ISO de tres letras: ampliar la lista es solo añadir aquí.
const List<String> tripCurrencies = <String>[
  'EUR',
  'USD',
  'GBP',
  'CHF',
  'JPY',
  'CNY',
  'INR',
  'AED',
  'MXN',
  'BRL',
  'CAD',
  'AUD',
];

class TripCreateScreen extends StatefulWidget {
  const TripCreateScreen({super.key});

  @override
  State<TripCreateScreen> createState() => _TripCreateScreenState();
}

/// Lo que se está escribiendo de UNA opción.
class _OptionDraft {
  final TextEditingController label = TextEditingController();
  final TextEditingController price = TextEditingController();
  final Set<String> tags = <String>{};

  void dispose() {
    label.dispose();
    price.dispose();
  }
}

class _TripCreateScreenState extends State<TripCreateScreen> {
  late final AppServices _services = ServicesScope.of(context);
  final GlobalKey<FormState> _form = GlobalKey<FormState>();
  final TextEditingController _title = TextEditingController();
  late final TextEditingController _name = TextEditingController(
    text: _services.prefs.readGroupName() ?? '',
  );
  final List<_OptionDraft> _options = <_OptionDraft>[
    _OptionDraft(),
    _OptionDraft(),
  ];
  String _currency = tripCurrencies.first;
  String? _problem;
  bool _busy = false;

  @override
  void dispose() {
    _title.dispose();
    _name.dispose();
    for (final _OptionDraft o in _options) {
      o.dispose();
    }
    super.dispose();
  }

  Future<void> _create() async {
    final AppLocalizations t = AppLocalizations.of(context);
    if (!(_form.currentState?.validate() ?? false)) return;
    final String name = _name.text.trim();
    final String language = Localizations.localeOf(context).languageCode;
    setState(() {
      _busy = true;
      _problem = null;
    });
    try {
      final GroupTrip trip = await _services.group.create(
        NewTrip(
          title: _title.text.trim(),
          currency: _currency,
          language: language,
          myName: name.isEmpty ? null : name,
          options: <TripOption>[
            for (int i = 0; i < _options.length; i++)
              TripOption(
                // Ids sencillos y estables: "op-1", "op-2"...
                id: 'op-${i + 1}',
                label: _options[i].label.text.trim(),
                priceMinor: wholeToMinor(
                  int.parse(_options[i].price.text),
                  _currency,
                ),
                tags: _options[i].tags.toList(),
              ),
          ],
        ),
      );
      if (name.isNotEmpty) await _services.prefs.writeGroupName(name);
      // Se vuelve a la lista con el id: ella abre el viaje recién creado.
      if (mounted) Navigator.of(context).pop(trip.id);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _problem = switch (e.error) {
          ApiError.network => t.errorNetwork,
          ApiError.signedOut => t.groupSignIn,
          _ => t.errorUnavailable,
        };
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    final TextTheme text = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(title: Text(t.groupCreateTitle)),
      body: SafeArea(
        child: Form(
          key: _form,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
            children: <Widget>[
              TextFormField(
                controller: _title,
                maxLength: 120,
                textCapitalization: TextCapitalization.sentences,
                decoration: InputDecoration(
                  labelText: t.groupTripName,
                  hintText: t.groupTripNameHint,
                ),
                validator: (String? v) =>
                    (v ?? '').trim().isEmpty ? t.groupRequired : null,
              ),
              const SizedBox(height: 8),
              TextFormField(
                controller: _name,
                maxLength: maxName,
                decoration: InputDecoration(
                  labelText: t.groupYourName,
                  helperText: t.groupYourNameHelp,
                  helperMaxLines: 2,
                ),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                initialValue: _currency,
                decoration: InputDecoration(labelText: t.groupCurrency),
                items: <DropdownMenuItem<String>>[
                  for (final String c in tripCurrencies)
                    DropdownMenuItem<String>(value: c, child: Text(c)),
                ],
                onChanged: (String? c) =>
                    setState(() => _currency = c ?? _currency),
              ),
              const SizedBox(height: 24),
              Text(t.groupOptionsTitle, style: text.titleLarge),
              const SizedBox(height: 4),
              Text(
                t.groupOptionsHelp,
                style: const TextStyle(color: NomadColors.textMuted),
              ),
              const SizedBox(height: 12),
              for (int i = 0; i < _options.length; i++) ...<Widget>[
                _OptionCard(
                  // La clave mantiene cada tarjeta con SU texto al quitar otra.
                  key: ObjectKey(_options[i]),
                  index: i,
                  draft: _options[i],
                  currency: _currency,
                  onRemove: _options.length > minOptions
                      ? () => setState(() => _options.removeAt(i).dispose())
                      : null,
                  onTags: () => setState(() {}),
                ),
                const SizedBox(height: 12),
              ],
              if (_options.length < maxOptions)
                OutlinedButton.icon(
                  onPressed: () => setState(() => _options.add(_OptionDraft())),
                  icon: const Icon(Icons.add_rounded),
                  label: Text(t.groupOptionAdd),
                ),
              const SizedBox(height: 24),
              if (_problem != null) ...<Widget>[
                Text(
                  _problem!,
                  style: const TextStyle(color: NomadColors.safety),
                ),
                const SizedBox(height: 8),
              ],
              FilledButton(
                onPressed: _busy ? null : _create,
                child: _busy
                    ? const SizedBox.square(
                        dimension: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Text(t.groupCreateAction),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _OptionCard extends StatelessWidget {
  const _OptionCard({
    super.key,
    required this.index,
    required this.draft,
    required this.currency,
    required this.onRemove,
    required this.onTags,
  });

  final int index;
  final _OptionDraft draft;
  final String currency;
  final VoidCallback? onRemove;
  final VoidCallback onTags;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 8, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    t.groupOptionN(index + 1),
                    style: const TextStyle(
                      color: NomadColors.group,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                if (onRemove != null)
                  IconButton(
                    tooltip: t.groupOptionRemove,
                    onPressed: onRemove,
                    icon: const Icon(Icons.close_rounded),
                  ),
              ],
            ),
            Padding(
              padding: const EdgeInsetsDirectional.only(end: 8),
              child: Column(
                children: <Widget>[
                  TextFormField(
                    controller: draft.label,
                    maxLength: 120,
                    textCapitalization: TextCapitalization.sentences,
                    decoration: InputDecoration(
                      labelText: t.groupOptionName,
                      hintText: t.groupOptionNameHint,
                      counterText: '',
                    ),
                    validator: (String? v) =>
                        (v ?? '').trim().isEmpty ? t.groupRequired : null,
                  ),
                  const SizedBox(height: 10),
                  TextFormField(
                    controller: draft.price,
                    keyboardType: TextInputType.number,
                    // Solo cifras: ni comas, ni puntos, ni signos.
                    inputFormatters: <TextInputFormatter>[
                      FilteringTextInputFormatter.digitsOnly,
                      LengthLimitingTextInputFormatter(7),
                    ],
                    decoration: InputDecoration(
                      labelText: t.groupOptionPrice,
                      suffixText: currency,
                    ),
                    validator: (String? v) => (int.tryParse(v ?? '') ?? 0) <= 0
                        ? t.groupPriceInvalid
                        : null,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Text(
              t.groupOptionTags,
              style: const TextStyle(color: NomadColors.textMuted),
            ),
            const SizedBox(height: 6),
            TagPicker(
              selected: draft.tags,
              onChanged: onTags,
              exclude: const <String>{'early-starts', 'crowds'},
            ),
          ],
        ),
      ),
    );
  }
}

/// Fichas para marcar gustos (máximo [maxTags], el límite del servidor).
/// Cambia [selected] directamente y avisa con [onChanged].
class TagPicker extends StatelessWidget {
  const TagPicker({
    super.key,
    required this.selected,
    required this.onChanged,
    this.exclude = const <String>{},
    this.blocked = const <String>{},
  });

  final Set<String> selected;
  final VoidCallback onChanged;

  /// Gustos que no tienen sentido aquí (una opción no "ofrece" madrugar).
  final Set<String> exclude;

  /// Gustos que ya están en la otra lista (no se puede querer y evitar algo).
  final Set<String> blocked;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    final bool full = selected.length >= maxTags;
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: <Widget>[
        for (final String tag in tripTags)
          if (!exclude.contains(tag))
            FilterChip(
              label: Text(tagLabel(t, tag)),
              selected: selected.contains(tag),
              selectedColor: NomadColors.group.withValues(alpha: 0.3),
              onSelected:
                  blocked.contains(tag) || (full && !selected.contains(tag))
                  ? null
                  : (bool on) {
                      on ? selected.add(tag) : selected.remove(tag);
                      onChanged();
                    },
            ),
      ],
    );
  }
}
