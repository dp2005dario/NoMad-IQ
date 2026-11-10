// Cerca de ti (maqueta "Cerca de ti"), tal cual: cabecera con tu barrio y la
// hora, pestañas "Tiendas y sitios / Gratis / Tengo 2 horas", el mapa 3D plegable
// con los sitios alrededor de ti, las tarjetas y el paseo guiado.
//
// La página es la propia maqueta (assets/nearby/cerca.html) dentro de un
// WebView, sin datos de ejemplo: la app le pone los textos en tu idioma y
// los sitios REALES de OpenStreetMap (nearby_page.dart).
//   - Tiendas y sitios: lo que hay alrededor (súper, cafeterías, farmacias,
//     cajeros...). Cuando una tarjeta se ve, la página pide su foto real de
//     Google Maps ("photo:3"); el servidor la busca y se la pasamos.
//   - El mapa de la página es un dibujo (no son tus calles de verdad): por
//     eso no lleva nombres de calles. Los sitios sí están a su distancia y
//     en su dirección reales. "Ruta" abre el camino de verdad en Google Maps.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/api_client.dart';
import '../../core/services.dart';
import '../../core/theme.dart';
import '../../l10n/generated/app_localizations.dart';
import '../map/geo.dart';
import '../map/location.dart';
import '../route/web_scene.dart';
import 'nearby_api.dart';
import 'nearby_page.dart';

class NearbyScreen extends StatefulWidget {
  const NearbyScreen({super.key});

  @override
  State<NearbyScreen> createState() => _NearbyScreenState();
}

class _NearbyScreenState extends State<NearbyScreen> {
  late final AppServices _services = ServicesScope.of(context);

  String? _page;
  String? _html;
  Map<int, Uri> _routes = const <int, Uri>{};
  Map<int, NearbySpot> _shops = const <int, NearbySpot>{};
  final WebSceneBridge _bridge = WebSceneBridge();

  /// El servidor no tiene fotos de Google (sin clave): no se piden más.
  bool _photosOff = false;
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    unawaited(_start());
  }

  Future<void> _start() async {
    // Sin caché: la página solo se lee al abrir la pantalla.
    _page = await rootBundle.loadString(nearbyPage, cache: false);
    if (!mounted) return;
    // Primero la página con "Buscando qué hay cerca…" y luego los sitios.
    _show(message: AppLocalizations.of(context).nbLoading);
    await _search();
  }

  /// Vuelve a pintar la página con lo que haya.
  void _show({
    GeoPoint? me,
    NearbyList? found,
    String? message,
    bool retry = false,
  }) {
    if (!mounted || _page == null) return;
    final NearbyPageData data = nearbyPageData(
      t: AppLocalizations.of(context),
      language: Localizations.localeOf(context).languageCode,
      now: DateTime.now(),
      me: me,
      found: found,
      message: message,
      retry: retry,
    );
    setState(() {
      _routes = data.routes;
      _shops = data.shops;
      _html = nearbyPageWith(_page!, data);
    });
  }

  /// Por qué no hay posición: sin permiso / GPS apagado, o aún sin señal.
  bool _noSignal = false;

  Future<GeoPoint?> _position() async {
    final LocationSource gps = _services.location;
    _noSignal = false;
    try {
      LocationAccess access = await gps.check();
      if (access == LocationAccess.denied) access = await gps.request();
      if (access != LocationAccess.granted) return null;
      final PositionFix? fix = await gps.current();
      if (fix == null) _noSignal = true;
      return fix?.point;
    } on Object {
      // Tiempo agotado, GPS que falla a mitad, etc.: cualquier error de
      // geolocator se trata como "todavía sin señal" y se puede reintentar.
      _noSignal = true;
      return null;
    }
  }

  Future<void> _search() async {
    final GeoPoint? me = await _position();
    if (!mounted) return;
    final AppLocalizations t = AppLocalizations.of(context);
    if (me == null) {
      _show(
        message: _noSignal ? t.nearbyNoSignal : t.cameraNoLocation,
        retry: true,
      );
      return;
    }
    try {
      final NearbyList found = await _services.nearby.near(me);
      _show(me: me, found: found);
    } on ApiException catch (e) {
      _show(
        message: e.error == ApiError.network
            ? t.errorNetwork
            : t.errorUnavailable,
        retry: true,
      );
    }
  }

  /// Lo que pide la página: volver, reintentar o abrir la ruta de verdad.
  void _onMessage(String message) {
    if (message == 'back') {
      unawaited(Navigator.of(context).maybePop());
    } else if (message == 'retry') {
      _show(message: AppLocalizations.of(context).nbLoading);
      unawaited(_search());
    } else if (message.startsWith('photo:')) {
      final int n = int.tryParse(message.substring(6)) ?? -1;
      final NearbySpot? spot = _shops[n];
      if (spot != null && !_photosOff) unawaited(_photo(n, spot));
    } else if (message.startsWith('route:')) {
      final Uri? url = _routes[int.tryParse(message.substring(6)) ?? -1];
      if (url != null) unawaited(_services.openBooking(url));
    }
  }

  /// Busca la foto de Google Maps de la tarjeta [n] y se la pasa a la página.
  Future<void> _photo(int n, NearbySpot spot) async {
    try {
      final ShopPhoto? photo = await _services.nearby.photo(spot);
      if (photo == null || !mounted || _shops[n] != spot) return;
      // jsonEncode: así ni la dirección ni el nombre pueden romper el JS.
      await _bridge.run(
        'window.__shopPhoto&&window.__shopPhoto($n,'
        '${jsonEncode(photo.url.toString())},${jsonEncode(photo.credit)})',
      );
    } on ApiException catch (e) {
      // 404 = el servidor no tiene la clave de Google: se queda el dibujo.
      if (e.error == ApiError.notFound) _photosOff = true;
    }
  }

  @override
  Widget build(BuildContext context) {
    final String? html = _html;
    return Scaffold(
      backgroundColor: NomadColors.background,
      body: html == null
          // Mientras se prepara la página (un instante), el fondo oscuro.
          ? const SizedBox.expand()
          : SafeArea(
              bottom: false,
              child: KeyedSubtree(
                // Una página nueva = un WebView nuevo.
                key: ValueKey<int>(html.hashCode),
                child:
                    _services.webScene?.call(html, _onMessage) ??
                    WebScene(
                      html: html,
                      onMessage: _onMessage,
                      bridge: _bridge,
                    ),
              ),
            ),
    );
  }
}
