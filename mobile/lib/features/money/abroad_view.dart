// "Tu dinero fuera": la maqueta "Dinero" tal cual (assets/money/dinero.html,
// dentro de un WebView) con tus datos de verdad.
//
// - Cajeros: los que tienes cerca según OpenStreetMap (con tu ubicación),
//   cuáles no cobran y el aviso de «cobrar en euros». "Abrir mapa 3D" abre
//   el mapa de cajeros de la app (atms_panel.dart).
// - Gastos: eliges el bote de tu viaje, tu límite y tus fechas (se guardan
//   en el móvil, ver trip_budget.dart) y la página cuenta TU parte de cada
//   gasto: lo que llevas, lo que puedes gastar al día y cómo acabas.
//   "Añadir a mano" apunta el gasto en ese bote, pagado por ti y solo para ti.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';

import '../../core/api_client.dart';
import '../../core/money.dart';
import '../../core/router.dart';
import '../../core/services.dart';
import '../../core/settings.dart';
import '../../l10n/generated/app_localizations.dart';
import '../flights/flights_page.dart' show unpackJson;
import '../map/geo.dart';
import '../map/location.dart';
import '../route/web_scene.dart';
import 'abroad_page.dart';
import 'atms_api.dart';
import 'atms_panel.dart';
import 'budget_panel.dart';
import 'expenses_api.dart';
import 'trip_budget.dart';

/// La pestaña con la que se abre.
enum AbroadPart { atms, budget }

class AbroadView extends StatefulWidget {
  const AbroadView({super.key, this.part = AbroadPart.atms, this.now});

  final AbroadPart part;

  /// "Hoy" (en los tests, un día fijo).
  final DateTime? now;

  /// El puente de la última pantalla abierta (lo miran los tests).
  static WebSceneBridge? lastBridge;

  @override
  State<AbroadView> createState() => _AbroadViewState();
}

class _AbroadViewState extends State<AbroadView> {
  late final AppServices _services = ServicesScope.of(context);
  final WebSceneBridge _bridge = AbroadView.lastBridge = WebSceneBridge();

  /// La página se lee una vez (se guarda el texto, no la espera).
  static String? _pageCache;
  String? _html;
  String? _sent;
  bool _started = false;

  // Cajeros.
  AtmPhase _atmPhase = AtmPhase.idle;
  LocationAccess? _access;
  GeoPoint? _me;
  List<Atm>? _atms;
  bool _atmsCached = false;

  // Gastos.
  late TripBudget? _budget = TripBudget.load(_services.prefs);
  List<ExpenseGroupSummary>? _pots;
  ExpenseGroup? _pot;
  ApiError? _error;

  DateTime get _now => widget.now ?? DateTime.now();

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    unawaited(_start());
  }

  Future<void> _start() async {
    try {
      _pageCache ??= await rootBundle.loadString(abroadPage, cache: false);
    } on Object {
      return;
    }
    if (mounted) setState(() {});
    unawaited(_load());
    // Los cajeros se buscan solos: si aún no diste permiso de ubicación,
    // sale la pregunta del móvil nada más entrar (sin tener que tocar nada).
    if (widget.part != AbroadPart.budget) await _searchAtms();
  }

  // --- Cajeros -------------------------------------------------------------

  Future<GeoPoint?> _position() async {
    final LocationSource gps = _services.location;
    LocationAccess access = await gps.check();
    if (access == LocationAccess.denied) access = await gps.request();
    _access = access;
    if (access != LocationAccess.granted) return null;
    try {
      final PositionFix fix = await positionNow(
        gps,
        wait: const Duration(seconds: 15),
      );
      return fix.point;
    } on TimeoutException {
      return null;
    } on StateError {
      return null;
    }
  }

  Future<void> _searchAtms() async {
    if (!mounted) return;
    // Dijiste "no volver a preguntar": el permiso solo se da en Ajustes.
    if (_atmPhase == AtmPhase.blocked) {
      await _services.location.openSettings();
      if (!mounted) return;
    }
    setState(() => _atmPhase = AtmPhase.searching);
    final GeoPoint? me = await _position();
    if (!mounted) return;
    if (me == null) {
      setState(
        () => _atmPhase = switch (_access) {
          LocationAccess.serviceOff => AtmPhase.gpsOff,
          LocationAccess.deniedForever => AtmPhase.blocked,
          _ => AtmPhase.noLocation,
        },
      );
      return;
    }
    try {
      final AtmList found = await _services.atms.near(me);
      await saveAtmCache(_services.prefs, me, found);
      if (!mounted) return;
      setState(() {
        _me = me;
        _atms = found.sortedFrom(me);
        _atmsCached = false;
        _atmPhase = AtmPhase.done;
      });
    } on ApiException {
      if (!mounted) return;
      // Sin servidor: los últimos guardados de esta zona, si los hay.
      final (AtmList, DateTime)? cached = readAtmCache(_services.prefs, me);
      setState(() {
        if (cached == null) {
          _atmPhase = AtmPhase.failed;
        } else {
          _me = me;
          _atms = cached.$1.sortedFrom(me);
          _atmsCached = true;
          _atmPhase = AtmPhase.done;
        }
      });
    }
  }

  void _openMap() => unawaited(
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (BuildContext context) => Scaffold(
          appBar: AppBar(title: Text(AppLocalizations.of(context).abroadAtms)),
          body: const AtmsPanel(),
        ),
      ),
    ),
  );

  // --- Gastos --------------------------------------------------------------

  Future<void> _load() async {
    try {
      final List<ExpenseGroupSummary> pots = await _services.expenses.list();
      final TripBudget? b = _budget;
      final ExpenseGroup? pot =
          b != null && pots.any((ExpenseGroupSummary p) => p.id == b.potId)
          ? await _services.expenses.get(b.potId)
          : null;
      if (!mounted) return;
      setState(() {
        _pots = pots;
        _pot = pot;
        _error = null;
      });
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.error);
    }
  }

  Future<void> _editTrip({String? potId}) async {
    final List<ExpenseGroupSummary>? pots = _pots;
    if (pots == null) return;
    if (pots.isEmpty) {
      context.go(Routes.money());
      return;
    }
    final TripBudget? b = await editTripBudget(
      context,
      pots: pots,
      now: _now,
      initial: _budget,
      potId: potId,
    );
    if (b == null || !mounted) return;
    await b.save(_services.prefs);
    if (!mounted) return;
    setState(() {
      _budget = b;
      _pot = null;
    });
    await _load();
  }

  Future<void> _noTrip() async {
    await _services.prefs.writeData(LocalData.tripBudget, null);
    if (mounted) {
      setState(() {
        _budget = null;
        _pot = null;
      });
    }
  }

  /// "Añadir a mano": pagado por ti y solo para ti, con fecha de hoy.
  Future<void> _add(Map<String, Object?> data) async {
    final ExpenseGroup? pot = _pot;
    final int whole = (data['a'] as num?)?.round() ?? 0;
    if (pot == null || whole <= 0) return;
    final String title = '${data['n'] ?? ''}'.trim();
    try {
      await _services.expenses.add(
        pot.id,
        NewExpense(
          title: title.isEmpty ? 'Gasto' : title,
          amountMinor: wholeToMinor(whole, pot.currency),
          payerSeat: pot.mySeat,
          participants: <int>[pot.mySeat],
          spentOn: _now,
        ),
      );
    } on ApiException catch (e) {
      if (!mounted) return;
      final AppLocalizations t = AppLocalizations.of(context);
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(
              e.error == ApiError.network ? t.errorNetwork : t.errorUnavailable,
            ),
          ),
        );
    }
    if (mounted) await _load();
  }

  /// Lo que pide la página.
  void _onMessage(String m) {
    final List<String> p = m.split(':');
    final int? n = p.length > 1 ? int.tryParse(p[1]) : null;
    final Map<String, Object?>? data = p.length == 3 ? unpackJson(p[2]) : null;
    switch (p.first) {
      case 'back':
        if (context.canPop()) context.pop();
      case 'locate':
        unawaited(_searchAtms());
      case 'map3d':
        _openMap();
      case 'trip':
        final List<ExpenseGroupSummary> pots =
            _pots ?? const <ExpenseGroupSummary>[];
        unawaited(
          _editTrip(potId: n != null && n < pots.length ? pots[n].id : null),
        );
      case 'notrip':
        unawaited(_noTrip());
      case 'add' when data != null:
        unawaited(_add(data));
      case 'free':
        unawaited(context.push(Routes.nearby));
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
    final Map<String, Object?> data = abroadPageData(
      now: _now,
      tab: widget.part == AbroadPart.budget ? 'budget' : 'atm',
      atmPhase: _atmPhase,
      me: _me,
      atms: _atms,
      atmsCached: _atmsCached,
      pots: _pots,
      budget: _pot == null ? null : _budget,
      pot: _pot,
      signedOut: _error == ApiError.signedOut,
      failed: _error != null && _error != ApiError.signedOut,
    );
    final String push = abroadPushScript(data);
    if (_html == null) {
      _html = abroadPageWith(page, data);
      _sent = push;
    } else if (push != _sent) {
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
