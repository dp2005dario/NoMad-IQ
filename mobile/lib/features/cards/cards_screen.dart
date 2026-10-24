// Cromos con amigos (maqueta "Cromos"): tres pestañas sobre una liga de
// amigos.
//   - Cambiar: le ofreces a un amigo un cromo tuyo que no tiene por uno suyo
//     que te falta. Si acepta, los dos recibís una copia.
//   - Liga: la clasificación del mes con los cromos nuevos.
//   - Amigos: en qué ciudad está cada uno (solo quien lo activa, y nunca
//     más exacto que la ciudad).
//
// Al abrir la liga se suben tus cromos (los sellos del Pasaporte: monumento,
// año y mes). Solo los ve la gente de la liga, y la pantalla lo dice antes
// de crear o entrar en una.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/api_client.dart';
import '../../core/services.dart';
import '../../core/theme.dart';
import '../../l10n/generated/app_localizations.dart';
import '../camera/stamps.dart';
import '../map/geo.dart';
import '../map/location.dart';
import '../passport/passport.dart';
import '../route/flight3d.dart' show CountryCodes;
import '../route/world_data.dart';
import '../sos/where_am_i.dart';
import 'league_api.dart';

/// Los puntos de cada cromo (los mismos que el servidor).
int cardPoints(int? year) => switch (rarityOf(year)) {
  Rarity.legendary => 150,
  Rarity.epic => 80,
  Rarity.rare => 40,
  Rarity.common => 10,
};

/// Cuántos países distintos hay en tus sellos (el país sale del aeropuerto
/// más cercano, como en el Pasaporte).
Future<int> countriesOf(List<Stamp> stamps) async {
  try {
    final WorldData world = await WorldData.load();
    final CountryCodes codes = await CountryCodes.load();
    return pagesOf(
      stamps,
      airports: world.airports.all,
      codes: codes,
    ).where((PassportPage p) => p.country != null).length;
  } on Object {
    return 0;
  }
}

class CardsScreen extends StatefulWidget {
  const CardsScreen({super.key, this.locate = whereabouts});

  /// Ciudad de un punto (en los tests, una fija).
  final Future<Whereabouts> Function(GeoPoint) locate;

  @override
  State<CardsScreen> createState() => _CardsScreenState();
}

class _CardsScreenState extends State<CardsScreen> {
  late final AppServices _services = ServicesScope.of(context);
  late final LeagueApi _api = _services.leagues;
  late final List<Stamp> _stamps = StampBook(_services.prefs).all();

  Future<int>? _countries;
  List<LeagueSummary>? _leagues;
  LeagueView? _league;
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    // Después del primer dibujo: _load usa los textos del idioma.
    WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_load()));
  }

  String _errorText(AppLocalizations t, Object e) => switch (e) {
    ApiException(error: ApiError.network) => t.cardsOffline,
    ApiException(error: ApiError.notFound) => t.cardsNotFound,
    ApiException(error: ApiError.conflict) => t.cardsConflict,
    _ => t.cardsFailed,
  };

  Future<void> _guard(Future<void> Function() work) async {
    final AppLocalizations t = AppLocalizations.of(context);
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await work();
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = _errorText(t, e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _load([String? id]) => _guard(() async {
    final List<LeagueSummary> all = await _api.list();
    final String? pick = id ?? _league?.id ?? all.firstOrNull?.id;
    LeagueView? league;
    if (pick != null) {
      // Primero se suben tus cromos, para que la clasificación esté al día.
      await _api.upload(
        pick,
        _stamps.map(LeagueCard.ofStamp).toList(),
        // Los países salen de los datos del mundo (dentro de la app); si
        // tardan, se sube 0 y se corrige la próxima vez.
        countries: await (_countries ??= countriesOf(
          _stamps,
        )).timeout(const Duration(seconds: 2), onTimeout: () => 0),
      );
      league = await _api.get(pick);
    }
    if (!mounted) return;
    setState(() {
      _leagues = all;
      _league = league;
    });
  });

  Future<void> _createOrJoin({required bool join}) async {
    final ({String name, String text})? got =
        await showModalBottomSheet<({String name, String text})>(
          context: context,
          isScrollControlled: true,
          useRootNavigator: true,
          builder: (BuildContext context) => _JoinSheet(
            join: join,
            name: _services.prefs.readGroupName() ?? '',
          ),
        );
    if (got == null || !mounted) return;
    await _services.prefs.writeGroupName(got.name);
    await _guard(() async {
      final LeagueView league = join
          ? await _api.join(got.text, myName: got.name)
          : await _api.create(title: got.text, myName: got.name);
      _league = league;
    });
    if (mounted && _error == null) await _load(_league?.id);
  }

  Future<void> _leave(LeagueView league) async {
    await _guard(() => _api.leave(league.id));
    if (!mounted) return;
    setState(() => _league = null);
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    final LeagueView? league = _league;
    final List<LeagueSummary>? leagues = _leagues;
    if (leagues == null) {
      return Scaffold(
        appBar: AppBar(title: Text(t.cardsTitle)),
        body: Center(
          child: _error == null
              ? const CircularProgressIndicator()
              : Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Text(_error!, textAlign: TextAlign.center),
                      const SizedBox(height: 12),
                      FilledButton(
                        onPressed: () => unawaited(_load()),
                        child: Text(t.cardsRetry),
                      ),
                    ],
                  ),
                ),
        ),
      );
    }
    if (league == null) {
      return Scaffold(
        appBar: AppBar(title: Text(t.cardsTitle)),
        body: _NoLeague(
          busy: _busy,
          error: _error,
          onCreate: () => unawaited(_createOrJoin(join: false)),
          onJoin: () => unawaited(_createOrJoin(join: true)),
        ),
      );
    }
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          title: Text(t.cardsTitle),
          actions: <Widget>[
            PopupMenuButton<String>(
              onSelected: (String v) {
                switch (v) {
                  case 'create':
                    unawaited(_createOrJoin(join: false));
                  case 'join':
                    unawaited(_createOrJoin(join: true));
                  case 'leave':
                    unawaited(_leave(league));
                  default:
                    unawaited(_load(v));
                }
              },
              itemBuilder: (BuildContext context) => <PopupMenuEntry<String>>[
                for (final LeagueSummary l in leagues)
                  if (l.id != league.id)
                    PopupMenuItem<String>(value: l.id, child: Text(l.title)),
                PopupMenuItem<String>(
                  value: 'create',
                  child: Text(t.cardsCreate),
                ),
                PopupMenuItem<String>(value: 'join', child: Text(t.cardsJoin)),
                PopupMenuItem<String>(
                  value: 'leave',
                  child: Text(t.cardsLeave),
                ),
              ],
            ),
          ],
          bottom: TabBar(
            tabs: <Widget>[
              Tab(text: t.cardsTabSwap),
              Tab(text: t.cardsTabLeague),
              Tab(text: t.cardsTabFriends),
            ],
          ),
        ),
        body: Column(
          children: <Widget>[
            if (_busy) const LinearProgressIndicator(),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.all(12),
                child: Text(
                  _error!,
                  style: const TextStyle(color: NomadColors.safety),
                ),
              ),
            Expanded(
              child: TabBarView(
                children: <Widget>[
                  _SwapTab(
                    league: league,
                    stamps: _stamps,
                    api: _api,
                    guard: _guard,
                    reload: () => _load(league.id),
                  ),
                  _LeagueTab(league: league),
                  _FriendsTab(
                    league: league,
                    guard: _guard,
                    reload: () => _load(league.id),
                    findCity: _findCity,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// La ciudad del aeropuerto más cercano a donde estás (o null).
  Future<String?> _findCity() async {
    final LocationSource gps = _services.location;
    try {
      LocationAccess access = await gps.check();
      if (access == LocationAccess.denied) access = await gps.request();
      if (access != LocationAccess.granted) return null;
      final PositionFix fix = await gps.watch().first.timeout(
        const Duration(seconds: 15),
      );
      return (await widget.locate(fix.point)).city;
    } on Object {
      return null;
    }
  }
}

class _NoLeague extends StatelessWidget {
  const _NoLeague({
    required this.busy,
    required this.error,
    required this.onCreate,
    required this.onJoin,
  });

  final bool busy;
  final String? error;
  final VoidCallback onCreate;
  final VoidCallback onJoin;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    final TextTheme text = Theme.of(context).textTheme;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: <Widget>[
        Text(t.cardsSubtitle, style: text.titleMedium),
        const SizedBox(height: 8),
        Text(t.cardsHow),
        const SizedBox(height: 24),
        FilledButton(
          onPressed: busy ? null : onCreate,
          child: Text(t.cardsCreate),
        ),
        const SizedBox(height: 12),
        OutlinedButton(
          onPressed: busy ? null : onJoin,
          child: Text(t.cardsJoin),
        ),
        if (error != null) ...<Widget>[
          const SizedBox(height: 12),
          Text(error!, style: const TextStyle(color: NomadColors.safety)),
        ],
        const SizedBox(height: 24),
        Text(
          t.cardsPrivacy,
          style: text.bodySmall?.copyWith(color: NomadColors.textMuted),
        ),
      ],
    );
  }
}

class _JoinSheet extends StatefulWidget {
  const _JoinSheet({required this.join, required this.name});

  final bool join;
  final String name;

  @override
  State<_JoinSheet> createState() => _JoinSheetState();
}

class _JoinSheetState extends State<_JoinSheet> {
  late final TextEditingController _name = TextEditingController(
    text: widget.name,
  );
  final TextEditingController _text = TextEditingController();

  @override
  void dispose() {
    _name.dispose();
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(
        16,
        16,
        16,
        16 + MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          TextField(
            controller: _text,
            maxLength: widget.join ? 12 : 40,
            textCapitalization: widget.join
                ? TextCapitalization.characters
                : TextCapitalization.sentences,
            decoration: InputDecoration(
              labelText: widget.join ? t.cardsCodeLabel : t.cardsLeagueName,
            ),
          ),
          TextField(
            controller: _name,
            maxLength: 40,
            decoration: InputDecoration(labelText: t.cardsMyName),
          ),
          const SizedBox(height: 8),
          Text(
            t.cardsPrivacy,
            style: Theme.of(context).textTheme.bodySmall
                ?.copyWith(color: NomadColors.textMuted),
          ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: () {
              final String name = _name.text.trim();
              final String text = _text.text.trim();
              if (name.isEmpty || text.isEmpty) return;
              Navigator.of(context).pop((name: name, text: text));
            },
            child: Text(widget.join ? t.cardsJoin : t.cardsCreate),
          ),
        ],
      ),
    );
  }
}

// --- Cambiar -------------------------------------------------------------------

class _SwapTab extends StatefulWidget {
  const _SwapTab({
    required this.league,
    required this.stamps,
    required this.api,
    required this.guard,
    required this.reload,
  });

  final LeagueView league;
  final List<Stamp> stamps;
  final LeagueApi api;
  final Future<void> Function(Future<void> Function()) guard;
  final Future<void> Function() reload;

  @override
  State<_SwapTab> createState() => _SwapTabState();
}

class _SwapTabState extends State<_SwapTab> {
  int? _friend;
  List<LeagueCard>? _theirs;
  String? _want;
  String? _give;

  Set<String> get _mine => <String>{
    for (final Stamp s in widget.stamps) s.qid,
    for (final LeagueCard c in widget.league.received) c.qid,
  };

  Future<void> _pickFriend(int seat) async {
    setState(() {
      _friend = seat;
      _theirs = null;
      _want = null;
      _give = null;
    });
    await widget.guard(() async {
      final List<LeagueCard> cards = await widget.api.cardsOf(
        widget.league.id,
        seat,
      );
      if (mounted && _friend == seat) setState(() => _theirs = cards);
    });
  }

  Future<void> _propose() async {
    final int? to = _friend;
    final String? give = _give;
    final String? want = _want;
    if (to == null || give == null || want == null) return;
    final AppLocalizations t = AppLocalizations.of(context);
    await widget.guard(
      () => widget.api.propose(
        widget.league.id,
        toSeat: to,
        giveQid: give,
        wantQid: want,
      ),
    );
    if (!mounted) return;
    setState(() {
      _want = null;
      _give = null;
    });
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(t.cardsOfferSent)));
    await widget.reload();
  }

  Future<void> _decide(LeagueSwap s, {required bool accept}) async {
    await widget.guard(
      () => widget.api.decide(widget.league.id, s.id, accept: accept),
    );
    await widget.reload();
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    final TextTheme text = Theme.of(context).textTheme;
    final LeagueView league = widget.league;
    final List<LeagueSwap> incoming = <LeagueSwap>[
      for (final LeagueSwap s in league.swaps)
        if (s.status == SwapStatus.pending && s.toSeat == league.mySeat) s,
    ];
    final List<LeagueSwap> outgoing = <LeagueSwap>[
      for (final LeagueSwap s in league.swaps)
        if (s.status == SwapStatus.pending && s.fromSeat == league.mySeat) s,
    ];
    final Set<String> mine = _mine;
    final List<LeagueCard>? theirs = _theirs;
    final Set<String> theirQids = <String>{
      for (final LeagueCard c in theirs ?? const <LeagueCard>[]) c.qid,
    };
    final List<LeagueCard> canWant = <LeagueCard>[
      for (final LeagueCard c in theirs ?? const <LeagueCard>[])
        if (!mine.contains(c.qid)) c,
    ];
    final List<Stamp> canGive = <Stamp>[
      for (final Stamp s in widget.stamps)
        if (!theirQids.contains(s.qid)) s,
    ];
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
      children: <Widget>[
        for (final LeagueSwap s in incoming)
          Card(
            color: NomadColors.group.withValues(alpha: 0.12),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    t.cardsIncoming(
                      league.nameOf(s.fromSeat),
                      s.give.name,
                      s.want.name,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: <Widget>[
                      Expanded(
                        child: OutlinedButton(
                          onPressed: () => unawaited(_decide(s, accept: false)),
                          child: Text(t.cardsDecline),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: FilledButton(
                          onPressed: () => unawaited(_decide(s, accept: true)),
                          child: Text(t.cardsAccept),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        for (final LeagueSwap s in outgoing)
          ListTile(
            leading: const Icon(Icons.hourglass_top_rounded),
            title: Text(
              t.cardsOutgoing(
                league.nameOf(s.toSeat),
                s.give.name,
                s.want.name,
              ),
            ),
          ),
        Text(t.cardsProposeTitle, style: text.titleMedium),
        const SizedBox(height: 4),
        Text(
          t.cardsSwapRule,
          style: text.bodySmall?.copyWith(color: NomadColors.textMuted),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: <Widget>[
            for (final Standing s in league.standings)
              if (!s.me)
                ChoiceChip(
                  label: Text(s.name),
                  selected: _friend == s.seat,
                  onSelected: (_) => unawaited(_pickFriend(s.seat)),
                ),
          ],
        ),
        if (league.standings.length < 2)
          Text(
            t.cardsInviteFirst(league.inviteCode),
            style: const TextStyle(color: NomadColors.textMuted),
          ),
        if (_friend != null && theirs != null) ...<Widget>[
          const SizedBox(height: 16),
          Text(t.cardsYouWant, style: text.labelLarge),
          if (canWant.isEmpty)
            Text(
              t.cardsNothingToWant,
              style: const TextStyle(color: NomadColors.textMuted),
            ),
          for (final LeagueCard c in canWant)
            _CardPick(
              name: c.name,
              year: c.year,
              selected: _want == c.qid,
              onTap: () => setState(() => _want = c.qid),
            ),
          const SizedBox(height: 16),
          Text(t.cardsYouGive, style: text.labelLarge),
          if (canGive.isEmpty)
            Text(
              t.cardsNothingToGive,
              style: const TextStyle(color: NomadColors.textMuted),
            ),
          for (final Stamp s in canGive)
            _CardPick(
              name: s.name,
              year: s.year,
              selected: _give == s.qid,
              onTap: () => setState(() => _give = s.qid),
            ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: _want != null && _give != null
                ? () => unawaited(_propose())
                : null,
            child: Text(t.cardsSendOffer),
          ),
        ],
        if (league.received.isNotEmpty) ...<Widget>[
          const SizedBox(height: 24),
          Text(t.cardsReceived, style: text.labelLarge),
          for (final LeagueCard c in league.received)
            ListTile(
              dense: true,
              leading: const Icon(Icons.card_giftcard_rounded),
              title: Text(c.name),
            ),
        ],
      ],
    );
  }
}

class _CardPick extends StatelessWidget {
  const _CardPick({
    required this.name,
    required this.year,
    required this.selected,
    required this.onTap,
  });

  final String name;
  final int? year;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    final Rarity r = rarityOf(year);
    final Color color = switch (r) {
      Rarity.legendary => const Color(0xFFFFD36B),
      Rarity.epic => NomadColors.group,
      Rarity.rare => NomadColors.flights,
      Rarity.common => NomadColors.textMuted,
    };
    return Card(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(
          color: selected ? NomadColors.mint : NomadColors.outline,
          width: selected ? 2 : 1,
        ),
      ),
      child: ListTile(
        onTap: onTap,
        leading: Icon(Icons.style_rounded, color: color),
        title: Text(name),
        subtitle: Text(
          t.cardsRarity(switch (r) {
            Rarity.legendary => 'legendary',
            Rarity.epic => 'epic',
            Rarity.rare => 'rare',
            Rarity.common => 'common',
          }, cardPoints(year)),
        ),
        trailing: selected
            ? const Icon(Icons.check_circle_rounded, color: NomadColors.mint)
            : null,
      ),
    );
  }
}

// --- Liga ----------------------------------------------------------------------

class _LeagueTab extends StatelessWidget {
  const _LeagueTab({required this.league});

  final LeagueView league;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    final TextTheme text = Theme.of(context).textTheme;
    final int pos = league.myPosition;
    final Standing? me = league.me;
    final Standing? ahead = pos > 1 ? league.standings[pos - 2] : null;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(
              child: Text(
                league.title.toUpperCase(),
                style: text.labelLarge?.copyWith(color: NomadColors.textMuted),
              ),
            ),
            IconButton(
              tooltip: t.cardsCopyCode,
              icon: const Icon(Icons.copy_rounded),
              onPressed: () => unawaited(
                Clipboard.setData(ClipboardData(text: league.inviteCode)),
              ),
            ),
          ],
        ),
        Text(
          t.cardsPosition(pos, league.standings.length),
          style: text.headlineSmall,
        ),
        if (ahead != null && me != null)
          Text(
            t.cardsBehind(ahead.pointsMonth - me.pointsMonth, ahead.name),
            style: const TextStyle(color: NomadColors.textMuted),
          ),
        const SizedBox(height: 16),
        for (int i = 0; i < league.standings.length; i++)
          _StandingRow(position: i + 1, s: league.standings[i]),
        const SizedBox(height: 12),
        Text(
          t.cardsPointsRule,
          style: text.bodySmall?.copyWith(color: NomadColors.textMuted),
        ),
        const SizedBox(height: 8),
        Text(
          t.cardsInviteCode(league.inviteCode),
          style: text.bodySmall?.copyWith(color: NomadColors.textMuted),
        ),
      ],
    );
  }
}

class _StandingRow extends StatelessWidget {
  const _StandingRow({required this.position, required this.s});

  final int position;
  final Standing s;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    final Color medal = switch (position) {
      1 => const Color(0xFFFFD36B),
      2 => const Color(0xFFC9D3D8),
      3 => const Color(0xFFE0A070),
      _ => NomadColors.textMuted,
    };
    return Card(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: s.me ? NomadColors.mint : NomadColors.outline),
      ),
      child: ListTile(
        leading: Text(
          '$position',
          style: TextStyle(
            color: medal,
            fontSize: 16,
            fontWeight: FontWeight.w800,
          ),
        ),
        title: Text(s.me ? t.cardsYou : s.name),
        subtitle: Text(t.cardsMeta(s.countries, s.legendary)),
        trailing: Text(
          t.cardsPoints(s.pointsMonth),
          style: const TextStyle(fontWeight: FontWeight.w800),
        ),
      ),
    );
  }
}

// --- Amigos --------------------------------------------------------------------

class _FriendsTab extends StatefulWidget {
  const _FriendsTab({
    required this.league,
    required this.guard,
    required this.reload,
    required this.findCity,
  });

  final LeagueView league;
  final Future<void> Function(Future<void> Function()) guard;
  final Future<void> Function() reload;
  final Future<String?> Function() findCity;

  @override
  State<_FriendsTab> createState() => _FriendsTabState();
}

class _FriendsTabState extends State<_FriendsTab> {
  late final LeagueApi _api = ServicesScope.of(context).leagues;
  bool _locating = false;

  Future<void> _toggle(bool on) async {
    final AppLocalizations t = AppLocalizations.of(context);
    String? city;
    if (on) {
      setState(() => _locating = true);
      city = await widget.findCity();
      if (!mounted) return;
      setState(() => _locating = false);
      if (city == null) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(t.cardsNoCity)));
        return;
      }
    }
    await widget.guard(() => _api.setCity(widget.league.id, city));
    await widget.reload();
  }

  String _ago(AppLocalizations t, DateTime? at) {
    if (at == null) return '';
    final Duration d = DateTime.now().difference(at);
    if (d.inMinutes < 60) return t.cardsAgoMinutes(d.inMinutes.clamp(1, 59));
    if (d.inHours < 24) return t.cardsAgoHours(d.inHours);
    return t.cardsAgoDays(d.inDays);
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    final TextTheme text = Theme.of(context).textTheme;
    final Standing? me = widget.league.me;
    final bool sharing = me?.city != null;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
      children: <Widget>[
        SwitchListTile(
          value: sharing,
          onChanged: _locating ? null : (bool v) => unawaited(_toggle(v)),
          title: Text(t.cardsShareCity),
          subtitle: Text(
            sharing ? t.cardsSharingCity(me!.city!) : t.cardsShareCityWhy,
          ),
          contentPadding: EdgeInsets.zero,
        ),
        if (_locating) const LinearProgressIndicator(),
        const SizedBox(height: 12),
        for (final Standing s in widget.league.standings)
          if (!s.me)
            Card(
              child: ListTile(
                leading: CircleAvatar(
                  backgroundColor: NomadColors.group,
                  child: Text(
                    s.name.isEmpty ? '?' : s.name.characters.first,
                    style: const TextStyle(color: NomadColors.background),
                  ),
                ),
                title: Text(s.name),
                subtitle: Text(
                  s.city == null
                      ? t.cardsNoShare
                      : '${s.city} · ${_ago(t, s.cityAt)}',
                ),
              ),
            ),
        const SizedBox(height: 12),
        Text(
          t.cardsFriendsPrivacy,
          style: text.bodySmall?.copyWith(color: NomadColors.textMuted),
        ),
      ],
    );
  }
}
