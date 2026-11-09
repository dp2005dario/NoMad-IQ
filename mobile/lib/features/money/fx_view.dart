// Divisas: la maqueta "Cambio de moneda" tal cual
// (assets/money/divisas.html, dentro de un WebView). Escribes una cantidad,
// eliges las dos monedas y tocas "Lanzar la moneda": la moneda sube girando
// y cae del otro lado ya convertida. Debajo, "Cómo llevarlo en efectivo"
// con las fotos de los billetes y monedas.
//
// Los tipos son los oficiales del Banco Central Europeo de ese día (ver
// fx_api.dart). Sin red se usan los últimos guardados en el móvil y Flyra
// lo avisa. La página es SOLO INFORMATIVA: no cambia ni mueve dinero.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/api_client.dart';
import '../../core/services.dart';
import '../flights/flights_page.dart' show unpackJson;
import '../route/web_scene.dart';
import 'fx_api.dart';
import 'fx_page.dart';

class FxView extends StatefulWidget {
  const FxView({super.key});

  /// El puente de la última pantalla abierta (lo miran los tests).
  static WebSceneBridge? lastBridge;

  @override
  State<FxView> createState() => _FxViewState();
}

class _FxViewState extends State<FxView> {
  late final AppServices _services = ServicesScope.of(context);
  final WebSceneBridge _bridge = FxView.lastBridge = WebSceneBridge();

  /// La página se lee una vez (se guarda el texto, no la espera).
  static String? _pageCache;

  /// Las fotos ya convertidas, por divisa (se leen una vez).
  static final Map<String, Map<String, Object?>> _photoCache =
      <String, Map<String, Object?>>{};
  String? _html;
  String? _sent;
  bool _started = false;

  FxResult? _fx;
  bool _failed = false;
  String _from = 'EUR';
  String _to = 'GBP';

  /// Las fotos leídas, por divisa, y las que ya tiene la página.
  final Map<String, Object?> _ph = <String, Object?>{};
  final Set<String> _shown = <String>{};

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    unawaited(_start());
  }

  Future<void> _start() async {
    try {
      _pageCache ??= await rootBundle.loadString(fxPage, cache: false);
    } on Object {
      return;
    }
    await _photos(<String>[_from, _to]);
    if (mounted) setState(() {});
    await _load();
  }

  Future<void> _load() async {
    try {
      final FxResult fx = await _services.fx.load();
      if (mounted) {
        setState(() {
          _fx = fx;
          _failed = false;
        });
      }
    } on ApiException {
      if (mounted) setState(() => _failed = true);
    }
  }

  /// Lee (una vez) las fotos de [codes] y las deja listas para la página.
  Future<void> _photos(List<String> codes) async {
    for (final String code in codes) {
      if (_ph.containsKey(code)) continue;
      final Map<String, Object?>? cached = _photoCache[code];
      if (cached != null) {
        _ph[code] = cached;
        continue;
      }
      final Map<String, Object?>? assets = photoAssets(code);
      if (assets == null) continue;
      final Map<String, String> uris = <String, String>{};
      Future<String?> uri(String path) async {
        if (uris[path] case final String u) return u;
        try {
          final ByteData b = await rootBundle.load(path);
          return uris[path] =
              'data:image/webp;base64,${base64Encode(b.buffer.asUint8List(b.offsetInBytes, b.lengthInBytes))}';
        } on Object {
          return null;
        }
      }

      Future<Map<String, String>> all(Object? m) async => <String, String>{
        for (final MapEntry<String, Object?> e
            in (m as Map<String, Object?>? ?? const <String, Object?>{})
                .entries)
          if (await uri(e.value! as String) case final String u) e.key: u,
      };
      final String? spin = assets['s'] == null
          ? null
          : await uri(assets['s']! as String);
      final Map<String, Object?> out = <String, Object?>{
        's': ?spin,
        'n': await all(assets['n']),
        'm': await all(assets['m']),
      };
      _photoCache[code] = out;
      _ph[code] = out;
    }
  }

  Future<void> _pair(String from, String to) async {
    if (!fxCodes.contains(from) || !fxCodes.contains(to)) return;
    _from = from;
    _to = to;
    await _photos(<String>[from, to]);
    if (mounted) setState(() {});
  }

  /// Lo que pide la página.
  void _onMessage(String m) {
    final List<String> p = m.split(':');
    final Map<String, Object?>? data = p.length == 3 ? unpackJson(p[2]) : null;
    switch (p.first) {
      case 'pair' when data != null:
        unawaited(_pair('${data['f']}', '${data['t']}'));
      case 'retry':
        unawaited(_load());
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
    Map<String, Object?> data(Map<String, Object?> ph) =>
        fxPageData(from: _from, to: _to, fx: _fx, failed: _failed, ph: ph);
    // Lo que sabe la página (sin las fotos, que pesan) y qué fotos tiene.
    final String key =
        '${jsonEncode(data(const <String, Object?>{}))}${_ph.keys.toList()..sort()}';
    if (_html == null) {
      _html = fxPageWith(page, data(Map<String, Object?>.of(_ph)));
      _shown.addAll(_ph.keys);
      _sent = key;
    } else if (key != _sent) {
      _sent = key;
      // Solo las fotos que la página aún no tiene.
      final Map<String, Object?> fresh = <String, Object?>{
        for (final MapEntry<String, Object?> e in _ph.entries)
          if (!_shown.contains(e.key)) e.key: e.value,
      };
      _shown.addAll(fresh.keys);
      unawaited(_bridge.run(fxPushScript(data(fresh))));
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
