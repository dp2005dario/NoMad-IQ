// Elegid planes (maqueta "Planes", pantalla 34): cada uno, desde su móvil,
// desliza las tarjetas de planes del viaje en grupo: a la derecha "me
// apetece", a la izquierda "paso". Los votos son SECRETOS: nadie ve qué has
// marcado hasta que coincidís. Cuando dos o más dicen que sí a un sitio sale
// "¡MATCH VIAJERO!" a pantalla completa, y "Añadir al plan" lo mete en el
// plan del grupo (y avisa a todos por el chat del viaje).
//
// De dónde salen los planes (0 €):
//   - Los que añade cada uno ("Fado en Alfama, esta noche, 25 €").
//   - "Ideas de la ciudad": las atracciones de la ficha de la ciudad que ya
//     tenemos (GET /v1/places/{IATA}, Wikidata, con caché en el servidor).
import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/api_client.dart';
import '../../core/services.dart';
import '../../core/settings.dart';
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
      if (mounted) await _celebrateNew();
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
    final AppLocalizations t = AppLocalizations.of(context);
    setState(() {
      _drag = 0;
      if (_again) _revoted.add(plan.id);
    });
    await _run(() => _services.plans.vote(widget.tripId, plan.id, yes: yes));
    if (!mounted || !yes) return;
    final GroupPlan? now = _board?.plans
        .where((GroupPlan p) => p.id == plan.id)
        .firstOrNull;
    if (now != null && now.myMatch && !now.planned) {
      await _celebrate(now);
    } else if (now != null) {
      _say(t.plansSavedSecret);
    }
  }

  /// Un aviso corto abajo (como el "toast" de la maqueta).
  void _say(String text) => ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(text)));

  /// Los match que ya te enseñamos en grande (se guardan en el móvil).
  Set<String> get _seen {
    try {
      final Object? l = jsonDecode(
        _services.prefs.readData(LocalData.plansSeen) ?? '[]',
      );
      return <String>{
        if (l is List<Object?>)
          for (final Object? id in l) ?(id is String ? id : null),
      };
    } on FormatException {
      return <String>{};
    }
  }

  Future<void> _markSeen(GroupPlan plan) async {
    final List<String> all = <String>[..._seen, '${widget.tripId}:${plan.id}'];
    // Solo los últimos 200: la lista no crece sin fin.
    await _services.prefs.writeData(
      LocalData.plansSeen,
      jsonEncode(all.length > 200 ? all.sublist(all.length - 200) : all),
    );
  }

  /// Al entrar: si alguien votó mientras no estabas y ahora coincidís, se
  /// celebra (una sola vez).
  Future<void> _celebrateNew() async {
    final Set<String> seen = _seen;
    final GroupPlan? fresh = _board?.plans
        .where(
          (GroupPlan p) =>
              p.myMatch &&
              !p.planned &&
              !seen.contains('${widget.tripId}:${p.id}'),
        )
        .firstOrNull;
    if (fresh != null) await _celebrate(fresh);
  }

  /// "¡MATCH VIAJERO!" a pantalla completa, con vibración. Si eliges
  /// "Añadir al plan", se mete en el plan del grupo.
  Future<void> _celebrate(GroupPlan plan) async {
    await _markSeen(plan);
    unawaited(HapticFeedback.heavyImpact());
    if (!mounted) return;
    final bool? add = await showGeneralDialog<bool>(
      context: context,
      useRootNavigator: true,
      barrierDismissible: false,
      transitionDuration: const Duration(milliseconds: 300),
      pageBuilder: (BuildContext dialog, _, _) => _MatchOverlay(
        plan: plan,
        names: plan.matchWith,
        onKeep: () => Navigator.of(dialog).pop(false),
        onAdd: () => Navigator.of(dialog).pop(true),
      ),
    );
    if (add == true && mounted) await _addToPlan(plan);
  }

  /// "Añadir al plan": se apunta en el servidor y se avisa al grupo con un
  /// mensaje en el chat del viaje (a los demás les llega la notificación).
  Future<void> _addToPlan(GroupPlan plan) async {
    final AppLocalizations t = AppLocalizations.of(context);
    final String lang = Localizations.localeOf(context).languageCode;
    await _run(() => _services.plans.addToPlan(widget.tripId, plan.id));
    final bool ok =
        _board?.plans.any((GroupPlan p) => p.id == plan.id && p.planned) ??
        false;
    if (!ok || !mounted) return;
    try {
      await _services.groupChat.send(
        widget.tripId,
        t.plansChatAdded(plan.title),
        lang,
      );
    } on ApiException {
      // Ya está en el plan; si el aviso del chat falla, no pasa nada grave.
    }
    if (mounted) _say(t.plansAddedToast);
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

  /// "Tú, Marta y Álex".
  String _join(AppLocalizations t, List<String> names) => names.length < 2
      ? names.join()
      : t.plansJoinAnd(
          names.sublist(0, names.length - 1).join(', '),
          names.last,
        );

  Widget _body(AppLocalizations t, PlanBoard board) {
    final TextTheme text = Theme.of(context).textTheme;
    final List<GroupPlan> deck = _deck;
    // Mis match viajeros (coincido con alguien) y mis "sí" aún sin pareja.
    final List<GroupPlan> matches = board.plans
        .where((GroupPlan p) => p.myMatch)
        .toList();
    final List<GroupPlan> waiting = board.plans
        .where((GroupPlan p) => p.myVote == true && !p.myMatch)
        .toList();
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 32),
      children: <Widget>[
        Text(
          widget.city == null
              ? t.plansSwipeHint2
              : '${widget.city} · ${t.plansSwipeHint2}',
          style: text.bodyMedium?.copyWith(color: NomadColors.textMuted),
        ),
        if (board.people.isNotEmpty) ...<Widget>[
          const SizedBox(height: 12),
          _People(people: board.people),
        ],
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
                tooltip: t.plansNoStamp,
                onTap: _busy ? null : () => _vote(deck.first, false),
              ),
              const SizedBox(width: 32),
              _RoundButton(
                icon: Icons.favorite_rounded,
                color: NomadColors.mint,
                tooltip: t.plansYesStamp,
                onTap: _busy ? null : () => _vote(deck.first, true),
              ),
            ],
          ),
        ] else ...<Widget>[
          Text(t.plansAllVoted, style: text.titleMedium),
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
        // Vuestros match viajeros.
        Text(t.plansMatchesTitle, style: text.titleLarge),
        Text(
          t.plansMatchesSub,
          style: text.bodySmall?.copyWith(color: NomadColors.textMuted),
        ),
        const SizedBox(height: 8),
        if (matches.isEmpty)
          Text(
            t.plansWaiting(board.members),
            style: const TextStyle(color: NomadColors.textMuted),
          ),
        for (final GroupPlan p in matches)
          Card(
            child: ListTile(
              leading: const Icon(
                Icons.favorite_rounded,
                color: NomadColors.mint,
              ),
              title: Text(
                p.title,
                style: const TextStyle(fontWeight: FontWeight.w800),
              ),
              subtitle: Text(_join(t, <String>[t.plansYou, ...p.matchWith])),
              trailing: p.planned
                  ? Text(
                      t.plansInPlan,
                      style: const TextStyle(
                        color: NomadColors.mint,
                        fontWeight: FontWeight.w800,
                      ),
                    )
                  : TextButton(
                      style: TextButton.styleFrom(
                        minimumSize: const Size(0, 36),
                      ),
                      onPressed: _busy ? null : () => _addToPlan(p),
                      child: Text(t.plansAddToPlan),
                    ),
            ),
          ),
        if (waiting.isNotEmpty) ...<Widget>[
          const SizedBox(height: 16),
          Text(
            t.plansWaitingTitle,
            style: text.labelMedium?.copyWith(
              color: NomadColors.textMuted,
              letterSpacing: 1.1,
              fontWeight: FontWeight.w800,
            ),
          ),
          for (final GroupPlan p in waiting)
            ListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              leading: const Icon(Icons.lock_rounded, size: 18),
              title: Text(p.title),
              trailing: Text(
                t.plansSecret,
                style: const TextStyle(color: NomadColors.group),
              ),
            ),
        ],
        const SizedBox(height: 12),
        Text(
          t.plansSecretFoot,
          style: text.bodySmall?.copyWith(color: NomadColors.textMuted),
        ),
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
        // Tus propios planes, para poder quitarlos (no se ven los votos de
        // nadie: son secretos).
        if (board.plans.any((GroupPlan p) => p.mine)) ...<Widget>[
          const SizedBox(height: 24),
          Text(t.plansAll, style: text.titleMedium),
          for (final GroupPlan p in board.plans.where((GroupPlan p) => p.mine))
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(p.title),
              trailing: IconButton(
                tooltip: t.plansRemove,
                icon: const Icon(Icons.delete_outline_rounded),
                onPressed: _busy
                    ? null
                    : () => _run(
                        () => _services.plans.remove(widget.tripId, p.id),
                      ),
              ),
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
                    yesLabel: t.plansYesStamp,
                    noLabel: t.plansNoStamp,
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
          // De dónde sale la foto (todas son de Wikimedia Commons).
          if (photo != null)
            const PositionedDirectional(
              end: 12,
              top: 12,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: Color(0x8C0B1217),
                  borderRadius: BorderRadius.all(Radius.circular(8)),
                ),
                child: Padding(
                  padding: EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  child: Text(
                    '📷 Wikimedia Commons',
                    style: TextStyle(color: Colors.white70, fontSize: 11),
                  ),
                ),
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

/// Los colores de las caras del grupo (como en la maqueta).
const List<Color> _faceColors = <Color>[
  NomadColors.group,
  NomadColors.safety,
  NomadColors.flights,
  NomadColors.money,
  NomadColors.mint,
  Color(0xFFFF8FB1),
  Color(0xFF7FE8B9),
  Color(0xFFFFD27A),
];

/// Una cara redonda con la inicial.
class _Face extends StatelessWidget {
  const _Face({required this.label, required this.color});

  final String label;
  final Color color;

  static const double size = 38;

  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    alignment: Alignment.center,
    decoration: BoxDecoration(
      shape: BoxShape.circle,
      gradient: RadialGradient(
        center: const Alignment(-0.3, -0.4),
        colors: <Color>[Colors.white.withValues(alpha: 0.55), color],
        stops: const <double>[0, 0.6],
      ),
    ),
    child: Text(
      label,
      style: TextStyle(
        color: NomadColors.background,
        fontWeight: FontWeight.w800,
        fontSize: size * 0.36,
      ),
    ),
  );
}

/// Las caras de arriba: quién ya votó y quién aún no ha entrado.
class _People extends StatelessWidget {
  const _People({required this.people});

  final List<PlanPerson> people;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    // Tú primero, como en la maqueta.
    final List<PlanPerson> sorted = <PlanPerson>[
      ...people.where((PlanPerson p) => p.me),
      ...people.where((PlanPerson p) => !p.me),
    ];
    return Wrap(
      spacing: 14,
      runSpacing: 8,
      children: <Widget>[
        for (int i = 0; i < sorted.length; i++)
          Opacity(
            opacity: sorted[i].me || sorted[i].voted ? 1 : 0.4,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Stack(
                  clipBehavior: Clip.none,
                  children: <Widget>[
                    _Face(
                      label: sorted[i].me
                          ? t.plansYou.toUpperCase()
                          : sorted[i].name.characters.first.toUpperCase(),
                      color: _faceColors[i % _faceColors.length],
                    ),
                    Positioned(
                      right: -1,
                      bottom: -1,
                      child: Container(
                        width: 11,
                        height: 11,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: sorted[i].me || sorted[i].voted
                              ? NomadColors.mint
                              : NomadColors.textMuted,
                          border: Border.all(
                            color: NomadColors.background,
                            width: 2,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  sorted[i].me
                      ? t.plansYou
                      : sorted[i].voted
                      ? t.plansVotedYet
                      : t.plansNotIn,
                  style: const TextStyle(
                    fontSize: 11,
                    color: NomadColors.textMuted,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// "¡MATCH VIAJERO!" a pantalla completa: las letras saltan una a una, cae
/// confeti, la foto del sitio, tu tarjeta y la de quien coincide contigo, y
/// Flyra pregunta si lo mete en el plan.
class _MatchOverlay extends StatefulWidget {
  const _MatchOverlay({
    required this.plan,
    required this.names,
    required this.onKeep,
    required this.onAdd,
  });

  final GroupPlan plan;

  /// Con quién coincides (sin ti).
  final List<String> names;
  final VoidCallback onKeep;
  final VoidCallback onAdd;

  @override
  State<_MatchOverlay> createState() => _MatchOverlayState();
}

class _MatchOverlayState extends State<_MatchOverlay>
    with SingleTickerProviderStateMixin {
  // Una sola animación de 3 s para todo (letras, confeti y tarjetas).
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 3000),
  );

  @override
  void initState() {
    super.initState();
    // Con "reducir movimiento" se enseña directamente el final.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (MediaQuery.of(context).disableAnimations) {
        _c.value = 1;
      } else {
        unawaited(_c.forward());
      }
    });
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    final TextTheme text = Theme.of(context).textTheme;
    final GroupPlan plan = widget.plan;
    final List<String> who = widget.names;
    final String all = who.isEmpty
        ? t.plansYou
        : who.length == 1
        ? t.plansJoinAnd(t.plansYou, who.first)
        : t.plansJoinAnd(
            <String>[t.plansYou, ...who.sublist(0, who.length - 1)].join(', '),
            who.last,
          );
    final String big = t.plansMatchBig;
    final Uri? photo = plan.photoUrl;
    return Material(
      color: const Color(0xF2120C24),
      child: SafeArea(
        child: AnimatedBuilder(
          animation: _c,
          builder: (BuildContext context, _) {
            final double v = _c.value;
            // Cada trozo entra en su momento (de 0 a 1 dentro de su tramo).
            double part(double from, double to) =>
                ((v - from) / (to - from)).clamp(0.0, 1.0);
            return Stack(
              children: <Widget>[
                Positioned.fill(
                  child: IgnorePointer(
                    child: CustomPaint(painter: _Confetti(part(0.25, 1))),
                  ),
                ),
                ListView(
                  padding: const EdgeInsets.fromLTRB(24, 32, 24, 24),
                  children: <Widget>[
                    // Las letras de "¡MATCH VIAJERO!" saltan una a una.
                    Wrap(
                      alignment: WrapAlignment.center,
                      children: <Widget>[
                        for (int i = 0; i < big.length; i++)
                          Transform.scale(
                            scale: Curves.elasticOut.transform(
                              part(0.05 + i * 0.015, 0.35 + i * 0.015),
                            ),
                            child: Text(
                              big[i],
                              style: text.headlineLarge?.copyWith(
                                color: const Color(0xFFFFD27A),
                                fontWeight: FontWeight.w900,
                              ),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Opacity(
                      opacity: part(0.3, 0.45),
                      child: Text(
                        t.plansMatchSub(all, plan.title),
                        textAlign: TextAlign.center,
                        style: text.titleMedium?.copyWith(color: Colors.white),
                      ),
                    ),
                    const SizedBox(height: 18),
                    // La foto del sitio.
                    Center(
                      child: Transform.scale(
                        scale: Curves.easeOutBack.transform(part(0.1, 0.35)),
                        child: Container(
                          width: 150,
                          height: 150,
                          clipBehavior: Clip.antiAlias,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: const Color(0xFFFFF3D6),
                              width: 4,
                            ),
                          ),
                          child: photo == null
                              ? const _Art()
                              : Image.network(
                                  photo.toString(),
                                  fit: BoxFit.cover,
                                  errorBuilder: (_, _, _) => const _Art(),
                                ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 18),
                    // Tu tarjeta y la de quien coincide contigo, que se
                    // acercan desde los lados.
                    Row(
                      children: <Widget>[
                        Expanded(
                          child: Transform.translate(
                            offset: Offset(
                              -80 *
                                  (1 -
                                      Curves.easeOut.transform(part(0.2, 0.4))),
                              0,
                            ),
                            child: Transform.rotate(
                              angle: -0.08,
                              child: _PersonCard(
                                face: '★',
                                name: t.plansYou,
                                color: NomadColors.group,
                                meToo: t.plansMeToo,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Transform.translate(
                            offset: Offset(
                              80 *
                                  (1 -
                                      Curves.easeOut.transform(part(0.2, 0.4))),
                              0,
                            ),
                            child: Transform.rotate(
                              angle: 0.08,
                              child: _PersonCard(
                                face: who.isEmpty
                                    ? '?'
                                    : who.first.characters.first.toUpperCase(),
                                name: who.isEmpty ? '' : who.first,
                                color: NomadColors.safety,
                                meToo: t.plansMeToo,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                    if (who.length > 1) ...<Widget>[
                      const SizedBox(height: 10),
                      Center(
                        child: Opacity(
                          opacity: part(0.4, 0.5),
                          child: Chip(
                            label: Text(
                              '+ ${who.sublist(1).join(', ')}',
                              style: const TextStyle(
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                    const SizedBox(height: 18),
                    // Flyra pregunta.
                    Opacity(
                      opacity: part(0.45, 0.6),
                      child: Container(
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: NomadColors.group.withValues(alpha: 0.18),
                          borderRadius: BorderRadius.circular(18),
                        ),
                        child: Text(
                          '✦ ${t.plansMatchFly(plan.title, who.length + 1)}',
                          style: const TextStyle(color: Colors.white),
                        ),
                      ),
                    ),
                    const SizedBox(height: 18),
                    Row(
                      children: <Widget>[
                        Expanded(
                          child: OutlinedButton(
                            style: OutlinedButton.styleFrom(
                              minimumSize: const Size(0, 52),
                            ),
                            onPressed: widget.onKeep,
                            child: Text(t.plansKeepPicking),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: FilledButton(
                            style: FilledButton.styleFrom(
                              minimumSize: const Size(0, 52),
                            ),
                            onPressed: widget.onAdd,
                            child: Text(t.plansAddToPlan),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// La tarjeta de una persona en el match ("★ Tú · ❤ Me apetece").
class _PersonCard extends StatelessWidget {
  const _PersonCard({
    required this.face,
    required this.name,
    required this.color,
    required this.meToo,
  });

  final String face;
  final String name;
  final Color color;
  final String meToo;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 8),
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(22),
      border: Border.all(color: const Color(0xFFFFF3D6), width: 3),
      gradient: RadialGradient(
        center: const Alignment(-0.4, -0.7),
        radius: 1.2,
        colors: <Color>[Colors.white.withValues(alpha: 0.65), color],
        stops: const <double>[0, 0.55],
      ),
    ),
    child: Column(
      children: <Widget>[
        Text(
          face,
          style: const TextStyle(
            fontSize: 34,
            fontWeight: FontWeight.w900,
            color: Color(0xFF120C24),
          ),
        ),
        Text(
          name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            fontWeight: FontWeight.w800,
            color: Color(0xFF120C24),
          ),
        ),
        Text(
          meToo,
          style: const TextStyle(fontSize: 12, color: Color(0xFF120C24)),
        ),
      ],
    ),
  );
}

/// El confeti que cae (dibujado, sin imágenes). [t] va de 0 a 1.
class _Confetti extends CustomPainter {
  const _Confetti(this.t);

  final double t;

  static const List<Color> _colors = <Color>[
    Color(0xFFFFD27A),
    Color(0xFFFF7AB6),
    Color(0xFFB69CFF),
    Color(0xFF7FE8B9),
    Color(0xFF6CA8FF),
    Colors.white,
    Color(0xFFFF8A65),
  ];

  @override
  void paint(Canvas canvas, Size size) {
    if (t <= 0 || t >= 1) return;
    // Siempre la misma "lluvia" (números fijos): no salta al repintar.
    final math.Random r = math.Random(7);
    final Paint paint = Paint();
    for (int i = 0; i < 40; i++) {
      final double x = r.nextDouble() * size.width;
      final double drift = (r.nextDouble() - 0.5) * 120;
      final double delay = r.nextDouble() * 0.4;
      final double p = ((t - delay) / (1 - delay)).clamp(0.0, 1.0);
      if (p <= 0) continue;
      final double y = -20 + p * (size.height + 40);
      paint.color = _colors[i % _colors.length].withValues(alpha: 1 - p * 0.6);
      canvas
        ..save()
        ..translate(x + drift * p, y)
        ..rotate(p * 8 + i);
      canvas
        ..drawRect(const Rect.fromLTWH(-4, -6, 8, 12), paint)
        ..restore();
    }
  }

  @override
  bool shouldRepaint(_Confetti old) => old.t != t;
}
