// Un viaje en grupo por dentro (maqueta "Grupo"). Según cómo vaya:
//
//   1. Esperando: el código para invitar, quién está ya listo, las opciones y
//      TUS preferencias (presupuesto, gustos, cosas a evitar y una nota).
//      Solo tu agente las ve; el servidor las borra al terminar.
//   2. Negociando: los agentes de cada uno discuten (unos minutos). La
//      pantalla pregunta cada pocos segundos cómo va.
//   3. Resultado: la opción elegida, por qué, y lo que dijo cada agente.
//
// La explicación del resultado se escribe AQUÍ con los textos traducidos (no
// se usa la frase del servidor), así se lee en el idioma de cada persona.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart' show DateFormat;

import '../../core/api_client.dart';
import '../../core/money.dart';
import '../../core/services.dart';
import '../../core/theme.dart';
import '../../l10n/generated/app_localizations.dart';
import '../../widgets/flyra_avatar.dart';
import 'group_api.dart';
import 'group_widgets.dart';
import 'trip_create_screen.dart' show TagPicker;

/// Cada cuánto se pregunta cómo va: rápido mientras negocian (tardan
/// minutos) y despacio mientras se espera a la gente (tardan horas).
const Duration pollWorking = Duration(seconds: 4);
const Duration pollCollecting = Duration(seconds: 20);

/// Tras este tiempo con la pantalla abierta se deja de preguntar solo (se
/// puede seguir tirando hacia abajo). Así un móvil olvidado encima de la mesa
/// no gasta batería ni llamadas al servidor.
const Duration pollGiveUp = Duration(minutes: 30);

class TripScreen extends StatefulWidget {
  const TripScreen({super.key, required this.tripId});

  final String tripId;

  @override
  State<TripScreen> createState() => _TripScreenState();
}

class _TripScreenState extends State<TripScreen> {
  late final AppServices _services = ServicesScope.of(context);
  final DateTime _openedAt = DateTime.now();
  GroupTrip? _trip;
  ApiError? _error;
  Timer? _poll;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_trip == null && _error == null) unawaited(_load());
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    _poll?.cancel();
    try {
      _show(await _services.group.get(widget.tripId));
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _error = e.error);
      // Un corte de red no es el final: se vuelve a probar al rato.
      if (e.error == ApiError.network) _schedule(pollCollecting);
    }
  }

  /// Enseña [trip] y programa la siguiente pregunta si aún no ha terminado.
  void _show(GroupTrip trip) {
    if (!mounted) return;
    setState(() {
      _trip = trip;
      _error = null;
    });
    if (!trip.status.finished) {
      _schedule(trip.status.working ? pollWorking : pollCollecting);
    }
  }

  void _schedule(Duration after) {
    _poll?.cancel();
    if (DateTime.now().difference(_openedAt) > pollGiveUp) return;
    _poll = Timer(after, () => unawaited(_load()));
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    final GroupTrip? trip = _trip;
    final ApiError? error = _error;
    return Scaffold(
      appBar: AppBar(title: Text(trip?.title ?? t.groupTitle)),
      body: SafeArea(
        child: trip == null
            ? Center(
                child: error == null
                    ? const CircularProgressIndicator()
                    : Padding(
                        padding: const EdgeInsets.all(32),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: <Widget>[
                            Text(switch (error) {
                              ApiError.network => t.errorNetwork,
                              ApiError.signedOut => t.groupSignIn,
                              ApiError.notFound => t.groupNotFound,
                              _ => t.errorUnavailable,
                            }, textAlign: TextAlign.center),
                            const SizedBox(height: 12),
                            TextButton(
                              onPressed: () => unawaited(_load()),
                              child: Text(t.guideRetry),
                            ),
                          ],
                        ),
                      ),
              )
            : RefreshIndicator(
                onRefresh: _load,
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
                  children: <Widget>[
                    _Header(trip: trip),
                    const SizedBox(height: 16),
                    ..._body(t, trip),
                  ],
                ),
              ),
      ),
    );
  }

  List<Widget> _body(
    AppLocalizations t,
    GroupTrip trip,
  ) => switch (trip.status) {
    TripStatus.collecting => <Widget>[
      if (trip.inviteCode != null) ...<Widget>[
        _InviteCard(code: trip.inviteCode!),
        const SizedBox(height: 16),
      ],
      _Options(trip: trip),
      const SizedBox(height: 20),
      _PreferencesForm(trip: trip, onSaved: _show),
      const SizedBox(height: 20),
      _StartBox(trip: trip, onStarted: _show),
    ],
    TripStatus.queued || TripStatus.running => <Widget>[
      const _Working(),
      const SizedBox(height: 20),
      _Options(trip: trip),
    ],
    TripStatus.concluded => <Widget>[
      if (trip.result != null) _ResultCard(trip: trip, result: trip.result!),
      const SizedBox(height: 20),
      if (trip.result != null) _AgentsSaid(trip: trip, result: trip.result!),
      const SizedBox(height: 20),
      _Options(trip: trip),
    ],
    TripStatus.expired => <Widget>[
      Text(
        t.groupExpiredText,
        style: const TextStyle(color: NomadColors.textMuted),
      ),
    ],
  };
}

/// Quiénes son, quién está listo y hasta cuándo hay plazo.
class _Header extends StatelessWidget {
  const _Header({required this.trip});

  final GroupTrip trip;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    final String locale = Localizations.localeOf(context).toLanguageTag();
    final String deadline = DateFormat.MMMd(locale)
        .add_Hm()
        .format(trip.deadline);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            MemberFaces(members: trip.members),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                t.groupMembersReady(trip.ready, trip.members.length),
                style: const TextStyle(color: NomadColors.textMuted),
              ),
            ),
            TripStatusChip(trip: trip),
          ],
        ),
        const SizedBox(height: 10),
        // Los nombres, para quien no adivine las iniciales.
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: <Widget>[
            for (final TripMember m in trip.members)
              Chip(
                avatar: Icon(
                  m.submitted
                      ? Icons.check_circle_rounded
                      : Icons.hourglass_empty_rounded,
                  size: 16,
                  color: m.submitted ? NomadColors.mint : NomadColors.textMuted,
                ),
                label: Text(memberName(t, m)),
                backgroundColor: const Color(0xFF221A38),
                side: const BorderSide(color: Color(0xFF3E3163)),
              ),
          ],
        ),
        if (trip.status == TripStatus.collecting) ...<Widget>[
          const SizedBox(height: 8),
          Text(
            t.groupDeadline(deadline),
            style: const TextStyle(color: NomadColors.textMuted, fontSize: 13),
          ),
        ],
      ],
    );
  }
}

class _InviteCard extends StatelessWidget {
  const _InviteCard({required this.code});

  final String code;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              t.groupInviteTitle,
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 4),
            Text(
              t.groupInviteText,
              style: const TextStyle(color: NomadColors.textMuted),
            ),
            const SizedBox(height: 12),
            Row(
              children: <Widget>[
                Expanded(
                  // El código se lee siempre de izquierda a derecha (también
                  // con la app en árabe): son letras y números latinos.
                  child: Directionality(
                    textDirection: TextDirection.ltr,
                    child: SelectableText(
                      formatInviteCode(code),
                      style: const TextStyle(
                        fontFamily: NomadFonts.display,
                        fontSize: 30,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 2,
                        color: NomadColors.group,
                      ),
                    ),
                  ),
                ),
                IconButton.filledTonal(
                  tooltip: t.groupInviteCopy,
                  onPressed: () async {
                    await Clipboard.setData(
                      ClipboardData(text: formatInviteCode(code)),
                    );
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text(t.groupInviteCopied)),
                      );
                    }
                  },
                  icon: const Icon(Icons.copy_rounded),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Las opciones del viaje con su precio y lo que ofrecen. La elegida, marcada.
class _Options extends StatelessWidget {
  const _Options({required this.trip});

  final GroupTrip trip;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    final String locale = Localizations.localeOf(context).toLanguageTag();
    final String? chosen = trip.result?.chosenOptionId;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(t.groupOptionsList, style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 8),
        for (final TripOption o in trip.options) ...<Widget>[
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: o.id == chosen
                  ? const Color(0xFF2B2150)
                  : NomadColors.surface,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: o.id == chosen ? NomadColors.group : NomadColors.outline,
                width: o.id == chosen ? 2 : 1,
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Expanded(
                      child: Text(
                        o.label,
                        style: const TextStyle(
                          fontWeight: FontWeight.w800,
                          fontSize: 15,
                        ),
                      ),
                    ),
                    Text(
                      t.groupPerPerson(
                        formatMoney(
                          o.priceMinor,
                          trip.currency,
                          locale,
                          compact: true,
                        ),
                      ),
                      style: const TextStyle(
                        color: NomadColors.money,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
                if (o.tags.isNotEmpty) ...<Widget>[
                  const SizedBox(height: 4),
                  Text(
                    o.tags.map((String tag) => tagLabel(t, tag)).join(' · '),
                    style: const TextStyle(
                      color: NomadColors.textMuted,
                      fontSize: 12,
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 8),
        ],
      ],
    );
  }
}

/// Lo que cuentas a TU agente. Se puede cambiar mientras el grupo espera.
class _PreferencesForm extends StatefulWidget {
  const _PreferencesForm({required this.trip, required this.onSaved});

  final GroupTrip trip;
  final void Function(GroupTrip) onSaved;

  @override
  State<_PreferencesForm> createState() => _PreferencesFormState();
}

class _PreferencesFormState extends State<_PreferencesForm> {
  late final AppServices _services = ServicesScope.of(context);
  final GlobalKey<FormState> _form = GlobalKey<FormState>();
  late final TripPreferences? _sent = widget.trip.myPreferences;
  late final TextEditingController _budget = TextEditingController(
    text: _sent == null
        ? ''
        : '${minorToWhole(_sent.budgetMinor, widget.trip.currency)}',
  );
  late final TextEditingController _notes = TextEditingController(
    text: _sent?.notes ?? '',
  );
  late final Set<String> _likes = <String>{...?_sent?.interests};
  late final Set<String> _avoid = <String>{...?_sent?.avoid};
  bool _busy = false;
  String? _problem;

  @override
  void dispose() {
    _budget.dispose();
    _notes.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final AppLocalizations t = AppLocalizations.of(context);
    if (!(_form.currentState?.validate() ?? false)) return;
    setState(() {
      _busy = true;
      _problem = null;
    });
    try {
      final GroupTrip trip = await _services.group.sendPreferences(
        widget.trip.id,
        TripPreferences(
          budgetMinor: wholeToMinor(
            int.parse(_budget.text),
            widget.trip.currency,
          ),
          interests: _likes.toList(),
          avoid: _avoid.toList(),
          notes: _notes.text.trim(),
        ),
      );
      if (!mounted) return;
      setState(() => _busy = false);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(t.groupSent)));
      widget.onSaved(trip);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _problem = switch (e.error) {
          ApiError.conflict => t.groupClosedNow,
          ApiError.network => t.errorNetwork,
          _ => t.errorUnavailable,
        };
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    final TextTheme text = Theme.of(context).textTheme;
    return Form(
      key: _form,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text(t.groupPrefsTitle, style: text.titleLarge),
          const SizedBox(height: 6),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              const Icon(Icons.lock_rounded, size: 16, color: NomadColors.mint),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  t.groupPrefsPrivate,
                  style: const TextStyle(
                    color: NomadColors.textMuted,
                    fontSize: 13,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          TextFormField(
            controller: _budget,
            keyboardType: TextInputType.number,
            inputFormatters: <TextInputFormatter>[
              FilteringTextInputFormatter.digitsOnly,
              LengthLimitingTextInputFormatter(7),
            ],
            decoration: InputDecoration(
              labelText: t.groupBudget,
              helperText: t.groupBudgetHelp,
              helperMaxLines: 2,
              suffixText: widget.trip.currency,
            ),
            validator: (String? v) =>
                (int.tryParse(v ?? '') ?? 0) <= 0 ? t.groupPriceInvalid : null,
          ),
          const SizedBox(height: 16),
          Text(
            t.groupLikes,
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 6),
          TagPicker(
            selected: _likes,
            blocked: _avoid,
            onChanged: () => setState(() {}),
          ),
          const SizedBox(height: 16),
          Text(
            t.groupAvoid,
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 6),
          TagPicker(
            selected: _avoid,
            blocked: _likes,
            onChanged: () => setState(() {}),
          ),
          const SizedBox(height: 16),
          TextFormField(
            controller: _notes,
            maxLength: maxNotes,
            maxLines: 3,
            minLines: 1,
            textCapitalization: TextCapitalization.sentences,
            decoration: InputDecoration(
              labelText: t.groupNotes,
              hintText: t.groupNotesHint,
            ),
          ),
          if (_problem != null) ...<Widget>[
            const SizedBox(height: 8),
            Text(_problem!, style: const TextStyle(color: NomadColors.safety)),
          ],
          const SizedBox(height: 12),
          FilledButton(
            onPressed: _busy ? null : _send,
            child: _busy
                ? const SizedBox.square(
                    dimension: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Text(
                    widget.trip.myPreferences == null
                        ? t.groupSend
                        : t.groupUpdate,
                  ),
          ),
        ],
      ),
    );
  }
}

/// "Empezar": solo para quien organiza. Los demás ven que esperan por él.
class _StartBox extends StatefulWidget {
  const _StartBox({required this.trip, required this.onStarted});

  final GroupTrip trip;
  final void Function(GroupTrip) onStarted;

  @override
  State<_StartBox> createState() => _StartBoxState();
}

class _StartBoxState extends State<_StartBox> {
  bool _busy = false;
  String? _problem;

  Future<void> _start() async {
    final AppLocalizations t = AppLocalizations.of(context);
    setState(() {
      _busy = true;
      _problem = null;
    });
    try {
      final GroupTrip trip = await ServicesScope.of(context).group
          .start(widget.trip.id);
      if (mounted) setState(() => _busy = false);
      widget.onStarted(trip);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _problem = switch (e.error) {
          ApiError.conflict => t.groupStartNeedsTwo,
          ApiError.network => t.errorNetwork,
          _ => t.errorUnavailable,
        };
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    final GroupTrip trip = widget.trip;
    if (!trip.iOrganize) {
      return Text(
        t.groupWaitingOrganizer,
        style: const TextStyle(color: NomadColors.textMuted),
      );
    }
    final bool enough = trip.ready >= 2;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Text(
          enough ? t.groupStartHelp : t.groupStartNeedsTwo,
          style: const TextStyle(color: NomadColors.textMuted),
        ),
        if (_problem != null) ...<Widget>[
          const SizedBox(height: 6),
          Text(_problem!, style: const TextStyle(color: NomadColors.safety)),
        ],
        const SizedBox(height: 10),
        FilledButton.icon(
          style: FilledButton.styleFrom(backgroundColor: NomadColors.group),
          onPressed: enough && !_busy ? _start : null,
          icon: const Icon(Icons.auto_awesome_rounded),
          label: Text(t.groupStart),
        ),
      ],
    );
  }
}

/// Mientras los agentes negocian: Flyra con una barra que se mueve.
class _Working extends StatelessWidget {
  const _Working();

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    return _FlyraCard(
      title: t.groupWorkingTitle,
      children: <Widget>[
        Text(
          t.groupWorkingText,
          style: const TextStyle(color: Color(0xFFDCD3F7), height: 1.4),
        ),
        const SizedBox(height: 14),
        const LinearProgressIndicator(
          color: NomadColors.group,
          backgroundColor: Color(0xFF3E3163),
        ),
      ],
    );
  }
}

/// El resultado, como en la maqueta: "El agente ha encontrado un acuerdo".
class _ResultCard extends StatelessWidget {
  const _ResultCard({required this.trip, required this.result});

  final GroupTrip trip;
  final TripResult result;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    final String locale = Localizations.localeOf(context).toLanguageTag();
    final TripOption? chosen = trip.option(result.chosenOptionId);
    final String title = switch (result.outcome) {
      TripOutcome.consensus => t.groupResultConsensus,
      TripOutcome.arbitration => t.groupResultArbitration,
      TripOutcome.noFeasibleOption => t.groupResultNone,
    };
    // Por qué, escrito con reglas (igual que en el servidor, pero traducido).
    final String why = switch (result.outcome) {
      TripOutcome.noFeasibleOption => t.groupResultNoneTip,
      TripOutcome.consensus when result.rounds == 0 => t.groupResultOnlyOne,
      TripOutcome.consensus => t.groupResultRound(result.rounds),
      TripOutcome.arbitration => t.groupResultArbiter(result.rounds),
    };
    return _FlyraCard(
      title: title,
      children: <Widget>[
        if (chosen != null) ...<Widget>[
          Text(chosen.label, style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 2),
          Text(
            t.groupPerPerson(
              formatMoney(
                chosen.priceMinor,
                trip.currency,
                locale,
                compact: true,
              ),
            ),
            style: const TextStyle(
              color: NomadColors.money,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 10),
        ],
        Text(
          why,
          style: const TextStyle(color: Color(0xFFDCD3F7), height: 1.4),
        ),
        if (result.excludedOverBudget > 0) ...<Widget>[
          const SizedBox(height: 6),
          Text(
            t.groupResultExcluded(result.excludedOverBudget),
            style: const TextStyle(color: Color(0xFFB9AEDB), fontSize: 13),
          ),
        ],
      ],
    );
  }
}

/// Lo que dijo cada agente y cómo de contenta queda cada persona.
class _AgentsSaid extends StatelessWidget {
  const _AgentsSaid({required this.trip, required this.result});

  final GroupTrip trip;
  final TripResult result;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    if (result.members.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          t.groupResultAgents,
          style: Theme.of(context).textTheme.titleLarge,
        ),
        const SizedBox(height: 8),
        for (final MemberOutcome m in result.members) ...<Widget>[
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: NomadColors.surface,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: NomadColors.outline),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Expanded(
                      child: Text(
                        m.alias == trip.myAlias
                            ? t.groupYourAgent
                            : t.groupAgentOf(trip.nameOf(m.alias)),
                        style: const TextStyle(fontWeight: FontWeight.w800),
                      ),
                    ),
                    if (m.chosenRank != null)
                      Text(
                        m.chosenRank == 1
                            ? t.groupRankFavourite
                            : t.groupRankN(m.chosenRank!),
                        style: TextStyle(
                          color: m.chosenRank == 1
                              ? NomadColors.mint
                              : NomadColors.textMuted,
                          fontWeight: FontWeight.w700,
                          fontSize: 12,
                        ),
                      ),
                  ],
                ),
                if (m.argument.isNotEmpty) ...<Widget>[
                  const SizedBox(height: 4),
                  Text('“${m.argument}”'),
                ],
                if (!m.byAi) ...<Widget>[
                  const SizedBox(height: 4),
                  Text(
                    t.groupByRules,
                    style: const TextStyle(
                      color: NomadColors.textMuted,
                      fontSize: 12,
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 8),
        ],
      ],
    );
  }
}

/// La tarjeta violeta con Flyra de la maqueta.
class _FlyraCard extends StatelessWidget {
  const _FlyraCard({required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: const Color(0xFF1A1530),
      borderRadius: BorderRadius.circular(26),
      border: Border.all(color: const Color(0xFF3E3163)),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            const FlyraAvatar(size: 36),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                title,
                style: const TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize: 15,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        ...children,
      ],
    ),
  );
}
