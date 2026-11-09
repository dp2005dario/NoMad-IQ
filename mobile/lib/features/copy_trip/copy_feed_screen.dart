// Copia este viaje (maqueta "Copiar"), tal cual: historias arriba, tarjetas
// con el dibujo de la ciudad, la ruta en un mapa 3D, estrellas y "Copiar este
// viaje", y el visor de historias.
//
// La página es la propia maqueta (assets/copy_trip/copiar.html) dentro de un
// WebView, sin datos de ejemplo. Lo real (copy_page.dart):
//   - Los viajes son los que la gente PUBLICA en el muro al compartir
//     (casilla "Publicar en el muro"; por defecto nadie sale).
//   - Las estrellas son votos de verdad: uno por persona (votar otra vez
//     cambia tu voto) y nadie puede votar su propio viaje.
//   - "Copiar este viaje" lo guarda en tus viajes copiados de este móvil.
//   - Un viaje con código se abre con su enlace (/copy-trip?code=...).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/api_client.dart';
import '../../core/services.dart';
import '../../core/theme.dart';
import '../../l10n/generated/app_localizations.dart';
import '../route/web_scene.dart';
import 'copied_trips.dart';
import 'copy_page.dart';
import 'shared_trip_api.dart';

class CopyFeedScreen extends StatefulWidget {
  const CopyFeedScreen({super.key});

  @override
  State<CopyFeedScreen> createState() => _CopyFeedScreenState();
}

class _CopyFeedScreenState extends State<CopyFeedScreen> {
  late final AppServices _services = ServicesScope.of(context);
  late final CopiedTrips _copied = CopiedTrips(_services.prefs);

  String? _page;
  String? _html;
  bool _started = false;
  List<SharedTrip> _trips = const <SharedTrip>[];

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    unawaited(_start());
  }

  Future<void> _start() async {
    // Sin caché: la página solo se lee al abrir la pantalla.
    _page = await rootBundle.loadString(copyPage, cache: false);
    if (!mounted) return;
    _show(message: AppLocalizations.of(context).cpLoading);
    await _load();
  }

  /// Vuelve a pintar la página con lo que haya.
  void _show({String? message, bool retry = false, String? toast}) {
    if (!mounted || _page == null) return;
    final Map<String, Object?> data = copyPageData(
      t: AppLocalizations.of(context),
      language: Localizations.localeOf(context).languageCode,
      locale: Localizations.localeOf(context).toLanguageTag(),
      now: DateTime.now(),
      trips: message == null ? _trips : const <SharedTrip>[],
      copied: <String>{for (final CopiedTrip c in _copied.all()) c.code},
      message: message,
      retry: retry,
      toast: toast,
    );
    setState(() => _html = copyPageWith(_page!, data));
  }

  Future<void> _load() async {
    final AppLocalizations t = AppLocalizations.of(context);
    try {
      _trips = await _services.sharedTrips.feed();
      _show();
    } on ApiException catch (e) {
      _show(
        message: e.error == ApiError.network ? t.copyOffline : t.copyFailed,
        retry: true,
      );
    }
  }

  SharedTrip? _trip(String? index) {
    final int? k = int.tryParse(index ?? '');
    return k != null && k >= 0 && k < _trips.length ? _trips[k] : null;
  }

  /// "Copiar este viaje": se guarda en el móvil y se cuenta la copia.
  Future<void> _copy(SharedTrip trip) async {
    await _copied.add(
      CopiedTrip(
        code: trip.code,
        title: trip.title,
        destination: trip.destination,
        days: trip.days,
        currency: trip.currency,
        lines: trip.lines,
        copiedAt: DateTime.now(),
      ),
    );
    // Contar la copia es solo para el "copiado N veces": si falla (sin red),
    // el viaje ya está en tu móvil igualmente.
    try {
      await _services.sharedTrips.copy(trip.code);
    } on ApiException {
      // Nada: no es importante.
    }
  }

  /// Tus estrellas. La página ya las enseña; si el servidor no las guarda,
  /// se vuelve a pintar con lo que de verdad hay y se dice.
  Future<void> _rate(SharedTrip trip, int stars) async {
    final int i = _trips.indexOf(trip);
    try {
      final SharedTrip saved = await _services.sharedTrips.rate(
        trip.code,
        stars,
      );
      if (i >= 0 && i < _trips.length && _trips[i].code == trip.code) {
        _trips = <SharedTrip>[..._trips]..[i] = saved;
      }
    } on ApiException {
      if (mounted) _show(toast: AppLocalizations.of(context).copyFailed);
    }
  }

  /// Lo que pide la página.
  void _onMessage(String message) {
    final List<String> part = message.split(':');
    final String? a = part.length > 1 ? part[1] : null;
    final String? b = part.length > 2 ? part[2] : null;
    switch (part.first) {
      case 'copy':
        final SharedTrip? trip = _trip(a);
        if (trip != null) unawaited(_copy(trip));
      case 'rate':
        final SharedTrip? trip = _trip(a);
        final int? stars = int.tryParse(b ?? '');
        if (trip != null && !trip.mine && stars != null) {
          if (stars >= 1 && stars <= 5) unawaited(_rate(trip, stars));
        }
      case 'retry':
        _show(message: AppLocalizations.of(context).cpLoading);
        unawaited(_load());
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
                    WebScene(html: html, onMessage: _onMessage),
              ),
            ),
    );
  }
}
