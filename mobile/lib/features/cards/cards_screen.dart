// Cromos con amigos: la maqueta "Cromos" tal cual (assets/cards/cromos.html,
// dentro de un WebView) con tu liga de verdad. Tres pestañas:
//   - Cambiar: los cambios que te ofrecen (aceptar, con 30 s para
//     deshacer, o "No, gracias"), los que esperan respuesta y los que puedes
//     proponer: un cromo de un amigo que te falta por uno tuyo que no tiene.
//     Si acepta, los dos os quedáis una copia.
//   - Liga: la clasificación del mes con los cromos nuevos. Tocar el
//     cartel abre las opciones (invitar, otra liga, crear, entrar, salir).
//   - Amigos: en qué ciudad está cada uno (solo quien lo activa, y nunca
//     más exacto que la ciudad).
//
// Al abrir la liga se suben tus cromos (los sellos del Pasaporte: monumento,
// año y mes). Solo los ve la gente de la liga, y la pantalla lo dice antes
// de crear o entrar en una.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';

import '../../core/api_client.dart';
import '../../core/services.dart';
import '../../core/theme.dart';
import '../../l10n/generated/app_localizations.dart';
import '../camera/stamps.dart';
import '../map/geo.dart';
import '../map/location.dart';
import '../passport/passport.dart';
import '../route/flight3d.dart' show CountryCodes;
import '../route/web_scene.dart';
import '../route/world_data.dart';
import '../sos/where_am_i.dart';
import 'cards_page.dart';
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

  /// El puente de la última pantalla abierta (lo miran los tests).
  static WebSceneBridge? lastBridge;

  /// Cuánto se puede deshacer un cambio aceptado.
  static Duration undoTime = const Duration(seconds: 30);

  @override
  State<CardsScreen> createState() => _CardsScreenState();
}

class _CardsScreenState extends State<CardsScreen> {
  late final AppServices _services = ServicesScope.of(context);
  late final LeagueApi _api = _services.leagues;
  late final List<Stamp> _stamps = StampBook(_services.prefs).all();
  final WebSceneBridge _bridge = CardsScreen.lastBridge = WebSceneBridge();

  /// La página se lee una vez (se guarda el texto, no la espera).
  static String? _pageCache;
  String? _html;
  String? _sent;

  Future<int>? _countries;
  List<LeagueSummary>? _leagues;
  LeagueView? _league;
  Map<int, List<LeagueCard>> _friendCards = <int, List<LeagueCard>>{};
  String? _error;
  bool _busy = false;

  /// Lo que estás viendo en "Cambiar" (el mismo orden que la página).
  List<SwapItem> _items = const <SwapItem>[];

  /// El cambio aceptado que aún se puede deshacer.
  Timer? _undo;

  @override
  void initState() {
    super.initState();
    // Después del primer dibujo: _load usa los textos del idioma.
    WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_start()));
  }

  Future<void> _start() async {
    try {
      _pageCache ??= await rootBundle.loadString(cardsPage, cache: false);
    } on Object {
      return;
    }
    if (!mounted) return;
    setState(() {});
    await _load();
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
      _toast(_errorText(t, e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _toast(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _load([String? id]) => _guard(() async {
    final List<LeagueSummary> all = await _api.list();
    final String? pick = id ?? _league?.id ?? all.firstOrNull?.id;
    LeagueView? league;
    final Map<int, List<LeagueCard>> cards = <int, List<LeagueCard>>{};
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
      // Los cromos de cada amigo (para saber qué te falta y qué cambiar).
      await Future.wait(<Future<void>>[
        for (final Standing s in league.standings)
          if (!s.me)
            _api
                .cardsOf(pick, s.seat)
                .then((List<LeagueCard> c) => cards[s.seat] = c)
                .catchError((Object _) => const <LeagueCard>[]),
      ]);
    }
    if (!mounted) return;
    setState(() {
      _leagues = all;
      _league = league;
      _friendCards = cards;
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

  /// "Invitar": el código de la liga, copiado para mandarlo.
  Future<void> _invite() async {
    final LeagueView? league = _league;
    if (league == null) return;
    final AppLocalizations t = AppLocalizations.of(context);
    await Clipboard.setData(ClipboardData(text: league.inviteCode));
    _toast('${t.cardsInviteCode(league.inviteCode)} ✓');
  }

  /// Tocar el cartel de la liga: invitar, otra liga, crear, entrar o salir.
  Future<void> _leagueMenu() async {
    final LeagueView? league = _league;
    final AppLocalizations t = AppLocalizations.of(context);
    final String? v = await showModalBottomSheet<String>(
      context: context,
      useRootNavigator: true,
      builder: (BuildContext context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            if (league != null)
              ListTile(
                leading: const Icon(Icons.copy_rounded),
                title: Text(t.cardsCopyCode),
                subtitle: Text(league.inviteCode),
                onTap: () => Navigator.pop(context, 'invite'),
              ),
            for (final LeagueSummary l in _leagues ?? const <LeagueSummary>[])
              if (l.id != league?.id)
                ListTile(
                  leading: const Icon(Icons.emoji_events_rounded),
                  title: Text(l.title),
                  onTap: () => Navigator.pop(context, l.id),
                ),
            ListTile(
              leading: const Icon(Icons.add_rounded),
              title: Text(t.cardsCreate),
              onTap: () => Navigator.pop(context, 'create'),
            ),
            ListTile(
              leading: const Icon(Icons.login_rounded),
              title: Text(t.cardsJoin),
              onTap: () => Navigator.pop(context, 'join'),
            ),
            if (league != null)
              ListTile(
                leading: const Icon(
                  Icons.logout_rounded,
                  color: NomadColors.safety,
                ),
                title: Text(t.cardsLeave),
                onTap: () => Navigator.pop(context, 'leave'),
              ),
          ],
        ),
      ),
    );
    if (v == null || !mounted) return;
    switch (v) {
      case 'invite':
        await _invite();
      case 'create':
        await _createOrJoin(join: false);
      case 'join':
        await _createOrJoin(join: true);
      case 'leave':
        if (league != null) await _leave(league);
      default:
        await _load(v);
    }
  }

  /// "Aceptar cambio": se manda pasados 30 s, por si lo deshaces. Si sales
  /// de la pantalla antes, se manda igual (lo aceptaste).
  void _accept(LeagueSwap s) {
    final LeagueView? league = _league;
    if (league == null) return;
    _undo?.cancel();
    _undo = Timer(CardsScreen.undoTime, () async {
      _undo = null;
      try {
        await _api.decide(league.id, s.id, accept: true);
      } on ApiException catch (e) {
        if (mounted) _toast(_errorText(AppLocalizations.of(context), e));
      }
      if (mounted) await _load(league.id);
    });
  }

  Future<void> _decline(LeagueSwap s) async {
    final LeagueView? league = _league;
    if (league == null) return;
    await _guard(() => _api.decide(league.id, s.id, accept: false));
    await _load(league.id);
  }

  Future<void> _offer(SwapItem i) async {
    final LeagueView? league = _league;
    if (league == null || i.toSeat == null) return;
    await _guard(
      () => _api.propose(
        league.id,
        toSeat: i.toSeat!,
        giveQid: i.give!.qid,
        wantQid: i.want!.qid,
      ),
    );
    if (!mounted || _error != null) return;
    _toast(AppLocalizations.of(context).cardsOfferSent);
    await _load(league.id);
  }

  /// "Compartir mi ciudad" (o dejar de hacerlo).
  Future<void> _share() async {
    final LeagueView? league = _league;
    if (league == null) return;
    String? city;
    if (league.me?.city == null) {
      city = await _findCity();
      if (!mounted) return;
      if (city == null) {
        _toast(AppLocalizations.of(context).cardsNoCity);
        return;
      }
    }
    await _guard(() => _api.setCity(league.id, city));
    await _load(league.id);
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

  /// Lo que pide la página.
  void _onMessage(String m) {
    final List<String> p = m.split(':');
    final int? n = p.length > 1 ? int.tryParse(p[1]) : null;
    final SwapItem? item = n != null && n < _items.length ? _items[n] : null;
    switch (p.first) {
      case 'back':
        if (context.canPop()) context.pop();
      case 'accept' when item?.swap != null:
        _accept(item!.swap!);
      case 'undo':
        _undo?.cancel();
        _undo = null;
      case 'decline' when item?.swap != null:
        unawaited(_decline(item!.swap!));
      case 'offer' when item != null:
        unawaited(_offer(item));
      case 'create':
        unawaited(_createOrJoin(join: false));
      case 'join':
        unawaited(_createOrJoin(join: true));
      case 'invite':
        unawaited(_invite());
      case 'league':
        unawaited(_leagueMenu());
      case 'share':
        unawaited(_share());
    }
  }

  @override
  Widget build(BuildContext context) {
    final String? page = _pageCache;
    if (page == null) {
      return const Scaffold(
        backgroundColor: Color(0xFF0B1217),
        body: SizedBox.expand(),
      );
    }
    _items = swapItems(
      league: _league,
      stamps: _stamps,
      friendCards: _friendCards,
    );
    final Map<String, Object?> data = cardsPageData(
      league: _league,
      stamps: _stamps,
      swaps: _items,
      friendCards: _friendCards,
      now: DateTime.now(),
      loading: _busy || _leagues == null,
      error: _error,
    );
    final String push = cardsPushScript(data);
    if (_html == null) {
      _html = cardsPageWith(page, data);
      _sent = push;
    } else if (push != _sent && _undo == null) {
      // Sin recargar (y sin cortar la cuenta atrás de "Deshacer").
      _sent = push;
      unawaited(_bridge.run(push));
    }
    final String html = _html!;
    return Scaffold(
      backgroundColor: const Color(0xFF0B1217),
      body: SafeArea(
        bottom: false,
        child:
            _services.webScene?.call(html, _onMessage) ??
            WebScene(html: html, onMessage: _onMessage, bridge: _bridge),
      ),
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
