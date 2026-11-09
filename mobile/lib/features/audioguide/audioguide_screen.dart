// La pantalla de la audioguía de una zona (maqueta "Audioguía"): la maqueta
// tal cual dentro de un WebView (assets/audioguide/audioguia.html) con tu
// audioguía. El audio lo toca la app (guide_player.dart): la página le dice
// qué hacer (pausa, rebobinar, otra parte) y la app le manda por dónde va.
//
// Como en la maqueta:
//   - FOTO REAL del lugar más conocido de la zona (Wikimedia Commons, con
//     enlace a su autor y licencia). Si no hay foto, no se pone nada.
//   - "¿SABÍAS QUE…?": el resumen de su artículo de Wikipedia (texto real,
//     con la fuente). Si no hay artículo, no sale.
//   - SUBTÍTULOS EN DIRECTO: las palabras se iluminan según avanza el audio.
//     Ojo: el servidor no dice cuándo suena cada palabra, así que se reparte
//     el tiempo de la parte entre sus letras (va bastante a la par, no exacto).
//   - TU RECORRIDO: las partes de la guía, cuáles has oído y cuánto queda,
//     con Flyra andando de una a otra. Las partes no traen un punto del
//     mapa: se reparten a lo largo del camino dibujado.
//   - Los avisos de Flyra abajo ("Audioguía descargada", "aún no está en tu
//     idioma"...). El botón de descargar lleva a "Sin conexión" si aún no la
//     tienes.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart' show NumberFormat;

import '../../core/api_client.dart';
import '../../core/content_language.dart';
import '../../core/languages.dart';
import '../../core/router.dart';
import '../../core/services.dart';
import '../offline/saved_guides.dart';
import '../../l10n/generated/app_localizations.dart';
import '../camera/landmarks_api.dart';
import '../map/geo.dart';
import '../route/places_api.dart' show PlacePhoto;
import '../route/web_scene.dart';
import '../../widgets/flyra_avatar.dart';
import 'audioguide_api.dart';
import 'audioguide_page.dart';
import 'guide_player.dart';

/// En qué punto está la carga.
enum _Stage { loading, preparing, ready, failed }

class AudioguideScreen extends StatefulWidget {
  /// La última conexión con la página (para las pruebas).
  static WebSceneBridge? lastBridge;

  const AudioguideScreen({
    super.key,
    required this.zoneId,
    required this.zoneName,
    this.center,
    this.retryEvery = const Duration(seconds: 5),
  });

  final String zoneId;
  final String zoneName;

  /// El centro de la zona (para la foto real y el "¿Sabías que…?").
  final GeoPoint? center;

  /// Si el guion aún se está escribiendo, cada cuánto se vuelve a preguntar.
  final Duration retryEvery;

  @override
  State<AudioguideScreen> createState() => _AudioguideScreenState();
}

class _AudioguideScreenState extends State<AudioguideScreen> {
  late AppServices _services;
  final WebSceneBridge _bridge = AudioguideScreen.lastBridge = WebSceneBridge();

  // La página se lee una vez y se guarda (como String, no como Future).
  static String? _pageCache;
  String? _html;
  String? _sent;

  /// El aviso de Flyra que pidió el botón de descargar (se enseña una vez).
  int _tapped = 0;
  late String _language;
  bool _started = false;

  _Stage _stage = _Stage.loading;
  ApiError? _error;
  GuideScript? _script;
  AudioManifest? _audio;
  GuidePlayer? _player;
  Timer? _retry;
  int _attempts = 0;
  bool _reloadedAudio = false;

  /// true si lo que se está oyendo es la copia guardada en el móvil (la
  /// descargó "Sin conexión"): se avisa con una etiqueta.
  bool _fromPhone = false;

  /// Velocidades que se van alternando al pulsar el botón "1×".
  static const List<double> _speeds = <double>[1, 1.25, 1.5, 0.75];
  int _speed = 0;

  /// El lugar más conocido de la zona (foto y resumen reales), si lo hay.
  Landmark? _place;

  /// true si la tienes descargada en el móvil (funciona sin conexión).
  bool _saved = false;

  /// En el PRIMER intento se espera hasta 1 minuto a que Flyra prepare
  /// el guion (6 reintentos de 5 s). Después, botón "Reintentar".
  static const int _maxAttempts = 6;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    _services = ServicesScope.of(context);
    _language = contentLanguage(context);
    unawaited(_loadPage());
    unawaited(_load());
    unawaited(_loadExtras());
  }

  Future<void> _loadPage() async {
    try {
      _pageCache ??= await rootBundle.loadString(audioguidePage, cache: false);
    } on Object {
      return;
    }
    if (mounted) setState(() {});
  }

  /// La foto, el "¿Sabías que…?" y si está descargada. Si algo falla, esa
  /// parte simplemente no sale: la audioguía funciona igual.
  Future<void> _loadExtras() async {
    final SavedGuide? saved = await _services.saved.of(
      widget.zoneId,
      _language,
    );
    if (mounted && saved != null) setState(() => _saved = true);
    final GeoPoint? c = widget.center;
    if (c == null) return;
    try {
      final Landmark place = await _services.landmarks.near(
        c.lat,
        c.lon,
        _language,
      );
      // Solo si está de verdad en la zona (no uno famoso a 1 km).
      if ((place.distanceM ?? 0) > 500) return;
      if (mounted) setState(() => _place = place);
    } on ApiException {
      // Sin cuenta, sin internet o sin lugares conocidos: no sale.
    }
  }

  @override
  void dispose() {
    _retry?.cancel();
    _player?.playback.removeListener(_onPlayback);
    unawaited(_player?.dispose());
    super.dispose();
  }

  // --- Carga -----------------------------------------------------------------

  Future<void> _load() async {
    _retry?.cancel();
    setState(() {
      // Mientras se espera a Flyra se sigue enseñando "preparando".
      if (_stage != _Stage.preparing) _stage = _Stage.loading;
      _error = null;
    });
    try {
      final GuideScript script = await _services.audioguides.script(
        widget.zoneId,
        _language,
      );
      if (!mounted) return;
      _script = script;
      _stage = _Stage.ready;
      setState(() {});
      await _loadAudio();
    } on ApiException catch (e) {
      if (!mounted) return;
      if (e.error == ApiError.notFound && _attempts < _maxAttempts) {
        // Aún no está: el servidor la escribe en cuanto alguien entra en la
        // zona. Se vuelve a preguntar en unos segundos.
        _attempts++;
        setState(() => _stage = _Stage.preparing);
        _retry = Timer(widget.retryEvery, () => unawaited(_load()));
        return;
      }
      // Antes de rendirse: ¿está descargada en el móvil? Si la bajaste con
      // "Sin conexión", funciona igual en modo avión.
      if (await _loadSaved()) return;
      if (!mounted) return;
      setState(() {
        _stage = _Stage.failed;
        _error = e.error;
      });
    }
  }

  /// Abre la copia guardada en el móvil. Devuelve true si la había.
  Future<bool> _loadSaved() async {
    final SavedGuide? saved = await _services.saved.of(
      widget.zoneId,
      _language,
    );
    if (saved == null || !mounted) return false;
    _retry?.cancel();
    _script = saved.script;
    _stage = _Stage.ready;
    _fromPhone = true;
    setState(() {});
    final AudioManifest? audio = saved.audio;
    if (audio != null) await _play(audio);
    return true;
  }

  Future<void> _loadAudio() async {
    try {
      final AudioManifest audio = await _services.audioguides.audio(
        widget.zoneId,
        _language,
      );
      if (!mounted) return;
      await _play(audio);
    } on ApiException {
      // Sin audio del servidor: si lo tienes descargado, se oye ese.
      final SavedGuide? saved = await _services.saved.of(
        widget.zoneId,
        _language,
      );
      final AudioManifest? phone = saved?.audio;
      if (phone != null && mounted) {
        _fromPhone = true;
        await _play(phone);
        return;
      }
      // Y si tampoco, se puede leer el texto.
      if (mounted) setState(() => _audio = null);
    }
  }

  /// Carga el audio en el reproductor (venga del servidor o del móvil).
  Future<void> _play(AudioManifest audio) async {
    try {
      final Playback? before = _player?.playback.value;
      GuidePlayer? player = _player;
      if (player == null) {
        player = _services.newPlayer();
        player.playback.addListener(_onPlayback);
        _player = player;
      }
      _audio = audio;
      setState(() {});
      final AppLocalizations t = AppLocalizations.of(context);
      final int n = audio.parts.length;
      final String? guideTitle = _script?.title;
      // Si es una recarga (el audio viejo se retiró), se sigue donde ibas.
      await player.load(
        <Uri>[for (final AudioPart p in audio.parts) p.url],
        part: before == null ? 0 : before.part.clamp(0, n - 1),
        position: before?.position,
        info: NowPlaying(
          album: _script?.zoneName ?? widget.zoneName,
          titles: <String>[
            for (int i = 0; i < n; i++)
              <String?>[
                t.guidePartOf(i + 1, n),
                guideTitle,
              ].whereType<String>().join(' · '),
          ],
        ),
      );
      await player.setSpeed(_speeds[_speed]);
    } on ApiException {
      if (mounted) setState(() => _audio = null);
    }
  }

  void _onPlayback() {
    final Playback p = _player!.playback.value;
    // Un archivo falló: puede que se retirara (410) porque hay versión
    // nueva. Se pide el manifiesto otra vez, UNA vez.
    if (p.failed && !_reloadedAudio) {
      _reloadedAudio = true;
      unawaited(_loadAudio());
    }
    if (mounted) setState(() {});
  }

  // --- Acciones del reproductor --------------------------------------------

  void _toggle() {
    final GuidePlayer? player = _player;
    if (player == null) return;
    unawaited(player.playback.value.playing ? player.pause() : player.play());
  }

  void _goPart(int part) {
    final int count = _audio?.parts.length ?? 0;
    if (part < 0 || part >= count) return;
    unawaited(_player?.seek(Duration.zero, part: part));
  }

  void _cycleSpeed() {
    setState(() => _speed = (_speed + 1) % _speeds.length);
    unawaited(_player?.setSpeed(_speeds[_speed]));
  }

  // --- Dibujo ----------------------------------------------------------------

  /// Lo que pide la página.
  void _onMessage(String m) {
    final List<String> p = m.split(':');
    final int? a = p.length > 1 ? int.tryParse(p[1]) : null;
    final int? b = p.length > 2 ? int.tryParse(p[2]) : null;
    switch (p.first) {
      case 'back':
        if (context.canPop()) context.pop();
      case 'toggle':
        _toggle();
      case 'seek' when a != null:
        final GuidePlayer? player = _player;
        final int part = b ?? player?.playback.value.part ?? 0;
        if (player != null) {
          unawaited(player.seek(Duration(milliseconds: a), part: part));
        }
      case 'part' when a != null:
        _goPart(a);
      case 'speed':
        _cycleSpeed();
      case 'dl':
        if (_saved) {
          setState(() => _tapped++);
        } else {
          unawaited(context.push(Routes.offline));
        }
      case 'photo':
        final PlacePhoto? photo = _place?.photo;
        if (photo != null) unawaited(_services.openBooking(photo.pageUrl));
      case 'text':
        unawaited(_showText());
    }
  }

  /// "Ver el texto": el guion entero, para leerlo.
  Future<void> _showText() async {
    final GuideScript? script = _script;
    if (script == null) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF16212A),
      builder: (BuildContext context) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.7,
        builder: (BuildContext context, ScrollController scroll) => ListView(
          controller: scroll,
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 32),
          children: <Widget>[
            Text(script.title, style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 12),
            for (final GuideSegment s in script.segments)
              Padding(
                padding: const EdgeInsets.only(bottom: 14),
                child: Text(
                  s.text,
                  style: Theme.of(context).textTheme.bodyLarge,
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// El aviso de Flyra de abajo: (título, texto), el más importante.
  (String, String)? _alert(AppLocalizations t, GuideScript script) {
    final Playback? p = _player?.playback.value;
    if (_tapped > 0 && _saved) {
      return (t.offlineSaved, t.guideDownloaded);
    }
    if (p?.failed ?? false) return (t.shortcutAudioguides, t.guideAudioFailed);
    if (_audio == null) return (t.shortcutAudioguides, t.guideRecording);
    if (script.contentLanguage != _language) {
      return (
        t.shortcutAudioguides,
        t.guideOtherLanguage(endonymFor(script.contentLanguage)),
      );
    }
    if (_audio?.stale ?? false) {
      return (t.shortcutAudioguides, t.guideOldVersion);
    }
    if (_fromPhone) return (t.offlineSaved, t.guideDownloaded);
    return null;
  }

  Map<String, Object?> _data(AppLocalizations t, GuideScript script) {
    final AudioManifest? audio = _audio;
    final Playback? p = _player?.playback.value;
    final List<Map<String, Object?>> parts = audio != null
        ? <Map<String, Object?>>[
            for (final AudioPart a in audio.parts)
              guidePartJson(a.text, a.duration),
          ]
        : <Map<String, Object?>>[
            for (final GuideSegment s in script.segments)
              guidePartJson(s.text, readingTime(s.text)),
          ];
    final int part = (p?.part ?? 0).clamp(
      0,
      parts.isEmpty ? 0 : parts.length - 1,
    );
    final PlacePhoto? photo = _place?.photo;
    final (String, String)? alert = _alert(t, script);
    return <String, Object?>{
      'zone': script.zoneName.isEmpty ? widget.zoneName : script.zoneName,
      'title': script.title,
      'langLbl': script.contentLanguage.toUpperCase(),
      'parts': parts,
      'hasAudio': audio != null && p != null,
      'part': part,
      'pos': (p?.position.inMilliseconds ?? 0) / 1000,
      'playing': p?.playing ?? false,
      'speed': _speeds[_speed],
      'speedLbl': t.guideSpeed(_speedLabel(context, _speeds[_speed])),
      'summary': _place?.summary ?? '',
      'photo': photo?.url.toString() ?? '',
      'caption': _place?.name ?? '',
      'credit': _place == null ? '' : t.guidePhotoCredit(_place!.name),
      'alertT': alert?.$1 ?? '',
      'alertS': alert?.$2 ?? '',
      'alertKey': alert == null ? '' : '${alert.$2}#$_tapped',
    };
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    final GuideScript? script = _script;
    final String? page = _pageCache;
    if (_stage != _Stage.ready || script == null || page == null) {
      return Scaffold(
        backgroundColor: const Color(0xFF0B1217),
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          title: Text(t.shortcutAudioguides),
        ),
        body: SafeArea(
          child: switch (_stage) {
            _Stage.preparing => _Message(text: t.guidePreparing, busy: true),
            _Stage.failed => _failure(t),
            _Stage.loading => const Center(child: CircularProgressIndicator()),
            // Lista, pero la página aún se está leyendo (un instante).
            _Stage.ready => const SizedBox.expand(),
          },
        ),
      );
    }
    final Map<String, Object?> data = _data(t, script);
    final String push = audioguidePushScript(data);
    if (_html == null) {
      _html = audioguidePageWith(page, data);
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

  Widget _failure(AppLocalizations t) {
    if (_error == ApiError.signedOut) {
      return _Message(
        text: t.guideSignIn,
        action: t.signInFromGuest,
        onAction: () => unawaited(context.push(Routes.signIn)),
      );
    }
    return _Message(
      text: switch (_error) {
        ApiError.network => t.errorNetwork,
        ApiError.rateLimited => t.errorRateLimited,
        ApiError.notFound => t.guidePreparingSlow,
        _ => t.errorUnavailable,
      },
      action: t.guideRetry,
      onAction: () {
        _attempts = 0;
        unawaited(_load());
      },
    );
  }

  /// "1", "1,25", "1.5"... con la coma o el punto de cada idioma.
  static String _speedLabel(BuildContext context, double speed) =>
      NumberFormat.decimalPattern(Localizations.localeOf(context).toString())
          .format(speed);
}

// --- Piezas ------------------------------------------------------------------

class _Message extends StatelessWidget {
  const _Message({
    required this.text,
    this.busy = false,
    this.action,
    this.onAction,
  });

  final String text;
  final bool busy;
  final String? action;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const FlyraAvatar(size: 64),
            const SizedBox(height: 20),
            Semantics(
              liveRegion: true,
              child: Text(
                text,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            if (busy) ...<Widget>[
              const SizedBox(height: 20),
              const CircularProgressIndicator(),
            ],
            if (action != null) ...<Widget>[
              const SizedBox(height: 20),
              FilledButton(onPressed: onAction, child: Text(action!)),
            ],
          ],
        ),
      ),
    );
  }
}

/// Cuántas letras de [text] se han dicho ya cuando la parte va por
/// [progress] (0 a 1), cortado al final de una palabra.
int guideSpokenUpTo(String text, double progress) {
  final int cut = (text.length * progress).round().clamp(0, text.length);
  if (cut == 0 || cut == text.length) return cut;
  final int space = text.indexOf(' ', cut);
  return space < 0 ? text.length : space;
}
