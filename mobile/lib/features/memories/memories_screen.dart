// Recuerdos (maqueta "Recuerdos"): la maqueta tal cual
// (assets/memories/recuerdos.html) con tus fotos y vídeos del viaje y la
// "historia" que se monta sola: portada con la ruta y las fechas, hasta 6
// fotos con "DÍA N · CIUDAD" y al final las cifras (días, ciudades, fotos,
// sellos nuevos). Debajo, todos tus recuerdos.
//
// El vídeo lo graba la propia página (dibuja la historia en un lienzo y el
// móvil lo graba, sin servidor y gratis). Si el móvil no sabe grabar, se
// comparten las fotos y un texto resumen. Tocar la historia la abre a
// pantalla completa (StoryPlayer, abajo).
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../core/router.dart';
import '../../core/services.dart';
import '../../core/theme.dart';
import '../../l10n/generated/app_localizations.dart';
import '../camera/stamps.dart';
import '../route/web_scene.dart';
import 'memories.dart';
import 'memories_page.dart';

/// Los tres estilos de la maqueta. Cambia cuánto dura cada diapositiva y cómo
/// se dibuja el pie de foto.
enum StoryStyle {
  cinema(Duration(milliseconds: 3750)),
  comic(Duration(milliseconds: 3750)),
  fast(Duration(milliseconds: 1800));

  const StoryStyle(this.slide);

  /// Lo que dura cada diapositiva (8 diapositivas de cine ≈ 30 s).
  final Duration slide;
}

String storyStyleLabel(AppLocalizations t, StoryStyle s) => switch (s) {
  StoryStyle.cinema => t.memStyleCinema,
  StoryStyle.comic => t.memStyleComic,
  StoryStyle.fast => t.memStyleFast,
};

/// Todo lo que necesita la historia, ya calculado.
class StoryData {
  const StoryData({
    required this.title,
    required this.dates,
    required this.photos,
    required this.paths,
    required this.stats,
    required this.start,
  });

  /// "Madrid → Lisboa" o "Mi viaje".
  final String title;

  /// "22 oct – 25 oct".
  final String dates;
  final List<Memory> photos;

  /// Nombre de archivo → ruta completa en el móvil.
  final Map<String, String> paths;
  final TripStats stats;
  final DateTime start;
}

/// Hace la imagen de una foto para la página, [width] píxeles de ancho
/// (null si no se puede abrir).
typedef MemoryPicture = Future<String?> Function(Uint8List bytes, int width);

/// La de verdad: la foto pequeña, como PNG dentro del texto de la página.
Future<String?> memoryImage(Uint8List bytes, int width) async {
  try {
    final ui.Codec codec = await ui.instantiateImageCodec(
      bytes,
      targetWidth: width,
    );
    final ui.FrameInfo frame = await codec.getNextFrame();
    final ByteData? png = await frame.image.toByteData(
      format: ui.ImageByteFormat.png,
    );
    frame.image.dispose();
    codec.dispose();
    if (png == null) return null;
    return 'data:image/png;base64,${base64Encode(png.buffer.asUint8List())}';
  } on Object {
    // Una foto que no se puede abrir se queda sin imagen.
    return null;
  }
}

class MemoriesScreen extends StatefulWidget {
  const MemoriesScreen({super.key, this.image = memoryImage});

  final MemoryPicture image;

  /// La última conexión con la página (para las pruebas).
  static WebSceneBridge? lastBridge;

  @override
  State<MemoriesScreen> createState() => _MemoriesScreenState();
}

class _MemoriesScreenState extends State<MemoriesScreen> {
  late final AppServices _services = ServicesScope.of(context);
  final WebSceneBridge _bridge = MemoriesScreen.lastBridge = WebSceneBridge();

  // La página se lee una vez y se guarda (como String, no como Future).
  static String? _pageCache;
  String? _html;
  Map<String, Object?> _shown = <String, Object?>{};

  List<Memory> _items = <Memory>[];
  Map<String, String> _paths = <String, String>{};
  DateTime _start = DateTime.now();
  StoryStyle _style = StoryStyle.cinema;

  /// Las fotos ya hechas para la página: miniaturas (cuadrícula) y grandes
  /// (historia), por nombre de archivo.
  final Map<String, String> _thumbs = <String, String>{};
  final Map<String, String> _big = <String, String>{};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_open()));
  }

  Future<void> _open() async {
    try {
      _pageCache ??= await rootBundle.loadString(memoriesPage, cache: false);
    } on Object {
      return;
    }
    if (mounted) setState(() {});
    await _load();
  }

  Future<void> _load() async {
    final List<Memory> items = _services.memories.all();
    final Map<String, String> paths = <String, String>{
      for (final Memory m in items)
        m.file: await _services.memoryFiles.pathOf(m.file),
    };
    if (!mounted) return;
    setState(() {
      _items = items;
      _paths = paths;
      _start = _services.memories.tripStart(DateTime.now());
    });
    await _images();
  }

  /// Hace las fotos que faltan: pequeñas para la cuadrícula y algo más
  /// grandes para las de la historia.
  Future<void> _images() async {
    final Set<String> story = <String>{
      for (final Memory m in storyPhotos(_items, _start)) m.file,
    };
    bool changed = false;
    for (final Memory m in _items) {
      if (m.kind != MemoryKind.photo) continue;
      final bool needThumb = !_thumbs.containsKey(m.file);
      final bool needBig = story.contains(m.file) && !_big.containsKey(m.file);
      if (!needThumb && !needBig) continue;
      final Uint8List? bytes = await _services.memoryFiles.read(m.file);
      if (bytes == null) continue;
      if (needThumb) {
        final String? t = await widget.image(bytes, 200);
        if (t != null) _thumbs[m.file] = t;
      }
      if (needBig) {
        final String? b = await widget.image(bytes, 540);
        if (b != null) _big[m.file] = b;
      }
      changed = true;
    }
    if (changed && mounted) setState(() {});
  }

  StoryData _story(AppLocalizations t, String locale) {
    final DateTime now = DateTime.now();
    final TripStats stats = statsOf(
      _items,
      StampBook(_services.prefs).all(),
      _start,
      now,
    );
    final DateFormat day = DateFormat.MMMd(locale);
    return StoryData(
      // Como mucho 4 ciudades en el título; si no, no cabe.
      title: stats.cities.isEmpty
          ? t.memMyTrip
          : stats.cities.take(4).join(' → '),
      dates: '${day.format(_start)} – ${day.format(now)}',
      photos: storyPhotos(_items, _start),
      paths: _paths,
      stats: stats,
      start: _start,
    );
  }

  Future<void> _pickStart() async {
    final DateTime now = DateTime.now();
    final DateTime? got = await showDatePicker(
      context: context,
      initialDate: _start.isAfter(now) ? now : _start,
      firstDate: now.subtract(const Duration(days: 366)),
      lastDate: now,
    );
    if (got == null) return;
    await _services.memories.setTripStart(got);
    await _load();
  }

  /// Sin vídeo (el móvil no sabe grabarlo): las fotos y un texto resumen.
  Future<void> _shareStory(StoryData s) async {
    final AppLocalizations t = AppLocalizations.of(context);
    await _services.share(<String>[
      for (final Memory m in s.photos)
        if (s.paths[m.file] case final String p) p,
    ], text: t.memShareText(s.title, s.stats.days, s.stats.media));
  }

  /// Llega el vídeo que ha grabado la página: se guarda en tus Recuerdos
  /// ("save") o se comparte ("share", "group").
  Future<void> _video(String mode, String ext, String data) async {
    final AppLocalizations t = AppLocalizations.of(context);
    final StoryData s = _story(
      t,
      Localizations.localeOf(context).toLanguageTag(),
    );
    final Uint8List bytes;
    try {
      bytes = base64Decode(data);
    } on FormatException {
      return;
    }
    if (bytes.isEmpty || (ext != 'mp4' && ext != 'webm')) return;
    if (mode == 'save') {
      if (_items.length >= maxMemories) {
        _say(t.memFull);
        return;
      }
      final String name = 'story_${DateTime.now().microsecondsSinceEpoch}.$ext';
      await _services.memoryFiles.write(name, bytes);
      await _services.memories.add(
        Memory(file: name, kind: MemoryKind.video, at: DateTime.now()),
      );
      _say(t.memSavedHint);
      await _load();
      return;
    }
    // Para compartir: un archivo que se reescribe cada vez (no es un
    // recuerdo nuevo).
    final String path = await _services.memoryFiles.write(
      'story_share.$ext',
      bytes,
    );
    await _services.share(<String>[
      path,
    ], text: t.memShareText(s.title, s.stats.days, s.stats.media));
  }

  void _say(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _openMemory(Memory m) async {
    final AppLocalizations t = AppLocalizations.of(context);
    final String? path = _paths[m.file];
    final String? choice = await showModalBottomSheet<String>(
      context: context,
      useRootNavigator: true,
      builder: (BuildContext context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            ListTile(
              leading: const Icon(Icons.ios_share_rounded),
              title: Text(t.memShare),
              onTap: () => Navigator.pop(context, 'share'),
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline_rounded),
              title: Text(t.memDelete),
              onTap: () => Navigator.pop(context, 'delete'),
            ),
          ],
        ),
      ),
    );
    if (!mounted) return;
    if (choice == 'share' && path != null) {
      await _services.share(<String>[path]);
    } else if (choice == 'delete') {
      final bool? sure = await showDialog<bool>(
        context: context,
        builder: (BuildContext context) => AlertDialog(
          content: Text(t.memDeleteConfirm),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(t.memCancel),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(t.memDelete),
            ),
          ],
        ),
      );
      if (sure != true) return;
      await _services.memories.remove(m);
      _thumbs.remove(m.file);
      _big.remove(m.file);
      await _load();
    }
  }

  /// Lo que pide la página.
  void _onMessage(String msg) {
    final AppLocalizations t = AppLocalizations.of(context);
    final List<String> p = msg.split(':');
    final StoryData s = _story(
      t,
      Localizations.localeOf(context).toLanguageTag(),
    );
    switch (p.first) {
      case 'back':
        if (context.canPop()) context.pop();
      case 'style' when p.length > 1:
        final int i = int.tryParse(p[1]) ?? 0;
        setState(() => _style = StoryStyle.values[i.clamp(0, 2)]);
      case 'full':
        unawaited(
          Navigator.of(context).push(
            MaterialPageRoute<void>(
              fullscreenDialog: true,
              builder: (_) => StoryPlayer(story: s, style: _style),
            ),
          ),
        );
      case 'open' when p.length > 1:
        final int i = int.tryParse(p[1]) ?? -1;
        if (i >= 0 && i < _items.length) unawaited(_openMemory(_items[i]));
      case 'camera':
        unawaited(() async {
          await context.push(Routes.travelCamera);
          await _load();
        }());
      case 'start':
        unawaited(_pickStart());
      case 'empty':
        _say(t.memNoPhotos);
      case 'novideo':
        if (s.photos.isEmpty) {
          _say(t.memNoPhotos);
        } else if (p.length > 1 && p[1] == 'save') {
          _say(
            'Este móvil no sabe crear el vídeo. Puedes compartir las fotos.',
          );
        } else {
          unawaited(_shareStory(s));
        }
      case 'video' when p.length > 3:
        unawaited(_video(p[1], p[2], p[3]));
    }
  }

  Map<String, Object?> _data(AppLocalizations t) {
    final String locale = Localizations.localeOf(context).toLanguageTag();
    final StoryData s = _story(t, locale);
    final List<String> cities = s.stats.cities;
    final DateFormat long = DateFormat.MMMMEEEEd(locale);
    String part(DateTime at) => switch (dayPartOf(at)) {
      DayPart.morning => t.memMorning,
      DayPart.afternoon => t.memAfternoon,
      DayPart.sunset => t.memSunset,
      DayPart.night => t.memNight,
    };
    final List<Map<String, Object?>> shots = <Map<String, Object?>>[];
    for (final Memory m in s.photos) {
      final String? src = _big[m.file];
      if (src == null) continue;
      final DateTime at = m.at.toLocal();
      shots.add(<String, Object?>{
        'src': src,
        'lbl': <String>[
          t.memDayN(tripDay(s.start, at)),
          if (m.city case final String c) c.toUpperCase(),
        ].join(' · '),
        'sub': '${long.format(at)} · ${part(at)}',
        'color': storyCaptionColors[shots.length % storyCaptionColors.length],
      });
    }
    return <String, Object?>{
      'title': 'Tu viaje en 30 s',
      'sub': s.photos.isEmpty ? t.memNoPhotos : t.memStoryHint,
      'backTxt': MaterialLocalizations.of(context).backButtonTooltip,
      'from': cities.isEmpty ? '' : cities.first,
      'to': cities.length < 2 ? '' : cities.last,
      'dates': s.dates.toUpperCase(),
      'route': s.title,
      'shots': shots,
      'stats': <Object?>[
        <String, Object?>{'v': '${s.stats.days}', 'k': t.memDays},
        <String, Object?>{'v': '${s.stats.cities.length}', 'k': t.memCities},
        <String, Object?>{'v': '${s.stats.media}', 'k': t.memMedia},
        <String, Object?>{'v': '${s.stats.stamps}', 'k': t.memStamps},
      ],
      'names': <String>[
        s.title,
        for (final Map<String, Object?> shot in shots) '${shot['lbl']}',
        t.memStamps,
      ],
      'sceneTxt': t.memStory,
      'styles': <String>[
        for (final StoryStyle st in StoryStyle.values) storyStyleLabel(t, st),
      ],
      'style': _style.index,
      'durs': <int>[
        for (final StoryStyle st in StoryStyle.values) st.slide.inMilliseconds,
      ],
      'pauseTxt': t.memPause,
      'playTxt': t.memResume,
      'stylesTxt': t.memStory,
      'storyTxt': 'Crear historia',
      'storySub': 'Allí le pones la música que quieras',
      'makingTxt': 'Creando vídeo…',
      'saveTxt': 'Guardar vídeo',
      'groupTxt': 'Enviar al grupo',
      'listH': '${t.memTitle} · ${t.memCount(_items.length, maxMemories)}',
      'onlyHere': t.memOnlyHere,
      'cameraTxt': t.memCameraTitle,
      'startTxt': t.memTripStart(DateFormat.yMMMd(locale).format(s.start)),
      'emptyTxt': t.memEmpty,
      'grid': <Object?>[
        for (final Memory m in _items)
          <String, Object?>{
            'thumb': _thumbs[m.file] ?? '',
            'video': m.kind == MemoryKind.video,
            'label': m.kind == MemoryKind.video ? t.memVideo : t.memPhoto,
          },
      ],
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
    if (_html == null) {
      _html = memoriesPageWith(page, data);
    } else {
      // Solo lo que ha cambiado: las fotos no se mandan otra vez.
      final Map<String, Object?> diff = changedKeys(_shown, data);
      if (diff.isNotEmpty) unawaited(_bridge.run(memoriesPushScript(diff)));
    }
    _shown = data;
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

/// Las cuatro cifras del viaje.
class _Stats extends StatelessWidget {
  const _Stats({required this.stats, this.big = false});

  final TripStats stats;
  final bool big;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    final List<(int, String)> cells = <(int, String)>[
      (stats.days, t.memDays),
      (stats.cities.length, t.memCities),
      (stats.media, t.memMedia),
      (stats.stamps, t.memStamps),
    ];
    return Wrap(
      spacing: 16,
      runSpacing: 12,
      children: <Widget>[
        for (final (int n, String label) in cells)
          SizedBox(
            width: big ? 140 : 72,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  '$n',
                  style: TextStyle(
                    fontSize: big ? 44 : 22,
                    fontWeight: FontWeight.w900,
                    color: NomadColors.mint,
                  ),
                ),
                Text(label, style: const TextStyle(fontSize: 12)),
              ],
            ),
          ),
      ],
    );
  }
}

/// La historia a pantalla completa: portada, fotos y cifras, pasando solas.
/// Toca a la derecha para avanzar, a la izquierda para volver y mantén
/// pulsado para pausar (como en Instagram).
class StoryPlayer extends StatefulWidget {
  const StoryPlayer({super.key, required this.story, required this.style});

  final StoryData story;
  final StoryStyle style;

  @override
  State<StoryPlayer> createState() => _StoryPlayerState();
}

class _StoryPlayerState extends State<StoryPlayer>
    with SingleTickerProviderStateMixin {
  // Un AnimationController por diapositiva: cuando llega al final, pasa a la
  // siguiente. Se libera en dispose para no dejar nada corriendo.
  late final AnimationController _progress = AnimationController(
    vsync: this,
    duration: widget.style.slide,
  )..addStatusListener(_onStatus);
  int _index = 0;

  // Portada + fotos + cifras.
  int get _count => widget.story.photos.length + 2;

  @override
  void initState() {
    super.initState();
    unawaited(_progress.forward());
  }

  @override
  void dispose() {
    _progress.dispose();
    super.dispose();
  }

  void _onStatus(AnimationStatus s) {
    if (s == AnimationStatus.completed) _go(1);
  }

  void _go(int delta) {
    final int next = _index + delta;
    if (next >= _count) {
      Navigator.of(context).maybePop();
      return;
    }
    setState(() => _index = next.clamp(0, _count - 1));
    unawaited(_progress.forward(from: 0));
  }

  void _toggle() {
    if (_progress.isAnimating) {
      _progress.stop();
    } else {
      unawaited(_progress.forward());
    }
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    final StoryData s = widget.story;
    final Widget slide;
    if (_index == 0) {
      slide = _Cover(story: s);
    } else if (_index == _count - 1) {
      slide = Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                s.title,
                style: const TextStyle(
                  fontSize: 26,
                  fontWeight: FontWeight.w900,
                ),
              ),
              const SizedBox(height: 24),
              _Stats(stats: s.stats, big: true),
            ],
          ),
        ),
      );
    } else {
      final Memory m = s.photos[_index - 1];
      slide = _PhotoSlide(
        memory: m,
        path: s.paths[m.file],
        caption: [
          t.memDayN(tripDay(s.start, m.at.toLocal())),
          if (m.city case final String c) c.toUpperCase(),
        ].join(' · '),
        style: widget.style,
      );
    }
    final bool paused = !_progress.isAnimating;
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Stack(
          fit: StackFit.expand,
          children: <Widget>[
            // Cine: fundido suave entre diapositivas; Viñetas y Rápido: corte.
            AnimatedSwitcher(
              duration: widget.style == StoryStyle.cinema
                  ? const Duration(milliseconds: 500)
                  : Duration.zero,
              child: KeyedSubtree(key: ValueKey<int>(_index), child: slide),
            ),
            Row(
              children: <Widget>[
                Expanded(
                  child: GestureDetector(
                    behavior: HitTestBehavior.translucent,
                    onTap: () => _go(-1),
                    onLongPress: _toggle,
                  ),
                ),
                Expanded(
                  flex: 2,
                  child: GestureDetector(
                    behavior: HitTestBehavior.translucent,
                    onTap: () => _go(1),
                    onLongPress: _toggle,
                  ),
                ),
              ],
            ),
            Positioned(
              top: 8,
              left: 8,
              right: 8,
              child: Column(
                children: <Widget>[
                  // Una rayita por diapositiva, como en las historias.
                  AnimatedBuilder(
                    animation: _progress,
                    builder: (BuildContext context, _) => Row(
                      children: <Widget>[
                        for (int i = 0; i < _count; i++)
                          Expanded(
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 2,
                              ),
                              child: LinearProgressIndicator(
                                minHeight: 3,
                                value: i < _index
                                    ? 1
                                    : i == _index
                                    ? _progress.value
                                    : 0,
                                color: Colors.white,
                                backgroundColor: Colors.white24,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  Row(
                    children: <Widget>[
                      IconButton(
                        tooltip: paused ? t.memResume : t.memPause,
                        onPressed: _toggle,
                        icon: Icon(
                          paused
                              ? Icons.play_arrow_rounded
                              : Icons.pause_rounded,
                        ),
                      ),
                      const Spacer(),
                      IconButton(
                        tooltip: t.memClose,
                        onPressed: () => Navigator.of(context).maybePop(),
                        icon: const Icon(Icons.close_rounded),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Cover extends StatelessWidget {
  const _Cover({required this.story});

  final StoryData story;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: <Color>[Color(0xFF0B1217), Color(0xFF16323A)],
        ),
      ),
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const Icon(
                Icons.flight_rounded,
                size: 48,
                color: NomadColors.mint,
              ),
              const SizedBox(height: 16),
              Text(
                story.title,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 30,
                  fontWeight: FontWeight.w900,
                ),
              ),
              const SizedBox(height: 8),
              Text(story.dates, style: const TextStyle(color: Colors.white70)),
            ],
          ),
        ),
      ),
    );
  }
}

class _PhotoSlide extends StatelessWidget {
  const _PhotoSlide({
    required this.memory,
    required this.path,
    required this.caption,
    required this.style,
  });

  final Memory memory;
  final String? path;
  final String caption;
  final StoryStyle style;

  @override
  Widget build(BuildContext context) {
    final String? p = path;
    final Widget photo = p == null
        ? const ColoredBox(color: NomadColors.surface)
        : Image.file(
            File(p),
            fit: BoxFit.cover,
            errorBuilder: (_, _, _) =>
                const ColoredBox(color: NomadColors.surface),
          );
    if (style == StoryStyle.comic) {
      // Viñetas: la foto con marco blanco y el pie en un bocadillo amarillo.
      return Padding(
        padding: const EdgeInsets.fromLTRB(20, 72, 20, 40),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Expanded(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.white, width: 6),
                ),
                child: photo,
              ),
            ),
            const SizedBox(height: 12),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 6,
                ),
                color: const Color(0xFFFFE066),
                child: Text(
                  caption,
                  style: const TextStyle(
                    color: Colors.black,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
            ),
          ],
        ),
      );
    }
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        photo,
        PositionedDirectional(
          start: 20,
          bottom: 40,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: const Color(0xB30B1217),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              caption,
              style: const TextStyle(
                color: NomadColors.mint,
                fontWeight: FontWeight.w900,
                letterSpacing: 1.5,
              ),
            ),
          ),
        ),
      ],
    );
  }
}
