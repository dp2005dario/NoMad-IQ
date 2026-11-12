// Hoteles / Dormir barato (maqueta "Hoteles"), tal cual: chips de sitios,
// tarjeta con el dibujo del monumento, mapa con pines y la hoja de cada zona
// con el "total con tren" y cuánto te ahorras frente a dormir al lado.
//
// La página es la propia maqueta (assets/stays/hoteles.html) dentro de un
// WebView, sin datos de ejemplo. Lo real (stays_page.dart):
//   - Las ZONAS para dormir salen del servidor (OpenStreetMap): junto al
//     sitio y estaciones de tren o metro con alojamientos, con su distancia
//     y minutos estimados.
//   - Los precios NO se inventan: no hay datos gratis y fiables de precios
//     de hotel. "Ver precios" abre Booking.com en esa zona con tus fechas;
//     lo que ves allí lo apuntas en la hoja y la app hace las cuentas.
//   - El mapa de la página es un dibujo (no son tus calles), pero cada zona
//     está a su distancia y en su dirección reales.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/api_client.dart';
import '../../core/config.dart';
import '../../core/services.dart';
import '../../core/theme.dart';
import '../../l10n/generated/app_localizations.dart';
import '../map/geo.dart';
import '../map/location.dart';
import '../nearby/nearby_api.dart' show ShopPhoto;
import '../route/web_scene.dart';
import '../sos/sos_store.dart' show telUri;
import 'pick_point_screen.dart';
import 'stays_api.dart';
import 'stays_math.dart';
import 'stays_page.dart';

class StaysScreen extends StatefulWidget {
  const StaysScreen({super.key, this.target, this.name});

  /// Adónde vas (si viene de otra pantalla).
  final GeoPoint? target;
  final String? name;

  @override
  State<StaysScreen> createState() => _StaysScreenState();
}

class _StaysScreenState extends State<StaysScreen> {
  late final AppServices _services = ServicesScope.of(context);

  String? _page;
  String? _html;
  bool _started = false;

  /// Los chips: tu destino (si lo hay), cerca de ti, los seis monumentos y
  /// "en el mapa". [_points] guarda dónde está cada uno (el GPS o lo que
  /// eliges en el mapa se apuntan al usarlos).
  late List<StayChip> _chips;
  final Map<int, GeoPoint> _points = <int, GeoPoint>{};
  int _current = 0;
  int _nights = 3;
  StayArea? _area;
  final Map<String, StayPrices> _prices = <String, StayPrices>{};

  /// Para mandar a la página las fotos de los hoteles sin recargarla.
  final WebSceneBridge _bridge = WebSceneBridge();

  /// Las fotos de Google Maps que ya llegaron (id del hotel → enlace).
  final Map<String, String> _photos = <String, String>{};

  /// Hoteles cuya foto ya se pidió (para no pedirla dos veces).
  final Set<String> _asked = <String>{};

  /// El servidor no tiene la clave de Google: no se piden más fotos.
  bool _photosOff = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    final AppLocalizations t = AppLocalizations.of(context);
    final GeoPoint? target = widget.target;
    _chips = <StayChip>[
      if (target != null)
        StayChip(
          kind: StayChipKind.target,
          ill: 'generic',
          name: widget.name ?? t.hoTarget,
          short: widget.name ?? t.hoTarget,
          point: target,
        ),
      StayChip(
        kind: StayChipKind.here,
        ill: 'generic',
        name: t.staysNearMe,
        short: t.staysNearMe,
      ),
      ...landmarkChips(t),
      StayChip(
        kind: StayChipKind.map,
        ill: 'generic',
        name: t.staysOnMap,
        short: t.staysOnMap,
      ),
    ];
    for (int i = 0; i < _chips.length; i++) {
      final GeoPoint? p = _chips[i].point;
      if (p != null) _points[i] = p;
    }
    unawaited(_start());
  }

  Future<void> _start() async {
    // Sin caché: la página solo se lee al abrir la pantalla.
    _page = await rootBundle.loadString(staysPage, cache: false);
    if (!mounted) return;
    _show(message: AppLocalizations.of(context).hoLoading);
    await _choose(0);
  }

  /// Vuelve a pintar la página con lo que haya.
  void _show({String? message, bool retry = false}) {
    if (!mounted || _page == null) return;
    final Map<String, Object?> data = staysPageData(
      t: AppLocalizations.of(context),
      language: Localizations.localeOf(context).languageCode,
      chips: _chips,
      current: _current,
      nights: _nights,
      center: _points[_current],
      area: message == null ? _area : null,
      prices: _prices,
      photos: _photos,
      message: message,
      retry: retry,
    );
    setState(() => _html = staysPageWith(_page!, data));
    if (message == null) unawaited(_hotelPhotos());
  }

  /// Los hoteles de la lista, en el mismo orden que la página.
  List<NearHotel> _hotels() {
    final GeoPoint? center = _points[_current];
    final StayArea? area = _area;
    if (center == null || area == null) return const <NearHotel>[];
    return nearestHotels(center, area.hotels);
  }

  /// Pide las fotos de Google Maps de los primeros hoteles, una a una, y
  /// se las pasa a la página al momento (sin recargarla).
  Future<void> _hotelPhotos() async {
    final List<NearHotel> list = _hotels();
    for (int i = 0; i < list.length && i < 8; i++) {
      final NearHotel h = list[i];
      if (_photosOff || !_asked.add(h.id)) continue;
      try {
        final ShopPhoto? photo = await _services.nearby.photoOf(
          id: h.id,
          name: h.name,
          point: h.point,
        );
        if (photo == null || !mounted) continue;
        final String url = photo.url.toString();
        _photos[h.id] = url;
        // jsonEncode: así ningún nombre ni enlace puede romper el JS.
        await _bridge.run(
          'window.__hotelPhoto&&window.__hotelPhoto('
          '${jsonEncode(h.id)},${jsonEncode(url)})',
        );
      } on ApiException catch (e) {
        // 404 = el servidor no tiene la clave de Google: se queda el logo.
        if (e.error == ApiError.notFound) _photosOff = true;
      }
    }
  }

  /// Elige el chip [i]: busca dónde está (GPS si es "cerca de ti") y sus
  /// zonas para dormir.
  Future<void> _choose(int i) async {
    final AppLocalizations t = AppLocalizations.of(context);
    _current = i;
    _area = null;
    if (_chips[i].kind == StayChipKind.here) {
      final GeoPoint? me = await _position();
      if (!mounted) return;
      if (me == null) {
        _show(message: t.staysNoLocation, retry: true);
        return;
      }
      _points[i] = me;
    }
    final GeoPoint? at = _points[i];
    if (at == null) return;
    try {
      final StayArea area = await _services.stays.around(at);
      if (!mounted || _current != i) return;
      _area = area;
      _show();
    } on ApiException catch (e) {
      _show(
        message: e.error == ApiError.network
            ? t.staysOffline
            : t.staysUnavailable,
        retry: true,
      );
    }
  }

  Future<GeoPoint?> _position() async {
    final LocationSource gps = _services.location;
    try {
      LocationAccess access = await gps.check();
      if (access == LocationAccess.denied) access = await gps.request();
      if (access != LocationAccess.granted) return null;
      return (await gps.current())?.point;
    } on Object {
      // GPS que falla o tarda demasiado: "sin ubicación" y se puede
      // reintentar o elegir el sitio en el mapa.
      return null;
    }
  }

  /// "En el mapa": eliges el punto y pasa a ser el chip de tu destino.
  Future<void> _onMap() async {
    final GeoPoint? p = await Navigator.of(context).push<GeoPoint>(
      MaterialPageRoute<GeoPoint>(
        builder: (_) => PickPointScreen(initial: _points[_current]),
      ),
    );
    if (p == null || !mounted) {
      _show(); // vuelve a marcar el chip que estaba
      return;
    }
    final int i = _chips.length - 1;
    final AppLocalizations t = AppLocalizations.of(context);
    _chips = <StayChip>[
      ..._chips.take(i),
      StayChip(
        kind: StayChipKind.target,
        ill: 'generic',
        name: t.staysPoint(p.lat.toStringAsFixed(3), p.lon.toStringAsFixed(3)),
        short: t.hoTarget,
        point: p,
      ),
      _chips[i],
    ];
    _points[i] = p;
    _show(message: t.hoLoading);
    await _choose(i);
  }

  StayZone? _zone(String? index) {
    final int? k = int.tryParse(index ?? '');
    final List<StayZone> zones = _area?.zones ?? const <StayZone>[];
    return k != null && k >= 0 && k < zones.length ? zones[k] : null;
  }

  /// Lo que pide la página.
  void _onMessage(String message) {
    final List<String> part = message.split(':');
    final String? a = part.length > 1 ? part[1] : null;
    final String? b = part.length > 2 ? part[2] : null;
    switch (part.first) {
      case 'chip':
        final int? i = int.tryParse(a ?? '');
        if (i != null && i >= 0 && i < _chips.length) unawaited(_choose(i));
      case 'map':
        unawaited(_onMap());
      case 'retry':
        _show(message: AppLocalizations.of(context).hoLoading);
        unawaited(_choose(_current));
      case 'nights':
        _nights = (int.tryParse(a ?? '') ?? _nights).clamp(1, 14);
      case 'night' || 'fare':
        final StayZone? z = _zone(a);
        final int? cents = int.tryParse(b ?? '');
        if (z == null || cents == null) return;
        final StayPrices p = _prices.putIfAbsent(z.id, StayPrices.new);
        final double? v = cents == 0 ? null : cents / 100;
        if (part.first == 'night') {
          p.night = v;
        } else {
          p.fare = v;
        }
      case 'hotel' || 'hprice' || 'hcall' || 'hweb' || 'hgo':
        final int? n = int.tryParse(a ?? '');
        final List<NearHotel> list = _hotels();
        if (n == null || n < 0 || n >= list.length) return;
        final NearHotel h = list[n];
        final String? phone = h.phone;
        final Uri? site = h.website;
        if (part.first == 'hcall' && phone != null) {
          // Un toque y se abre el marcador con su número puesto.
          unawaited(_services.openLink(telUri(phone)));
          return;
        }
        if (part.first == 'hweb' && site != null) {
          unawaited(_services.openLink(site));
          return;
        }
        if (part.first == 'hgo') {
          unawaited(_services.openLink(mapsDirections(h.point)));
          return;
        }
        if (part.first != 'hprice') {
          // Como en Google Maps: ese hotel, con sus fotos, opiniones y su
          // teléfono (cuando OpenStreetMap no lo tiene).
          unawaited(_services.openBooking(mapsPlace(h.name, h.point)));
          return;
        }
        final DateTime from = DateUtils.dateOnly(DateTime.now())
            .add(const Duration(days: 14));
        unawaited(
          _services.openBooking(
            bookingSearch(
              at: h.point,
              checkIn: from,
              checkOut: from.add(Duration(days: _nights)),
              adults: 2,
              language: Localizations.localeOf(context).languageCode,
              affiliateId: AppConfig.bookingAffiliateId,
            ),
          ),
        );
      case 'book':
        final StayZone? z = _zone(a);
        if (z == null) return;
        final DateTime start = DateUtils.dateOnly(DateTime.now())
            .add(const Duration(days: 14));
        unawaited(
          _services.openBooking(
            bookingSearch(
              at: z.point,
              checkIn: start,
              checkOut: start.add(Duration(days: _nights)),
              adults: 2,
              language: Localizations.localeOf(context).languageCode,
              affiliateId: AppConfig.bookingAffiliateId,
            ),
          ),
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final String? html = _html;
    return Scaffold(
      backgroundColor: NomadColors.background,
      body: html == null
          ? const SizedBox.expand()
          : SafeArea(
              bottom: false,
              child: KeyedSubtree(
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
