// Elegid planes (maqueta "Planes"): cada uno, desde su móvil, desliza las
// tarjetas de planes del viaje en grupo: a la derecha SÍ, a la izquierda NO.
// Los planes que gustan a TODOS salen como "¡Match!".
//
// De dónde salen los planes (0 €):
//   - Los que añade cada uno ("Fado en Alfama, esta noche, 25 €").
//   - "Ideas de la ciudad": las atracciones de la ficha de la ciudad que ya
//     tenemos (GET /v1/places/{IATA}, Wikidata, con caché en el servidor).
import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/api_client.dart';
import '../../core/services.dart';
import '../../core/theme.dart';
import '../../l10n/generated/app_localizations.dart';
import '../easy/easy_mode.dart';
import '../route/places_api.dart';
import 'plans_api.dart';

class PlansScreen extends StatefulWidget {
  const PlansScreen({super.key, required this.tripId, this.city});

  final String tripId;

  /// El destino que eligió el grupo ("Lisboa"), para el subtítulo.
  final String? city;

  @override
  State<PlansScreen> createState() => _PlansScreenState();
}

class _PlansScreenState extends State<PlansScreen> {
  late final AppServices _services = ServicesScope.of(context);

  PlanBoard? _board;
  ApiError? _error;
  bool _busy = false;

  /// "Volver a empezar": vuelve a enseñar todas las tarjetas (tu voto nuevo
  /// sustituye al anterior).
  bool _again = false;
  final Set<String> _revoted = <String>{};

  /// Cuánto has arrastrado la tarjeta de arriba (en píxeles).
  double _drag = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final PlanBoard b = await _services.plans.board(widget.tripId);
      if (mounted) setState(() => (_board = b, _error = null));
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.error);
    }
  }

  /// Las tarjetas que quedan por votar (la primera es la de arriba).
  List<GroupPlan> get _deck {
    final PlanBoard? b = _board;
    if (b == null) return const <GroupPlan>[];
    if (_again) {
      return b.plans.where((GroupPlan p) => !_revoted.contains(p.id)).toList();
    }
    return b.pending;
  }

  Future<void> _run(Future<PlanBoard> Function() call) async {
    setState(() => _busy = true);
    try {
      final PlanBoard b = await call();
      if (mounted) setState(() => _board = b);
    } on ApiException catch (e) {
      if (!mounted) return;
      final AppLocalizations t = AppLocalizations.of(context);
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(switch (e.error) {
              ApiError.network => t.errorNetwork,
              ApiError.conflict => t.plansTooMany,
              _ => t.errorUnavailable,
            }),
          ),
        );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _vote(GroupPlan plan, bool yes) async {
    setState(() {
      _drag = 0;
      if (_again) _revoted.add(plan.id);
    });
    await _run(() => _services.plans.vote(widget.tripId, plan.id, yes: yes));
  }

  Future<void> _addMine() async {
    final NewPlan? plan = await showDialog<NewPlan>(
      context: context,
      builder: (BuildContext context) => const _NewPlanDialog(),
    );
    if (plan == null || !mounted) return;
    await _run(() => _services.plans.add(widget.tripId, <NewPlan>[plan]));
  }

  /// Añade las atracciones de la ficha de la ciudad (hasta 8).
  Future<void> _addIdeas() async {
    final AppLocalizations t = AppLocalizations.of(context);
    final String lang = Localizations.localeOf(context).languageCode;
    final String? iata = await showDialog<String>(
      context: context,
      builder: (BuildContext context) =>
          _AirportDialog(initial: loadEasyTrip(_services.prefs).to ?? ''),
    );
    if (iata == null || !mounted) return;
    setState(() => _busy = true);
    PlaceCard? card;
    try {
      card = await _services.places.get(iata, lang);
    } on ApiException {
      card = null;
    }
    if (!mounted) return;
    setState(() => _busy = false);
    final List<NewPlan> ideas = <NewPlan>[
      for (final Attraction a in card?.attractions ?? const <Attraction>[])
        NewPlan(
          title: a.name,
          note: a.description,
          photoUrl: a.photo?.url,
          articleUrl: a.articleUrl,
          wikidataId: a.wikidataId,
        ),
    ];
    if (ideas.isEmpty) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(t.plansNoIdeas)));
      return;
    }
    await _run(() => _services.plans.add(widget.tripId, ideas));
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    final PlanBoard? board = _board;
    final ApiError? error = _error;
    return Scaffold(
      appBar: AppBar(title: Text(t.plansTitle)),
      body: SafeArea(
        child: board == null
            ? Center(
                child: error == null
                    ? const CircularProgressIndicator()
                    : Padding(
                        padding: const EdgeInsets.all(32),
                        child: Text(switch (error) {
                          ApiError.network => t.errorNetwork,
                          ApiError.notFound => t.groupNotFound,
                          ApiError.signedOut => t.groupSignIn,
                          _ => t.errorUnavailable,
                        }, textAlign: TextAlign.center),
                      ),
              )
            : _body(t, board),
      ),
    );
  }

  Widget _body(AppLocalizations t, PlanBoard board) {
    final TextTheme text = Theme.of(context).textTheme;
    final List<GroupPlan> deck = _deck;
    final List<GroupPlan> matches = board.matches;
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 32),
      children: <Widget>[
        Text(
          widget.city == null
              ? t.plansSwipeHint
              : '${widget.city} · ${t.plansSwipeHint}',
          style: text.bodyMedium?.copyWith(color: NomadColors.textMuted),
        ),
        const SizedBox(height: 12),
        if (board.plans.isEmpty)
          Text(t.plansEmpty, style: text.titleMedium)
        else if (deck.isNotEmpty) ...<Widget>[
          Text(
            t.plansProgress(
              board.plans.length - deck.length + 1,
              board.plans.length,
            ),
            style: const TextStyle(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 12),
          _stack(t, deck),
          const SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              _RoundButton(
                icon: Icons.close_rounded,
                color: const Color(0xFFFF6B6B),
                tooltip: t.plansNo,
                onTap: _busy ? null : () => _vote(deck.first, false),
              ),
              const SizedBox(width: 32),
              _RoundButton(
                icon: Icons.favorite_rounded,
                color: NomadColors.mint,
                tooltip: t.plansYes,
                onTap: _busy ? null : () => _vote(deck.first, true),
              ),
            ],
          ),
        ] else ...<Widget>[
          Text(
            matches.isEmpty ? t.plansAllVoted : t.plansMatch,
            style: text.headlineSmall?.copyWith(
              color: matches.isEmpty ? null : NomadColors.mint,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            matches.isEmpty
                ? t.plansWaiting(board.members)
                : t.plansMatchBody(board.members),
          ),
          const SizedBox(height: 12),
          for (final GroupPlan p in matches)
            Card(
              child: ListTile(
                leading: const Icon(
                  Icons.favorite_rounded,
                  color: NomadColors.mint,
                ),
                title: Text(p.title),
                subtitle: p.note == null ? null : Text(p.note!),
              ),
            ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            icon: const Icon(Icons.replay_rounded),
            label: Text(t.plansRestart),
            onPressed: () => setState(() {
              _again = true;
              _revoted.clear();
            }),
          ),
        ],
        const SizedBox(height: 24),
        Text(t.plansAddTitle, style: text.titleMedium),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: <Widget>[
            FilledButton.tonalIcon(
              icon: const Icon(Icons.add_rounded),
              label: Text(t.plansAddMine),
              onPressed: _busy ? null : _addMine,
            ),
            FilledButton.tonalIcon(
              icon: const Icon(Icons.auto_awesome_rounded),
              label: Text(t.plansAddIdeas),
              onPressed: _busy ? null : _addIdeas,
            ),
          ],
        ),
        if (board.plans.isNotEmpty) ...<Widget>[
          const SizedBox(height: 24),
          Text(t.plansAll, style: text.titleMedium),
          for (final GroupPlan p in board.plans)
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(p.title),
              subtitle: Text(t.plansVotes(p.yes, p.voted, board.members)),
              trailing: p.mine
                  ? IconButton(
                      tooltip: t.plansRemove,
                      icon: const Icon(Icons.delete_outline_rounded),
                      onPressed: _busy
                          ? null
                          : () => _run(
                              () => _services.plans.remove(widget.tripId, p.id),
                            ),
                    )
                  : null,
            ),
        ],
      ],
    );
  }

  /// La tarjeta de arriba (la que se arrastra) y la siguiente, detrás.
  Widget _stack(AppLocalizations t, List<GroupPlan> deck) {
    final GroupPlan top = deck.first;
    final GroupPlan? next = deck.length > 1 ? deck[1] : null;
    // En árabe (de derecha a izquierda) el gesto es el mismo: derecha = sí,
    // como en todas las apps de deslizar.
    return SizedBox(
      height: 380,
      child: Stack(
        children: <Widget>[
          if (next != null)
            Positioned.fill(
              child: Transform.translate(
                offset: const Offset(0, 14),
                child: Transform.scale(
                  scale: 0.95,
                  child: _PlanCard(plan: next),
                ),
              ),
            ),
          Positioned.fill(
            child: GestureDetector(
              onHorizontalDragUpdate: _busy
                  ? null
                  : (DragUpdateDetails d) =>
                        setState(() => _drag += d.delta.dx),
              onHorizontalDragEnd: _busy
                  ? null
                  : (_) {
                      if (_drag.abs() > 90) {
                        unawaited(_vote(top, _drag > 0));
                      } else {
                        setState(() => _drag = 0);
                      }
                    },
              child: Transform.translate(
                offset: Offset(_drag, 0),
                child: Transform.rotate(
                  angle: _drag / 14 * 3.14159 / 180,
                  child: _PlanCard(
                    plan: top,
                    yes: (_drag / 80).clamp(0, 1).toDouble(),
                    no: (-_drag / 80).clamp(0, 1).toDouble(),
                    yesLabel: t.plansYes,
                    noLabel: t.plansNo,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _PlanCard extends StatelessWidget {
  const _PlanCard({
    required this.plan,
    this.yes = 0,
    this.no = 0,
    this.yesLabel,
    this.noLabel,
  });

  final GroupPlan plan;
  final double yes;
  final double no;
  final String? yesLabel;
  final String? noLabel;

  @override
  Widget build(BuildContext context) {
    final Uri? photo = plan.photoUrl;
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(28),
        color: const Color(0xFF1A1530),
        border: Border.all(color: const Color(0xFF3E3163)),
        boxShadow: const <BoxShadow>[
          BoxShadow(
            color: Color(0x73000000),
            blurRadius: 40,
            offset: Offset(0, 20),
          ),
        ],
      ),
      child: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          if (photo != null)
            Image.network(
              photo.toString(),
              fit: BoxFit.cover,
              errorBuilder: (_, _, _) => const _Art(),
            )
          else
            const _Art(),
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: <Color>[Color(0x00000000), Color(0xE6000000)],
                stops: <double>[0.4, 1],
              ),
            ),
          ),
          PositionedDirectional(
            start: 20,
            end: 20,
            bottom: 20,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  plan.title,
                  style: Theme.of(context).textTheme.headlineSmall
                      ?.copyWith(color: Colors.white),
                ),
                if (plan.note != null)
                  Text(
                    plan.note!,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Color(0xFFE0E0E0)),
                  ),
              ],
            ),
          ),
          if (yesLabel != null)
            Positioned(
              left: 18,
              top: 22,
              child: Opacity(
                opacity: yes,
                child: _Stamp(yesLabel!, NomadColors.mint, -0.24),
              ),
            ),
          if (noLabel != null)
            Positioned(
              right: 18,
              top: 22,
              child: Opacity(
                opacity: no,
                child: _Stamp(noLabel!, const Color(0xFFFF6B6B), 0.24),
              ),
            ),
        ],
      ),
    );
  }
}

/// El dibujo de fondo cuando el plan no tiene foto.
class _Art extends StatelessWidget {
  const _Art();

  @override
  Widget build(BuildContext context) => const DecoratedBox(
    decoration: BoxDecoration(
      gradient: LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: <Color>[Color(0xFF7B4FA3), Color(0xFF1A1530)],
      ),
    ),
    child: Center(
      child: Icon(
        Icons.local_activity_rounded,
        size: 96,
        color: Colors.white24,
      ),
    ),
  );
}

/// El sello "SÍ" / "NO" que aparece al arrastrar.
class _Stamp extends StatelessWidget {
  const _Stamp(this.label, this.color, this.angle);

  final String label;
  final Color color;
  final double angle;

  @override
  Widget build(BuildContext context) => Transform.rotate(
    angle: angle,
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
      decoration: BoxDecoration(
        border: Border.all(color: color, width: 4),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 30,
          fontWeight: FontWeight.w800,
        ),
      ),
    ),
  );
}

class _RoundButton extends StatelessWidget {
  const _RoundButton({
    required this.icon,
    required this.color,
    required this.tooltip,
    required this.onTap,
  });

  final IconData icon;
  final Color color;
  final String tooltip;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => IconButton.outlined(
    tooltip: tooltip,
    iconSize: 32,
    style: IconButton.styleFrom(
      foregroundColor: color,
      side: BorderSide(color: color, width: 2),
      minimumSize: const Size(64, 64),
    ),
    icon: Icon(icon),
    onPressed: onTap,
  );
}

class _NewPlanDialog extends StatefulWidget {
  const _NewPlanDialog();

  @override
  State<_NewPlanDialog> createState() => _NewPlanDialogState();
}

class _NewPlanDialogState extends State<_NewPlanDialog> {
  final TextEditingController _title = TextEditingController();
  final TextEditingController _note = TextEditingController();

  @override
  void dispose() {
    _title.dispose();
    _note.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    return AlertDialog(
      title: Text(t.plansAddMine),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          TextField(
            controller: _title,
            maxLength: maxPlanTitle,
            autofocus: true,
            decoration: InputDecoration(labelText: t.plansFieldTitle),
            onChanged: (_) => setState(() {}),
          ),
          TextField(
            controller: _note,
            maxLength: maxPlanNote,
            decoration: InputDecoration(
              labelText: t.plansFieldNote,
              hintText: t.plansFieldNoteHint,
            ),
          ),
        ],
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(MaterialLocalizations.of(context).cancelButtonLabel),
        ),
        FilledButton(
          onPressed: _title.text.trim().isEmpty
              ? null
              : () => Navigator.of(context).pop(
                  NewPlan(
                    title: _title.text.trim(),
                    note: _note.text.trim().isEmpty ? null : _note.text.trim(),
                  ),
                ),
          child: Text(t.plansAdd),
        ),
      ],
    );
  }
}

class _AirportDialog extends StatefulWidget {
  const _AirportDialog({required this.initial});

  final String initial;

  @override
  State<_AirportDialog> createState() => _AirportDialogState();
}

class _AirportDialogState extends State<_AirportDialog> {
  late final TextEditingController _code = TextEditingController(
    text: widget.initial,
  );

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  bool get _ok => RegExp(r'^[A-Za-z]{3}$').hasMatch(_code.text.trim());

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    return AlertDialog(
      title: Text(t.plansAddIdeas),
      content: TextField(
        controller: _code,
        maxLength: 3,
        autofocus: true,
        textCapitalization: TextCapitalization.characters,
        decoration: InputDecoration(labelText: t.plansAirport),
        onChanged: (_) => setState(() {}),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(MaterialLocalizations.of(context).cancelButtonLabel),
        ),
        FilledButton(
          onPressed: _ok
              ? () => Navigator.of(context).pop(_code.text.trim().toUpperCase())
              : null,
          child: Text(t.plansAdd),
        ),
      ],
    );
  }
}
