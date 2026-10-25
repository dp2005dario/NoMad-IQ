// Recuerdos (maqueta "Recuerdos"): tus fotos y vídeos del viaje y la
// "historia" que se monta sola: portada con la ruta y las fechas, hasta 6
// fotos con "DÍA N · CIUDAD" y al final las cifras (días, ciudades, fotos,
// sellos nuevos).
//
// La historia se reproduce DENTRO de la app (como las historias de
// Instagram). Para compartirla se mandan las fotos y un texto resumen por el
// menú del móvil: montar un vídeo en el móvil necesitaría un codificador
// pesado (decenas de MB más en la app), y así sale gratis y rápido.
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../core/router.dart';
import '../../core/services.dart';
import '../../core/theme.dart';
import '../../l10n/generated/app_localizations.dart';
import '../camera/stamps.dart';
import 'memories.dart';

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

class MemoriesScreen extends StatefulWidget {
  const MemoriesScreen({super.key});

  @override
  State<MemoriesScreen> createState() => _MemoriesScreenState();
}

class _MemoriesScreenState extends State<MemoriesScreen> {
  late final AppServices _services = ServicesScope.of(context);
  List<Memory> _items = <Memory>[];
  Map<String, String> _paths = <String, String>{};
  DateTime _start = DateTime.now();
  StoryStyle _style = StoryStyle.cinema;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_load()));
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

  Future<void> _shareStory(StoryData s) async {
    final AppLocalizations t = AppLocalizations.of(context);
    await _services.share(<String>[
      for (final Memory m in s.photos)
        if (s.paths[m.file] case final String p) p,
    ], text: t.memShareText(s.title, s.stats.days, s.stats.media));
  }

  Future<void> _open(Memory m) async {
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
      await _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    final String locale = Localizations.localeOf(context).toLanguageTag();
    final StoryData story = _story(t, locale);
    return Scaffold(
      appBar: AppBar(title: Text(t.memTitle)),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () async {
          await context.push(Routes.travelCamera);
          await _load();
        },
        icon: const Icon(Icons.photo_camera_rounded),
        label: Text(t.memCameraTitle),
      ),
      body: CustomScrollView(
        slivers: <Widget>[
          SliverPadding(
            padding: const EdgeInsets.all(16),
            sliver: SliverList.list(
              children: <Widget>[
                _StoryCard(
                  story: story,
                  style: _style,
                  onStyle: (StoryStyle s) => setState(() => _style = s),
                  onStart: () => unawaited(_pickStart()),
                  onPlay: story.photos.isEmpty
                      ? null
                      : () => Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            fullscreenDialog: true,
                            builder: (_) =>
                                StoryPlayer(story: story, style: _style),
                          ),
                        ),
                  onShare: story.photos.isEmpty
                      ? null
                      : () => unawaited(_shareStory(story)),
                ),
                const SizedBox(height: 16),
                Text(
                  '${t.memTitle} · ${t.memCount(_items.length, maxMemories)}',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 4),
                Text(
                  t.memOnlyHere,
                  style: const TextStyle(color: NomadColors.textMuted),
                ),
                const SizedBox(height: 12),
                if (_items.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 24),
                    child: Text(t.memEmpty, textAlign: TextAlign.center),
                  ),
              ],
            ),
          ),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 96),
            sliver: SliverGrid.builder(
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 3,
                mainAxisSpacing: 4,
                crossAxisSpacing: 4,
              ),
              itemCount: _items.length,
              itemBuilder: (BuildContext context, int i) {
                final Memory m = _items[i];
                return _Thumb(
                  memory: m,
                  path: _paths[m.file],
                  onTap: () => unawaited(_open(m)),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _StoryCard extends StatelessWidget {
  const _StoryCard({
    required this.story,
    required this.style,
    required this.onStyle,
    required this.onStart,
    required this.onPlay,
    required this.onShare,
  });

  final StoryData story;
  final StoryStyle style;
  final ValueChanged<StoryStyle> onStyle;
  final VoidCallback onStart;
  final VoidCallback? onPlay;
  final VoidCallback? onShare;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    final String locale = Localizations.localeOf(context).toLanguageTag();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(t.memStory, style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 4),
            Text(
              story.photos.isEmpty ? t.memNoPhotos : t.memStoryHint,
              style: const TextStyle(color: NomadColors.textMuted),
            ),
            const SizedBox(height: 12),
            Text(
              story.title,
              style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
            ),
            Text(story.dates),
            const SizedBox(height: 12),
            _Stats(stats: story.stats),
            const SizedBox(height: 12),
            ActionChip(
              avatar: const Icon(Icons.event_rounded, size: 18),
              label: Text(
                t.memTripStart(DateFormat.yMMMd(locale).format(story.start)),
              ),
              onPressed: onStart,
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: <Widget>[
                for (final StoryStyle s in StoryStyle.values)
                  ChoiceChip(
                    selected: s == style,
                    label: Text(storyStyleLabel(t, s)),
                    onSelected: (_) => onStyle(s),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: <Widget>[
                Expanded(
                  child: FilledButton.icon(
                    onPressed: onPlay,
                    icon: const Icon(Icons.play_arrow_rounded),
                    label: Text(t.memPlay),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.outlined(
                  tooltip: t.memShareStory,
                  onPressed: onShare,
                  icon: const Icon(Icons.ios_share_rounded),
                ),
              ],
            ),
          ],
        ),
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

class _Thumb extends StatelessWidget {
  const _Thumb({required this.memory, required this.path, required this.onTap});

  final Memory memory;
  final String? path;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    final String? p = path;
    final bool video = memory.kind == MemoryKind.video;
    return Semantics(
      button: true,
      label: video ? t.memVideo : t.memPhoto,
      child: InkWell(
        onTap: onTap,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: Stack(
            fit: StackFit.expand,
            children: <Widget>[
              if (!video && p != null)
                Image.file(
                  File(p),
                  fit: BoxFit.cover,
                  // Miniatura pequeña: no carga la foto entera en memoria.
                  cacheWidth: 240,
                  errorBuilder: (_, _, _) =>
                      const ColoredBox(color: NomadColors.surfaceHigh),
                )
              else
                const ColoredBox(color: NomadColors.surfaceHigh),
              if (video)
                const Center(
                  child: Icon(Icons.play_circle_fill_rounded, size: 36),
                ),
            ],
          ),
        ),
      ),
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
