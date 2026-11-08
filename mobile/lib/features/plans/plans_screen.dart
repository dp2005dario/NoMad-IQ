// Elegid planes: la maqueta "Planes" tal cual (assets/plans/planes.html,
// dentro de un WebView). Cada uno, desde su móvil, desliza las tarjetas de
// planes del viaje en grupo: a la derecha "me apetece", a la izquierda
// "paso". Los votos son SECRETOS: nadie ve qué has marcado hasta que
// coincidís. Cuando dos o más dicen que sí a un sitio sale "¡MATCH
// VIAJERO!" a pantalla completa, y "Añadir al plan" lo mete en el plan del
// grupo (y avisa a todos por el chat del viaje).
//
// De dónde salen los planes (0 €): los que añade el grupo desde Grupo y
// Eventos y, si aún no hay ninguno, las atracciones de la ficha de la
// ciudad (GET /v1/places/{IATA}, Wikidata), que se añaden solas.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';

import '../../core/api_client.dart';
import '../../core/services.dart';
import '../../core/settings.dart';
import '../../l10n/generated/app_localizations.dart';
import '../flights/flights_page.dart' show unpackJson;
import '../route/places_api.dart';
import '../route/web_scene.dart';
import 'plans_api.dart';
import 'plans_page.dart';

class PlansScreen extends StatefulWidget {
  const PlansScreen({super.key, required this.tripId, this.city, this.iata});

  final String tripId;

  /// El destino que eligió el grupo ("Lisboa"), para el subtítulo.
  final String? city;

  /// Su aeropuerto (para las ideas de la ciudad, si aún no hay planes).
  final String? iata;

  /// El puente de la última pantalla abierta (lo miran los tests).
  static WebSceneBridge? lastBridge;

  @override
  State<PlansScreen> createState() => _PlansScreenState();
}

class _PlansScreenState extends State<PlansScreen> {
  late final AppServices _services = ServicesScope.of(context);
  final WebSceneBridge _bridge = PlansScreen.lastBridge = WebSceneBridge();

  /// La página se lee una vez (se guarda el texto, no la espera).
  static String? _pageCache;
  String? _html;
  String? _sent;
  bool _started = false;

  PlanBoard? _board;
  ApiError? _error;

  /// "Volver a empezar": vuelven todas las tarjetas (tu voto nuevo
  /// sustituye al anterior).
  bool _again = false;
  final Set<String> _revoted = <String>{};

  /// Lo que la página debe enseñar una vez (un match o un aviso).
  Map<String, Object?> _once = <String, Object?>{};

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    unawaited(_start());
  }

  Future<void> _start() async {
    try {
      _pageCache ??= await rootBundle.loadString(plansPage, cache: false);
    } on Object {
      return;
    }
    if (mounted) setState(() {});
    await _load();
  }

  Future<void> _load() async {
    try {
      PlanBoard b = await _services.plans.board(widget.tripId);
      if (b.plans.isEmpty) b = await _seed() ?? b;
      if (mounted) setState(() => (_board = b, _error = null));
      if (mounted) await _celebrateNew();
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.error);
    }
  }

  /// Sin planes: las atracciones de la ficha de la ciudad (hasta 8).
  Future<PlanBoard?> _seed() async {
    final String? iata = widget.iata;
    if (iata == null || iata.isEmpty) return null;
    final String lang = Localizations.localeOf(context).languageCode;
    try {
      final PlaceCard? card = await _services.places.get(iata, lang);
      final List<NewPlan> ideas = <NewPlan>[
        for (final Attraction a
            in card?.attractions ?? const <Attraction>[].take(maxPlansPerAdd))
          NewPlan(
            title: a.name,
            note: a.description,
            photoUrl: a.photo?.url,
            articleUrl: a.articleUrl,
            wikidataId: a.wikidataId,
          ),
      ];
      if (ideas.isEmpty) return null;
      return await _services.plans.add(widget.tripId, ideas);
    } on ApiException {
      return null;
    }
  }

  void _say(String text) =>
      setState(() => _once = <String, Object?>{..._once, 'toast': text});

  Future<PlanBoard?> _run(Future<PlanBoard> Function() call) async {
    try {
      final PlanBoard b = await call();
      if (mounted) setState(() => _board = b);
      return b;
    } on ApiException catch (e) {
      if (!mounted) return null;
      final AppLocalizations t = AppLocalizations.of(context);
      _say(switch (e.error) {
        ApiError.network => t.errorNetwork,
        ApiError.conflict => t.plansTooMany,
        _ => t.errorUnavailable,
      });
      return null;
    }
  }

  GroupPlan? _plan(String? id) =>
      _board?.plans.where((GroupPlan p) => p.id == id).firstOrNull;

  Future<void> _vote(String id, bool yes) async {
    final AppLocalizations t = AppLocalizations.of(context);
    if (_again) _revoted.add(id);
    final PlanBoard? b = await _run(
      () => _services.plans.vote(widget.tripId, id, yes: yes),
    );
    if (b == null || !mounted || !yes) return;
    final GroupPlan? now = _plan(id);
    if (now != null && now.myMatch && !now.planned) {
      await _celebrate(now);
    } else if (now != null) {
      _say(t.plansSavedSecret);
    }
  }

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

  /// "¡MATCH VIAJERO!" a pantalla completa (lo dibuja la página).
  Future<void> _celebrate(GroupPlan plan) async {
    await _markSeen(plan);
    unawaited(HapticFeedback.heavyImpact());
    if (!mounted) return;
    final List<GroupPlan> plans = _board?.plans ?? const <GroupPlan>[];
    setState(
      () => _once = <String, Object?>{
        ..._once,
        'match': planJson(plan, plans.indexOf(plan), city: widget.city),
      },
    );
  }

  /// "Añadir al plan": se apunta en el servidor y se avisa al grupo con un
  /// mensaje en el chat del viaje (a los demás les llega la notificación).
  Future<void> _addToPlan(String id) async {
    final AppLocalizations t = AppLocalizations.of(context);
    final String lang = Localizations.localeOf(context).languageCode;
    await _run(() => _services.plans.addToPlan(widget.tripId, id));
    final GroupPlan? plan = _plan(id);
    if (plan == null || !plan.planned || !mounted) return;
    try {
      await _services.groupChat.send(
        widget.tripId,
        t.plansChatAdded(plan.title),
        lang,
      );
    } on ApiException {
      // Ya está en el plan; si el aviso del chat falla, no pasa nada grave.
    }
  }

  /// Lo que pide la página.
  void _onMessage(String m) {
    final List<String> p = m.split(':');
    final int? n = p.length > 1 ? int.tryParse(p[1]) : null;
    final Map<String, Object?>? data = p.length == 3 ? unpackJson(p[2]) : null;
    final String? id = data?['id'] as String?;
    switch (p.first) {
      case 'back':
        if (context.canPop()) context.pop();
      case 'vote' when id != null && n != null:
        unawaited(_vote(id, n == 1));
      case 'addplan' when id != null:
        unawaited(_addToPlan(id));
      case 'again':
        setState(() {
          _again = true;
          _revoted.clear();
        });
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
    final Map<String, Object?> data = plansPageData(
      city: widget.city,
      board: _board,
      failed: _error != null && _error != ApiError.signedOut,
      signedOut: _error == ApiError.signedOut,
      again: _again,
      revoted: _revoted,
    );
    final Map<String, Object?> once = _once;
    final String push = plansPushScript(<String, Object?>{...data, ...once});
    if (_html == null) {
      _html = plansPageWith(page, <String, Object?>{...data, ...once});
      _sent = push;
      _once = <String, Object?>{};
    } else if (push != _sent) {
      _sent = push;
      _once = <String, Object?>{};
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
