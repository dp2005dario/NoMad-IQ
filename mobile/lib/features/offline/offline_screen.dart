// Sin conexión (maqueta "SinConexion"): la maqueta tal cual
// (assets/offline/sinconexion.html) para descargar ciudades enteras y que el
// mapa, las audioguías y los avisos de zona funcionen en modo avión o en el
// extranjero sin datos.
//
// Todo lo descargado vive SOLO en este móvil, en la carpeta privada de la
// app, y se borra al desinstalar o al tocar "Borrar".
//
// Lo que hace (todo de verdad, nada de ejemplo):
//   - buscas la ciudad por su nombre o por su aeropuerto y ves su mapa de
//     OpenStreetMap con el recuadro de lo que se va a bajar;
//   - eliges cuánto (centro, ciudad o con alrededores) y si quieres las
//     voces de las audioguías; el tamaño aproximado sale de lo que ocuparon
//     DE VERDAD tus otras ciudades (sin ninguna, se dice que aún no se sabe);
//   - varias ciudades en cola (se bajan de una en una), "Pausar" y
//     "Seguir" (lo ya bajado no se baja otra vez), el anillo con el %, y al
//     terminar el estallido con vibración;
//   - "Hay un mapa más nuevo" (la versión que publica OpenFreeMap), borrar
//     con confirmación, "solo con wifi" y "Actualizar solas";
//   - el botón del avión enseña cómo se ve sin internet (y si de verdad no
//     hay internet, se ve así solo);
//   - si falta el wifi, Flyra lo dice y te deja usar tus datos.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../core/router.dart';
import '../../core/services.dart';
import '../../core/settings.dart';
import '../../l10n/generated/app_localizations.dart';
import '../route/flight3d.dart' show CountryCodes;
import '../route/web_scene.dart';
import '../route/world_data.dart';
import 'city_downloader.dart';
import 'city_pack.dart';
import 'offline_auto.dart';
import 'offline_page.dart';

class OfflineScreen extends StatefulWidget {
  const OfflineScreen({super.key});

  /// La última conexión con la página (para las pruebas).
  static WebSceneBridge? lastBridge;

  @override
  State<OfflineScreen> createState() => _OfflineScreenState();
}

/// Lo que dice Flyra en su bocadillo.
typedef _Fly = ({String title, String text, String main, String? alt});

class _OfflineScreenState extends State<OfflineScreen> {
  late final AppServices _services = ServicesScope.of(context);
  final WebSceneBridge _bridge = OfflineScreen.lastBridge = WebSceneBridge();

  // La página se lee una vez y se guarda (como String, no como Future).
  static String? _pageCache;
  String? _html;
  String? _sent;

  Airports? _airports;
  CountryCodes? _codes;
  List<CityPack> _cities = <CityPack>[];
  bool _wifiOnly = true;

  /// Lo que buscas y la ciudad que has elegido.
  String _query = '';
  Airport? _picked;

  /// Lo que eliges antes de bajar: cuánto de la ciudad y si con voces.
  OfflineArea _area = OfflineArea.city;
  bool _audio = true;

  /// Si hay internet ahora (null = aún no se sabe).
  bool? _online;
  StreamSubscription<bool>? _net;

  /// Qué ciudad se está descargando y por dónde va (null = ninguna).
  String? _busy;
  DownloadProgress? _progress;

  /// Lo último que salió mal (null = nada) y si es "falta el wifi".
  DownloadError? _error;
  String? _otherBusy;

  /// Cuenta los avisos: cada aviso nuevo vuelve a enseñar el bocadillo.
  int _flyKey = 0;

  /// La última ciudad pedida (para "Usar datos").
  _Job? _last;

  /// Ciudades esperando su turno (se bajan de una en una).
  final List<_Job> _queue = <_Job>[];

  /// Has tocado "Pausar".
  bool _stop = false;

  /// La última ciudad que terminó bien (para el "estallido").
  String? _justDone;
  int _burstN = 0;

  /// Las descargas paradas a medias (para "Seguir").
  List<PausedDownload> _paused = <PausedDownload>[];

  /// La versión del mapa publicada ahora (null = no se sabe).
  String? _latestMap;

  /// "Actualizar solas" activado.
  late final OfflineAutoUpdate _auto = OfflineAutoUpdate(_services);
  bool _autoOn = false;

  /// El botón del avión: enseña cómo se ve sin internet.
  bool _pretend = false;

  @override
  void initState() {
    super.initState();
    _cities = _services.offlineCities.all();
    _paused = _services.offlineCities.paused();
    _autoOn = _auto.enabled;
    _wifiOnly = _services.prefs.readData(LocalData.offlineWifiOnly) != '0';
    _net = _services.onlineChanges().listen((bool on) {
      if (mounted) setState(() => _online = on);
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_open()));
  }

  @override
  void dispose() {
    unawaited(_net?.cancel());
    super.dispose();
  }

  Future<void> _open() async {
    try {
      _pageCache ??= await rootBundle.loadString(offlinePage, cache: false);
    } on Object {
      return;
    }
    if (mounted) setState(() {});
    unawaited(_loadMapVersion());
    try {
      final WorldData world = await WorldData.load();
      if (mounted) setState(() => _airports = world.airports);
    } on Object {
      // Sin la lista de aeropuertos no se puede buscar una ciudad nueva.
    }
    try {
      final CountryCodes codes = await CountryCodes.load();
      if (mounted) setState(() => _codes = codes);
    } on Object {
      // Sin los códigos de país, cada ciudad lleva su aeropuerto.
    }
  }

  Future<void> _loadMapVersion() async {
    if (_cities.isEmpty) return;
    String? v;
    try {
      v = await _services.mapVersion.latest();
    } on Object {
      v = null;
    }
    if (mounted && v != null) setState(() => _latestMap = v);
  }

  Future<void> _setAuto(bool on) async {
    setState(() => _autoOn = on);
    await _auto.setEnabled(on);
  }

  Future<void> _setWifiOnly(bool only) async {
    setState(() => _wifiOnly = only);
    await _services.prefs.writeData(
      LocalData.offlineWifiOnly,
      only ? '1' : '0',
    );
  }

  /// Borrar lo que se bajó de una descarga parada.
  Future<void> _discard(PausedDownload p) async {
    // Si la ciudad ya estaba descargada de antes, esa se queda.
    if (_services.offlineCities.of(p.iata) == null) {
      await _services.downloads.forget(p.iata);
    }
    await _services.offlineCities.unpause(p.iata);
    if (mounted) {
      setState(() => _paused = _services.offlineCities.paused());
    }
  }

  Future<void> _forget(CityPack pack) async {
    await _services.downloads.forget(pack.iata);
    if (mounted) {
      setState(() => _cities = _services.offlineCities.all());
    }
  }

  Airport? _airportOf(String code) {
    final Airports? all = _airports;
    final String c = code.trim().toUpperCase();
    if (all == null || c.length != 3) return null;
    return all[c];
  }

  /// Añade a la cola; si no hay nada bajando, empieza ya.
  void _enqueue(Airport airport, OfflineArea area, bool audio) {
    if (_busy == airport.iata ||
        _queue.any((_Job j) => j.airport.iata == airport.iata)) {
      return;
    }
    setState(() => _queue.add(_Job(airport, area, audio)));
    if (_busy == null) unawaited(_next());
  }

  Future<void> _next() async {
    while (mounted && _queue.isNotEmpty && _busy == null) {
      final _Job j = _queue.removeAt(0);
      await _download(j);
    }
  }

  void _fail(DownloadError e) => setState(() {
    _error = e;
    _otherBusy = null;
    _flyKey++;
  });

  Future<void> _download(_Job job) async {
    if (_busy != null) return;
    final Airport airport = job.airport;
    // Se está poniendo al día otra ciudad sola ("Actualizar solas").
    final String? other = _services.offlineBusy.value;
    if (other != null) {
      setState(() {
        _error = null;
        _otherBusy = other;
        _flyKey++;
      });
      return;
    }
    _services.offlineBusy.value = airport.iata;
    final String language = Localizations.localeOf(context).languageCode;
    final bool hadIt = _cities.any((CityPack c) => c.iata == airport.iata);
    bool ok = false;
    setState(() {
      _busy = airport.iata;
      _last = job;
      _progress = const DownloadProgress(DownloadStep.zones);
      _error = null;
      _otherBusy = null;
      _stop = false;
      _justDone = null;
    });
    try {
      await _services.downloads.run(
        iata: airport.iata,
        city: airport.city,
        center: airport.position,
        language: language,
        wifiOnly: _wifiOnly,
        onProgress: (DownloadProgress p) {
          if (mounted) setState(() => _progress = p);
        },
        stopped: () => _stop,
        area: job.area,
        withAudio: job.audio,
      );
      ok = true;
      await _services.offlineCities.unpause(airport.iata);
    } on DownloadException catch (e) {
      // Parada a medias (tú, o se fue la red): lo bajado se queda y la
      // ciudad sale con "Seguir", que no vuelve a bajar lo que ya está.
      if (e.error == DownloadError.cancelled ||
          e.error == DownloadError.offline ||
          e.error == DownloadError.failed) {
        await _services.offlineCities.pause(
          PausedDownload(
            iata: airport.iata,
            city: airport.city,
            area: job.area,
            withAudio: job.audio,
          ),
        );
      } else if (!hadIt) {
        // No hay nada que bajar ahí (o falta el wifi): fuera los restos.
        await _services.downloads.forget(airport.iata);
      }
      // "Pausar" lo has tocado tú: no hace falta que Flyra diga nada.
      if (mounted && e.error != DownloadError.cancelled) _fail(e.error);
    } on Object {
      if (mounted) _fail(DownloadError.failed);
    } finally {
      _services.offlineBusy.value = null;
      if (mounted) {
        setState(() {
          _busy = null;
          _progress = null;
          _cities = _services.offlineCities.all();
          _paused = _services.offlineCities.paused();
          if (ok) {
            _justDone = airport.iata;
            _burstN++;
          }
        });
        if (ok) unawaited(HapticFeedback.mediumImpact());
      }
    }
  }

  /// "Pausar", "Seguir" o "Abrir" en la tarjeta de una ciudad.
  Future<void> _act(String iata) async {
    if (_busy == iata) {
      setState(() => _stop = true);
      return;
    }
    final int q = _queue.indexWhere((_Job j) => j.airport.iata == iata);
    if (q >= 0) {
      // En cola: se queda parada, lista para "Seguir".
      final _Job j = _queue[q];
      setState(() => _queue.removeAt(q));
      await _services.offlineCities.pause(
        PausedDownload(
          iata: iata,
          city: j.airport.city,
          area: j.area,
          withAudio: j.audio,
        ),
      );
      if (mounted) setState(() => _paused = _services.offlineCities.paused());
      return;
    }
    for (final PausedDownload p in _paused) {
      if (p.iata == iata) {
        final Airport? a = _airportOf(iata);
        if (a != null) _enqueue(a, p.area, p.withAudio);
        return;
      }
    }
    if (mounted) context.go(Routes.map);
  }

  /// "Borrar" (después de "¿Borrar...?" en la tarjeta).
  Future<void> _delete(String iata) async {
    final int q = _queue.indexWhere((_Job j) => j.airport.iata == iata);
    if (q >= 0) {
      setState(() => _queue.removeAt(q));
      return;
    }
    for (final PausedDownload p in _paused) {
      if (p.iata == iata) return _discard(p);
    }
    for (final CityPack c in _cities) {
      if (c.iata == iata) return _forget(c);
    }
  }

  void _onMessage(String m) {
    final int i = m.indexOf(':');
    final String what = i < 0 ? m : m.substring(0, i);
    final String arg = i < 0 ? '' : m.substring(i + 1);
    switch (what) {
      case 'back':
        if (context.canPop()) context.pop();
      case 'plane':
        setState(() => _pretend = !_pretend);
      case 'q':
        setState(() => _query = webSceneText(arg));
      case 'pick':
        final Airport? a = _airportOf(arg);
        if (a != null) setState(() => _picked = a);
      case 'area':
        final int n = int.tryParse(arg) ?? -1;
        if (n >= 0 && n < OfflineArea.values.length) {
          setState(() => _area = OfflineArea.values[n]);
        }
      case 'audio':
        setState(() => _audio = !_audio);
      case 'add':
        final Airport? a = _picked;
        if (a != null) _enqueue(a, _area, _audio);
      case 'act':
        unawaited(_act(arg));
      case 'upd':
        final CityPack? pack = _services.offlineCities.of(arg);
        final Airport? a = _airportOf(arg);
        if (pack != null && a != null) _enqueue(a, pack.area, pack.withAudio);
      case 'del':
        unawaited(_delete(arg));
      case 'wifi':
        unawaited(_setWifiOnly(!_wifiOnly));
      case 'auto':
        unawaited(_setAuto(!_autoOn));
      case 'flyMain':
        final bool wifi = _error == DownloadError.waitingForWifi;
        setState(() {
          _error = null;
          _otherBusy = null;
        });
        // "Usar datos": se quita "solo con wifi" y se vuelve a intentar.
        final _Job? job = _last;
        if (wifi && job != null) {
          unawaited(
            _setWifiOnly(false)
                .then((_) => _enqueue(job.airport, job.area, job.audio)),
          );
        }
      case 'flyHide':
        setState(() {
          _error = null;
          _otherBusy = null;
        });
    }
  }

  _Fly? _fly(AppLocalizations t) {
    final String? other = _otherBusy;
    if (other != null) {
      return (
        title: 'Espera un momento',
        text: t.offlineAutoBusy(other),
        main: 'Vale',
        alt: null,
      );
    }
    return switch (_error) {
      null || DownloadError.cancelled => null,
      DownloadError.waitingForWifi => (
        title: 'Descarga en pausa',
        text: t.offlineWaitingWifi,
        main: 'Usar datos',
        alt: 'Ahora no',
      ),
      DownloadError.offline => (
        title: 'Sin internet',
        text: '${t.offlineNoNet} ${t.offlineResumeNote}',
        main: 'Vale',
        alt: null,
      ),
      DownloadError.nothingThere => (
        title: 'Aún no hay audioguías',
        text: t.offlineNothingThere,
        main: 'Vale',
        alt: null,
      ),
      DownloadError.failed => (
        title: 'No se pudo descargar',
        text: t.offlineFailed,
        main: 'Vale',
        alt: null,
      ),
    };
  }

  /// Dos letras del país (como en la maqueta) o, si no se sabe, el
  /// aeropuerto.
  String _code(String iata) {
    final Airport? a = _airportOf(iata);
    final String? cc = a == null ? null : _codes?[a.country];
    return cc ?? iata;
  }

  String _step(AppLocalizations t, DownloadProgress? p) => switch (p?.step) {
    DownloadStep.guides => t.offlineStepGuides,
    DownloadStep.audio => t.offlineStepAudio(p!.done, p.total),
    DownloadStep.map => t.offlineStepMap,
    _ => t.offlineStepZones,
  };

  Map<String, Object?> _data(AppLocalizations t) {
    final String tag = Localizations.localeOf(context).toLanguageTag();
    final String language = Localizations.localeOf(context).languageCode;
    final bool plane = _online == false || _pretend;
    final int n = _cities.length;
    final bool full = n >= OfflineLibrary.maxCities;
    final int? est = estimateBytes(_cities, area: _area, withAudio: _audio);
    final int? mapOnly = estimateBytes(_cities, area: _area, withAudio: false);
    final int? withVoices = estimateBytes(
      _cities,
      area: _area,
      withAudio: true,
    );

    // Las tarjetas: la que baja, las de la cola, las paradas y las listas.
    // Una por ciudad.
    final List<Map<String, Object?>> items = <Map<String, Object?>>[];
    final Set<String> seen = <String>{};
    final String? busy = _busy;
    if (busy != null) {
      seen.add(busy);
      final int pr = ((_progress?.fraction ?? 0) * 100).round();
      final bool upd = _cities.any((CityPack c) => c.iata == busy);
      items.add(<String, Object?>{
        'id': busy,
        'name': _airportOf(busy)?.city ?? busy,
        'code': _code(busy),
        'st': upd ? 'updating' : 'down',
        'pr': pr,
        'detail': plane
            ? 'Necesita internet para seguir'
            : upd
            ? 'Actualizando… $pr %'
            : 'Descargando · $pr %',
        'left': _stop ? 'Parando…' : _step(t, _progress),
        'right': '',
        'btnText': 'Pausar',
      });
    }
    for (final _Job j in _queue) {
      if (!seen.add(j.airport.iata)) continue;
      items.add(<String, Object?>{
        'id': j.airport.iata,
        'name': j.airport.city,
        'code': _code(j.airport.iata),
        'st': 'queued',
        'pr': 0,
        'detail': plane
            ? 'Necesita internet para seguir'
            : 'En cola · empieza al acabar la otra',
        'left': '',
        'right': '',
        'btnText': 'Pausar',
        'askTxt': '¿Quitar ${j.airport.city} de la cola?',
        'canDel': true,
      });
    }
    for (final PausedDownload p in _paused) {
      if (!seen.add(p.iata)) continue;
      items.add(<String, Object?>{
        'id': p.iata,
        'name': p.city,
        'code': _code(p.iata),
        'st': 'paused',
        'pr': 0,
        'warn': true,
        'detail': plane
            ? 'Necesita internet para seguir'
            : 'En pausa · ${t.offlineResumeNote}',
        'btnText': t.offlineResume,
        'askTxt': '¿Borrar lo bajado de ${p.city}?',
        'canDel': true,
      });
    }
    for (final CityPack c in _cities) {
      if (!seen.add(c.iata)) continue;
      final DateTime? newer = hasNewerMap(c, _latestMap)
          ? mapVersionDay(_latestMap)
          : null;
      final String? upd = c.mapFailed
          ? '↻ El mapa no se pudo guardar · volver a bajarlo'
          : c.language != language
          ? '↻ Está en otro idioma · volver a bajarla'
          : newer != null
          ? '↻ Hay un mapa más nuevo (${DateFormat.yMMMd(tag).format(newer)}) · actualizar'
          : null;
      items.add(<String, Object?>{
        'id': c.iata,
        'name': c.city,
        'code': _code(c.iata),
        'st': 'done',
        'pr': 100,
        'ok': !c.mapFailed,
        'warn': c.mapFailed,
        'detail': plane
            ? (c.mapFailed ? t.offlineMapMissing : t.offlineWorksOffline)
            : c.mapFailed
            ? t.offlineMapMissing
            : 'Descargada · ${sizeLabel(c.bytes)} · ${_areaName(t, c.area)}',
        'btnText': 'Abrir',
        'updTxt': ?upd,
        'feats': <String>[
          t.offlinePartMap,
          if (c.withAudio)
            c.guides == 1 ? '1 audioguía' : '${c.guides} audioguías'
          else
            t.offlineTextOnly,
          t.offlinePartAlerts,
        ],
        'askTxt': '¿Borrar ${c.city}? Liberas ${sizeLabel(c.bytes)}',
        'canDel': _busy == null,
      });
    }

    // Las ciudades para elegir: lo que buscas o, sin buscar, las tuyas.
    final Airports? all = _airports;
    final List<Airport> found = <Airport>[
      if (all != null && _query.trim().isNotEmpty)
        ...searchAirports(all, _query)
      else
        for (final Map<String, Object?> it in items)
          ?_airportOf(it['id']! as String),
    ];
    final Airport? picked = _picked;
    if (picked != null && !found.any((Airport a) => a.iata == picked.iata)) {
      found.insert(0, picked);
    }

    final bool inList = picked != null && seen.contains(picked.iata);
    final String addText;
    final bool canAdd;
    if (plane) {
      addText = 'Sin internet: no se puede descargar ahora';
      canAdd = false;
    } else if (picked == null) {
      addText = 'Busca tu ciudad arriba';
      canAdd = false;
    } else if (inList) {
      addText = '${picked.city} ya está en tus zonas';
      canAdd = false;
    } else if (full) {
      addText = t.offlineMax(OfflineLibrary.maxCities);
      canAdd = false;
    } else {
      addText =
          'Descargar ${picked.city}${est == null ? '' : ' · ~${sizeLabel(est)}'}';
      canAdd = true;
    }

    final int voices = mapOnly != null && withVoices != null
        ? withVoices - mapOnly
        : 0;
    return <String, Object?>{
      't': <String, Object?>{
        'title': 'Zonas sin conexión',
        'back': MaterialLocalizations.of(context).backButtonTooltip,
        'planeAria': 'Ver cómo funciona sin internet',
        'heroH': 'Tu ciudad en el móvil, aunque no haya internet',
        'heroP': 'Mapa, calles, rutas a pie, audioguías y avisos de zona funcionan en modo avión.',
        'areaH': t.offlineAreaTitle,
        'searchHint': 'Busca ciudad o aeropuerto',
        'whatH': t.offlineWhatTitle.toUpperCase(),
        'zonesH': 'Tus zonas',
        'none': 'No tienes zonas guardadas. Elige una arriba.',
        'wifiH': t.offlineWifiOnly,
        'wifiP': t.offlineWifiOnlyWhy,
        'autoH': t.offlineAutoTitle,
        'autoP': t.offlineAutoWhy,
        'spaceH': 'Espacio en tu móvil',
        'credits': 'Mapas de OpenStreetMap (© colaboradores de OSM).',
        'del': t.offlineDelete,
        'no': 'No',
      },
      // Ya se puede buscar (la lista de aeropuertos está cargada).
      'ready': _airports != null && _codes != null,
      'plane': plane,
      'pretend': _pretend,
      'planeH': _pretend ? 'Modo avión · sin internet' : t.offlineNoNetTitle,
      'planeText': t.offlineNoNetWorks(n),
      'subtitle': plane && _pretend
          ? 'Modo avión: solo lo descargado'
          : t.offlineReady(n),
      'chips': <Object?>[
        for (final Airport a in found)
          <String, Object?>{'code': a.iata, 't': '${a.city} ${a.iata}'},
      ],
      'city': picked?.iata ?? '',
      'lat': picked?.position.lat,
      'lon': picked?.position.lon,
      'zoneLabel': picked == null
          ? 'Busca tu ciudad arriba'
          : '${picked.city} · ${_areaName(t, _area).toLowerCase()} (${t.offlineKm(_area.km)})',
      'estTxt': picked == null || est == null ? '' : '~${sizeLabel(est)}',
      'areas': <Object?>[
        for (final OfflineArea a in OfflineArea.values)
          <String, Object?>{'t': _areaName(t, a), 's': t.offlineKm(a.km)},
      ],
      'area': _area.index,
      'parts': <Object?>[
        <String, Object?>{
          't': t.offlinePartMap,
          'on': true,
          'locked': true,
          'mb': mapOnly == null ? '' : sizeLabel(mapOnly),
        },
        <String, Object?>{
          't': t.offlinePartAudio,
          'on': _audio,
          'mb': voices > 0 ? sizeLabel(voices) : '',
        },
        <String, Object?>{'t': t.offlinePartAlerts, 'on': true, 'locked': true},
      ],
      'note':
          '${t.offlinePartsNote} ${est == null ? t.offlineEstimateUnknown : t.offlineEstimate(sizeLabel(est))}',
      'addText': addText,
      'canAdd': canAdd,
      'items': items,
      'countLabel': items.length == 1 ? '1 zona' : '${items.length} zonas',
      'wifi': _wifiOnly,
      'auto': _autoOn,
      'usedLabel': t.offlineUsed(sizeLabel(_services.offlineCities.totalBytes)),
      'segs': spaceShares(<int>[for (final CityPack c in _cities) c.bytes]),
      'legend': <String>[
        for (final CityPack c in _cities) '${c.city} ${sizeLabel(c.bytes)}',
      ],
      'burst': _justDone ?? '',
      'burstN': _burstN,
      'fly': switch (_fly(t)) {
        null => null,
        final _Fly f => <String, Object?>{
          'key': _flyKey,
          'title': f.title,
          'text': f.text,
          'main': f.main,
          'alt': f.alt,
        },
      },
    };
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
    final Map<String, Object?> data = _data(AppLocalizations.of(context));
    final String push = offlinePushScript(data);
    if (_html == null) {
      _html = offlinePageWith(page, data);
      _sent = push;
    } else if (push != _sent) {
      _sent = push;
      unawaited(_bridge.run(push));
    }
    final String html = _html!;
    final AppServices services = ServicesScope.of(context);
    return Scaffold(
      backgroundColor: const Color(0xFF0B1217),
      body: SafeArea(
        bottom: false,
        child:
            services.webScene?.call(html, _onMessage) ??
            WebScene(html: html, onMessage: _onMessage, bridge: _bridge),
      ),
    );
  }
}

String _areaName(AppLocalizations t, OfflineArea a) => switch (a) {
  OfflineArea.center => t.offlineAreaCenter,
  OfflineArea.city => t.offlineAreaCity,
  OfflineArea.around => t.offlineAreaAround,
};

/// Una ciudad en la cola, con lo que elegiste para ella.
class _Job {
  const _Job(this.airport, this.area, this.audio);

  final Airport airport;
  final OfflineArea area;
  final bool audio;
}
