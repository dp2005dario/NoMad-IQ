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
import '../../widgets/flyra_avatar.dart';
import '../reels/reels.dart';
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

  /// Reglas del grupo: máximo por persona y lo que nadie quiere.
  final TextEditingController _maxPrice = TextEditingController();
  final Set<String> _ruleAvoid = <String>{};

  int? get _maxPriceValue {
    final int? v = int.tryParse(_maxPrice.text);
    return v != null && v > 0 ? v : null;
  }

  String? _problem;
  bool _busy = false;

  @override
  void dispose() {
    _title.dispose();
    _name.dispose();
    _maxPrice.dispose();
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
          rules: TripRules(
            maxPriceMinor: _maxPriceValue == null
                ? null
                : wholeToMinor(_maxPriceValue!, _currency),
            avoid: _ruleAvoid.toList(),
          ),
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

  /// En qué paso vas (para la barra de arriba): 0 el viaje, 1 las
  /// opciones, 2 todo listo para crear.
  int get _step {
    if (_title.text.trim().isEmpty) return 0;
    final bool optionsDone = _options.every(
      (_OptionDraft o) =>
          o.label.text.trim().isNotEmpty &&
          (int.tryParse(o.price.text) ?? 0) > 0,
    );
    return optionsDone ? 2 : 1;
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    return Scaffold(
      backgroundColor: NomadColors.background,
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        title: Text(
          t.groupCreateTitle,
          style: const TextStyle(
            fontFamily: NomadFonts.display,
            fontWeight: FontWeight.w800,
          ),
        ),
      ),
      // Fondo violeta de "Viajes en grupo" que se funde con el negro.
      body: DecoratedBox(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            stops: <double>[0, 0.55],
            colors: <Color>[Color(0xFF1D1638), NomadColors.background],
          ),
        ),
        child: SafeArea(
          child: Form(
            key: _form,
            // Cada letra puede cambiar el paso y la vista previa.
            onChanged: () => setState(() {}),
            child: Column(
              children: <Widget>[
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
                    children: <Widget>[
                      _Appear(
                        order: 0,
                        child: _Hero(
                          title: t.groupCreateHeadline,
                          text: t.groupIntro,
                        ),
                      ),
                      const SizedBox(height: 16),
                      _Appear(
                        order: 1,
                        child: _Steps(
                          step: _step,
                          labels: <String>[
                            t.groupStepTrip,
                            t.groupStepOptions,
                            t.groupStepVote,
                          ],
                        ),
                      ),
                      const SizedBox(height: 16),
                      _Appear(
                        order: 2,
                        child: _Templates(
                          title: t.groupQuickIdeas,
                          onPick: _useTemplate,
                        ),
                      ),
                      const SizedBox(height: 16),
                      _Appear(
                        order: 2,
                        child: _Section(
                          icon: Icons.luggage_rounded,
                          color: _lilac,
                          title: t.groupStepTrip,
                          children: <Widget>[
                            TextFormField(
                              controller: _title,
                              maxLength: 120,
                              textCapitalization: TextCapitalization.sentences,
                              decoration: InputDecoration(
                                labelText: t.groupTripName,
                                hintText: t.groupTripNameHint,
                                prefixIcon: const Icon(Icons.flag_rounded),
                              ),
                              validator: (String? v) => (v ?? '').trim().isEmpty
                                  ? t.groupRequired
                                  : null,
                            ),
                            const SizedBox(height: 4),
                            TextFormField(
                              controller: _name,
                              maxLength: maxName,
                              decoration: InputDecoration(
                                labelText: t.groupYourName,
                                helperText: t.groupYourNameHelp,
                                helperMaxLines: 2,
                                prefixIcon: const Icon(Icons.person_rounded),
                              ),
                            ),
                            const SizedBox(height: 14),
                            Text(
                              t.groupCurrency,
                              style: const TextStyle(
                                color: NomadColors.textMuted,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(height: 8),
                            _CurrencyRow(
                              selected: _currency,
                              onPick: (String c) =>
                                  setState(() => _currency = c),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 14),
                      _Appear(
                        order: 3,
                        child: _Section(
                          icon: Icons.gavel_rounded,
                          color: const Color(0xFFFFB86B),
                          title: t.groupRulesTitle,
                          subtitle: t.groupRulesHelp,
                          children: <Widget>[
                            TextFormField(
                              controller: _maxPrice,
                              keyboardType: TextInputType.number,
                              inputFormatters: <TextInputFormatter>[
                                FilteringTextInputFormatter.digitsOnly,
                                LengthLimitingTextInputFormatter(7),
                              ],
                              decoration: InputDecoration(
                                labelText: t.groupRulesMax,
                                suffixText: _currency,
                                prefixIcon: const Icon(Icons.savings_rounded),
                              ),
                            ),
                            const SizedBox(height: 12),
                            Text(
                              t.groupRulesAvoid,
                              style: const TextStyle(
                                color: NomadColors.textMuted,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(height: 6),
                            TagPicker(
                              selected: _ruleAvoid,
                              onChanged: () => setState(() {}),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 14),
                      _Appear(
                        order: 3,
                        child: _Section(
                          icon: Icons.how_to_vote_rounded,
                          color: NomadColors.group,
                          title: t.groupOptionsTitle,
                          subtitle: t.groupOptionsHelp,
                          children: <Widget>[
                            for (int i = 0; i < _options.length; i++)
                              _Appear(
                                // La clave mantiene cada tarjeta con SU texto al
                                // quitar otra.
                                key: ObjectKey(_options[i]),
                                order: 0,
                                child: Padding(
                                  padding: const EdgeInsets.only(bottom: 12),
                                  child: _OptionCard(
                                    index: i,
                                    draft: _options[i],
                                    currency: _currency,
                                    onRemove: _options.length > minOptions
                                        ? () => setState(
                                            () =>
                                                _options.removeAt(i).dispose(),
                                          )
                                        : null,
                                    onTags: () => setState(() {}),
                                    maxPrice: _maxPriceValue,
                                  ),
                                ),
                              ),
                            if (_options.length < maxOptions)
                              OutlinedButton.icon(
                                style: OutlinedButton.styleFrom(
                                  foregroundColor: _lilac,
                                  backgroundColor: const Color(0x148A5CF6),
                                  side: BorderSide(
                                    color: _lilac.withValues(alpha: 0.5),
                                  ),
                                  minimumSize: const Size.fromHeight(48),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(16),
                                  ),
                                ),
                                onPressed: () => setState(
                                  () => _options.add(_OptionDraft()),
                                ),
                                icon: const Icon(Icons.add_rounded),
                                label: Text(t.groupOptionAdd),
                              ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 14),
                      _Appear(order: 4, child: const _PlansBox()),
                      const SizedBox(height: 14),
                      _Appear(
                        order: 4,
                        child: _Preview(
                          title: t.groupPreviewTitle,
                          empty: t.groupPreviewEmpty,
                          trip: _title.text.trim(),
                          currency: _currency,
                          options: <(String, int)>[
                            for (final _OptionDraft o in _options)
                              if (o.label.text.trim().isNotEmpty)
                                (
                                  o.label.text.trim(),
                                  int.tryParse(o.price.text) ?? 0,
                                ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                // El botón, siempre a mano abajo.
                Container(
                  padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
                  decoration: const BoxDecoration(
                    color: Color(0xFF110E1C),
                    border: Border(top: BorderSide(color: Color(0xFF2A2245))),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      if (_problem != null) ...<Widget>[
                        Text(
                          _problem!,
                          style: const TextStyle(color: NomadColors.safety),
                        ),
                        const SizedBox(height: 8),
                      ],
                      SizedBox(
                        width: double.infinity,
                        height: 54,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(18),
                            gradient: const LinearGradient(
                              colors: <Color>[
                                Color(0xFF8A5CF6),
                                Color(0xFFB69CFF),
                              ],
                            ),
                            boxShadow: const <BoxShadow>[
                              BoxShadow(
                                color: Color(0x558A5CF6),
                                blurRadius: 18,
                                offset: Offset(0, 6),
                              ),
                            ],
                          ),
                          child: TextButton(
                            style: TextButton.styleFrom(
                              foregroundColor: const Color(0xFF120C24),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(18),
                              ),
                            ),
                            onPressed: _busy ? null : _create,
                            child: _busy
                                ? const SizedBox.square(
                                    dimension: 22,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2.4,
                                      color: Color(0xFF120C24),
                                    ),
                                  )
                                : Text(
                                    t.groupCreateAction,
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w800,
                                      fontSize: 16,
                                    ),
                                  ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Una idea rápida: pone el nombre (si no hay) y los gustos de cada
  /// opción, para no empezar con la hoja en blanco.
  void _useTemplate(_Template tpl, String name) {
    setState(() {
      if (_title.text.trim().isEmpty) _title.text = name;
      for (final _OptionDraft o in _options) {
        o.tags
          ..clear()
          ..addAll(tpl.tags);
      }
    });
  }
}

/// "¿No se te ocurren planes?": escribes una ciudad o país y te enseña
/// vídeos cortos de cosas que hacer allí.
class _PlansBox extends StatefulWidget {
  const _PlansBox();

  @override
  State<_PlansBox> createState() => _PlansBoxState();
}

class _PlansBoxState extends State<_PlansBox> {
  final TextEditingController _place = TextEditingController();

  /// El sitio buscado ("" = ideas generales).
  String _searched = '';

  @override
  void dispose() {
    _place.dispose();
    super.dispose();
  }

  void _go() {
    FocusScope.of(context).unfocus();
    setState(() => _searched = _place.text.trim());
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: const Color(0xFF5A2E5E)),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: <Color>[Color(0xFF3B1A3F), Color(0xFF16142A)],
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              const Text('🎬', style: TextStyle(fontSize: 22)),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  t.groupPlansTitle,
                  style: const TextStyle(
                    fontFamily: NomadFonts.display,
                    fontWeight: FontWeight.w800,
                    fontSize: 18,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _place,
            textInputAction: TextInputAction.search,
            textCapitalization: TextCapitalization.words,
            onSubmitted: (_) => _go(),
            decoration: InputDecoration(
              filled: true,
              fillColor: const Color(0xFF120E1E),
              prefixIcon: Padding(
                padding: const EdgeInsetsDirectional.only(start: 14, end: 6),
                child: Center(
                  widthFactor: 1,
                  child: Text(
                    t.groupPlansFor,
                    style: const TextStyle(
                      color: Color(0xFFFF8FD8),
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ),
              hintText: t.groupPlansHint,
              suffixIcon: IconButton(
                tooltip: t.groupPlansFor,
                onPressed: _go,
                icon: const Icon(Icons.search_rounded),
              ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(16),
                borderSide: BorderSide.none,
              ),
            ),
          ),
          const SizedBox(height: 14),
          PlanReels(place: _searched),
        ],
      ),
    );
  }
}

/// El violeta claro de los viajes en grupo.
const Color _lilac = Color(0xFFB69CFF);

/// Ideas rápidas para empezar: emoji, gustos que pone a las opciones y su
/// nombre (traducido).
class _Template {
  const _Template(this.emoji, this.tags, this.name);

  final String emoji;
  final List<String> tags;
  final String Function(AppLocalizations t) name;
}

final List<_Template> _templates = <_Template>[
  _Template('🏙️', const <String>[
    'food',
    'nightlife',
    'history',
  ], (AppLocalizations t) => t.groupTplWeekend),
  _Template('🎉', const <String>[
    'nightlife',
    'food',
    'adventure',
  ], (AppLocalizations t) => t.groupTplParty),
  _Template('🏖️', const <String>[
    'beach',
    'relax',
    'food',
  ], (AppLocalizations t) => t.groupTplBeach),
  _Template('🏛️', const <String>[
    'museums',
    'history',
    'shopping',
  ], (AppLocalizations t) => t.groupTplCulture),
  _Template('🧗', const <String>[
    'adventure',
    'nature',
    'mountains',
    'sport',
  ], (AppLocalizations t) => t.groupTplAdventure),
  _Template('🍝', const <String>[
    'food',
    'shopping',
    'history',
  ], (AppLocalizations t) => t.groupTplFood),
];

/// Fila de tarjetitas de ideas rápidas que se deslizan.
class _Templates extends StatelessWidget {
  const _Templates({required this.title, required this.onPick});

  final String title;
  final void Function(_Template tpl, String name) onPick;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            const Icon(Icons.auto_awesome_rounded, size: 16, color: _lilac),
            const SizedBox(width: 6),
            Text(
              title.toUpperCase(),
              style: const TextStyle(
                fontSize: 11.5,
                letterSpacing: 0.7,
                fontWeight: FontWeight.w800,
                color: _lilac,
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        SizedBox(
          height: 92,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: _templates.length,
            separatorBuilder: (_, _) => const SizedBox(width: 10),
            itemBuilder: (BuildContext context, int i) {
              final _Template tpl = _templates[i];
              final String name = tpl.name(t);
              return Material(
                color: Colors.transparent,
                child: InkWell(
                  borderRadius: BorderRadius.circular(20),
                  onTap: () => onPick(tpl, name),
                  child: Ink(
                    width: 112,
                    padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(20),
                      gradient: LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: <Color>[
                          _tones[i % _tones.length],
                          const Color(0xFF15182A),
                        ],
                      ),
                      border: Border.all(color: const Color(0xFF3E3163)),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: <Widget>[
                        Text(tpl.emoji, style: const TextStyle(fontSize: 26)),
                        Text(
                          name,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontWeight: FontWeight.w800,
                            fontSize: 12.5,
                            height: 1.15,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  static const List<Color> _tones = <Color>[
    Color(0xFF3A2470),
    Color(0xFF4A1F4F),
    Color(0xFF123A4F),
    Color(0xFF3A2E14),
    Color(0xFF173F2E),
    Color(0xFF4A2A1A),
  ];
}

/// Entra deslizándose un poco hacia arriba (cada bloque un pelín después).
class _Appear extends StatelessWidget {
  const _Appear({super.key, required this.order, required this.child});

  final int order;
  final Widget child;

  @override
  Widget build(BuildContext context) => TweenAnimationBuilder<double>(
    tween: Tween<double>(begin: 0, end: 1),
    duration: MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : Duration(milliseconds: 420 + order * 110),
    curve: Curves.easeOutCubic,
    builder: (BuildContext context, double v, Widget? child) => Opacity(
      opacity: v,
      child: Transform.translate(offset: Offset(0, 18 * (1 - v)), child: child),
    ),
    child: child,
  );
}

/// La cabecera: Flyra con su halo, el título grande y cómo va esto, sobre
/// un degradado violeta con "estrellitas".
class _Hero extends StatelessWidget {
  const _Hero({required this.title, required this.text});

  final String title;
  final String text;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.fromLTRB(18, 18, 18, 20),
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(28),
      border: Border.all(color: const Color(0xFF5A46A0)),
      gradient: const LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: <Color>[
          Color(0xFF3A2470),
          Color(0xFF1A1E4A),
          Color(0xFF0F2A44),
        ],
      ),
      boxShadow: const <BoxShadow>[
        BoxShadow(
          color: Color(0x338A5CF6),
          blurRadius: 30,
          offset: Offset(0, 10),
        ),
      ],
    ),
    child: Stack(
      clipBehavior: Clip.none,
      children: <Widget>[
        // Puntitos de luz de adorno.
        for (final (double, double, double) d
            in const <(double, double, double)>[
              (0.92, 0.05, 3),
              (0.78, 0.30, 2),
              (0.97, 0.55, 2.5),
              (0.70, 0.08, 1.6),
            ])
          Positioned.fill(
            child: Align(
              alignment: Alignment(d.$1 * 2 - 1, d.$2 * 2 - 1),
              child: Container(
                width: d.$3 * 2,
                height: d.$3 * 2,
                decoration: const BoxDecoration(
                  color: Color(0xCCE6DEFF),
                  shape: BoxShape.circle,
                ),
              ),
            ),
          ),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Container(
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(color: _lilac, width: 2),
                    boxShadow: const <BoxShadow>[
                      BoxShadow(color: Color(0x668A5CF6), blurRadius: 20),
                    ],
                  ),
                  child: const FlyraAvatar(size: 50),
                ),
                const SizedBox(width: 10),
                const Text('✈️', style: TextStyle(fontSize: 22)),
                const SizedBox(width: 4),
                const Text('👥', style: TextStyle(fontSize: 22)),
              ],
            ),
            const SizedBox(height: 14),
            Text(
              title,
              style: const TextStyle(
                fontFamily: NomadFonts.display,
                fontWeight: FontWeight.w800,
                fontSize: 24,
                height: 1.15,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              text,
              style: const TextStyle(
                color: Color(0xFFE6DEFF),
                height: 1.45,
                fontSize: 14,
              ),
            ),
          ],
        ),
      ],
    ),
  );
}

/// Los tres pasos, con el que toca encendido.
class _Steps extends StatelessWidget {
  const _Steps({required this.step, required this.labels});

  final int step;
  final List<String> labels;

  @override
  // Los tres pasos igual de altos aunque un nombre ocupe 2 líneas.
  Widget build(BuildContext context) => IntrinsicHeight(
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        for (int i = 0; i < labels.length; i++) ...<Widget>[
          if (i > 0)
            Center(
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 300),
                width: 14,
                height: 2,
                color: i <= step ? _lilac : const Color(0xFF332A55),
              ),
            ),
          Expanded(
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 300),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 9),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(14),
                color: i < step
                    ? const Color(0x338A5CF6)
                    : i == step
                    ? const Color(0x1F8A5CF6)
                    : const Color(0xFF15182A),
                border: Border.all(
                  color: i < step
                      ? _lilac
                      : i == step
                      ? const Color(0xFF8A5CF6)
                      : const Color(0xFF332A55),
                ),
              ),
              // Arriba el círculo, debajo el nombre en hasta 2 líneas: así
              // se lee entero aunque el móvil sea estrecho.
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: <Widget>[
                  Icon(
                    i < step
                        ? Icons.check_circle_rounded
                        : Icons.circle_outlined,
                    size: 16,
                    color: i < step
                        ? _lilac
                        : i == step
                        ? const Color(0xFF8A5CF6)
                        : NomadColors.textMuted,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    labels[i],
                    maxLines: 2,
                    textAlign: TextAlign.center,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11.5,
                      height: 1.15,
                      fontWeight: FontWeight.w800,
                      color: i <= step
                          ? NomadColors.text
                          : NomadColors.textMuted,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ],
    ),
  );
}

/// Un bloque con su icono de color y su título.
class _Section extends StatelessWidget {
  const _Section({
    required this.icon,
    required this.color,
    required this.title,
    required this.children,
    this.subtitle,
  });

  final IconData icon;
  final Color color;
  final String title;
  final String? subtitle;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(24),
      border: Border.all(color: const Color(0xFF332A55)),
      gradient: const LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: <Color>[Color(0xFF1F1A36), Color(0xFF15182A)],
      ),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Row(
          children: <Widget>[
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(icon, color: color, size: 20),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                title,
                style: const TextStyle(
                  fontFamily: NomadFonts.display,
                  fontWeight: FontWeight.w800,
                  fontSize: 18,
                ),
              ),
            ),
          ],
        ),
        if (subtitle != null) ...<Widget>[
          const SizedBox(height: 6),
          Text(
            subtitle!,
            style: const TextStyle(color: NomadColors.textMuted, height: 1.4),
          ),
        ],
        const SizedBox(height: 14),
        ...children,
      ],
    ),
  );
}

/// Las divisas como fichas que se deslizan (en vez de una lista cerrada).
class _CurrencyRow extends StatelessWidget {
  const _CurrencyRow({required this.selected, required this.onPick});

  final String selected;
  final ValueChanged<String> onPick;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 40,
    child: ListView.separated(
      scrollDirection: Axis.horizontal,
      itemCount: tripCurrencies.length,
      separatorBuilder: (_, _) => const SizedBox(width: 8),
      itemBuilder: (BuildContext context, int i) {
        final String c = tripCurrencies[i];
        final bool on = c == selected;
        return ChoiceChip(
          label: Text(
            c,
            style: TextStyle(
              fontWeight: FontWeight.w800,
              color: on ? const Color(0xFF120C24) : NomadColors.text,
            ),
          ),
          selected: on,
          showCheckmark: false,
          selectedColor: _lilac,
          backgroundColor: const Color(0xFF221C3A),
          side: BorderSide(color: on ? _lilac : const Color(0xFF3E3163)),
          onSelected: (_) => onPick(c),
        );
      },
    ),
  );
}

/// Lo que verá tu grupo: el nombre y cada opción con una barra según su
/// precio (la más barata, en menta).
class _Preview extends StatelessWidget {
  const _Preview({
    required this.title,
    required this.empty,
    required this.trip,
    required this.currency,
    required this.options,
  });

  final String title;
  final String empty;
  final String trip;
  final String currency;
  final List<(String, int)> options;

  @override
  Widget build(BuildContext context) {
    final int top = options.fold<int>(
      0,
      (int m, (String, int) o) => o.$2 > m ? o.$2 : m,
    );
    final List<int> priced = <int>[
      for (final (String, int) o in options)
        if (o.$2 > 0) o.$2,
    ];
    final int cheapest = priced.isEmpty
        ? 0
        : priced.reduce((int a, int b) => a < b ? a : b);
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: NomadColors.outline),
        gradient: const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: <Color>[Color(0xFF221A3E), Color(0xFF12101E)],
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              const Icon(
                Icons.visibility_rounded,
                size: 16,
                color: NomadColors.textMuted,
              ),
              const SizedBox(width: 6),
              Text(
                title.toUpperCase(),
                style: const TextStyle(
                  fontSize: 11,
                  letterSpacing: 0.6,
                  fontWeight: FontWeight.w800,
                  color: NomadColors.textMuted,
                ),
              ),
            ],
          ),
          if (trip.isNotEmpty) ...<Widget>[
            const SizedBox(height: 8),
            Text(
              trip,
              style: const TextStyle(
                fontFamily: NomadFonts.display,
                fontWeight: FontWeight.w800,
                fontSize: 20,
              ),
            ),
          ],
          const SizedBox(height: 10),
          if (options.isEmpty)
            Text(empty, style: const TextStyle(color: NomadColors.textMuted))
          else
            for (int i = 0; i < options.length; i++)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Row(
                      children: <Widget>[
                        _Letter(index: i, size: 22),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            options[i].$1,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontWeight: FontWeight.w700),
                          ),
                        ),
                        if (options[i].$2 > 0)
                          Text(
                            '${options[i].$2} $currency',
                            style: TextStyle(
                              fontWeight: FontWeight.w800,
                              color: options[i].$2 == cheapest
                                  ? NomadColors.mint
                                  : NomadColors.text,
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: TweenAnimationBuilder<double>(
                        tween: Tween<double>(
                          end: top == 0 ? 0 : options[i].$2 / top,
                        ),
                        duration: const Duration(milliseconds: 450),
                        curve: Curves.easeOutCubic,
                        builder: (BuildContext context, double v, Widget? _) =>
                            LinearProgressIndicator(
                              value: v,
                              minHeight: 6,
                              backgroundColor: NomadColors.surfaceHigh,
                              color: options[i].$2 == cheapest
                                  ? NomadColors.mint
                                  : NomadColors.group,
                            ),
                      ),
                    ),
                  ],
                ),
              ),
        ],
      ),
    );
  }
}

/// La letra de cada opción (A, B, C...) en un circulito de color.
class _Letter extends StatelessWidget {
  const _Letter({required this.index, this.size = 30});

  final int index;
  final double size;

  static const List<Color> _colors = <Color>[
    NomadColors.group,
    NomadColors.flights,
    NomadColors.money,
    NomadColors.mint,
    NomadColors.safety,
  ];

  @override
  Widget build(BuildContext context) {
    final Color c = _colors[index % _colors.length];
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.18),
        shape: BoxShape.circle,
        border: Border.all(color: c),
      ),
      child: Text(
        String.fromCharCode(0x41 + index),
        style: TextStyle(
          color: c,
          fontWeight: FontWeight.w800,
          fontSize: size * 0.45,
        ),
      ),
    );
  }
}

class _OptionCard extends StatelessWidget {
  const _OptionCard({
    required this.index,
    required this.draft,
    required this.currency,
    required this.onRemove,
    required this.onTags,
    this.maxPrice,
  });

  final int index;
  final _OptionDraft draft;
  final String currency;

  /// El máximo por persona de las reglas del grupo (o null).
  final int? maxPrice;
  final VoidCallback? onRemove;
  final VoidCallback onTags;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    final Color c = _Letter._colors[index % _Letter._colors.length];
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: c.withValues(alpha: 0.45)),
        gradient: LinearGradient(
          begin: Alignment.centerLeft,
          end: Alignment.centerRight,
          stops: const <double>[0, 0.02, 0.02, 1],
          colors: <Color>[
            c,
            c,
            const Color(0xFF221C3A),
            const Color(0xFF1A1830),
          ],
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 8, 8, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                _Letter(index: index),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    t.groupOptionN(index + 1),
                    style: TextStyle(color: c, fontWeight: FontWeight.w800),
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
                      // Más oscuro que la tarjeta para que se vea el hueco.
                      filled: true,
                      fillColor: NomadColors.background,
                      prefixIcon: const Icon(Icons.place_rounded),
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
                      filled: true,
                      fillColor: NomadColors.background,
                      prefixIcon: const Icon(Icons.payments_rounded),
                    ),
                    validator: (String? v) {
                      final int price = int.tryParse(v ?? '') ?? 0;
                      if (price <= 0) return t.groupPriceInvalid;
                      final int? max = maxPrice;
                      return max != null && price > max
                          ? t.groupPriceOverMax
                          : null;
                    },
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
