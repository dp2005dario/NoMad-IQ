// "Mi álbum de cromos" de Inicio (maqueta "ECLIPTA Inicio").
//
// Un libro cerrado con la tapa "CROMOS". Al tocarlo, la tapa gira y se abre
// en dos páginas; se pasa página deslizando o con las flechas (la hoja gira
// en 3D). Arriba de cada página, el país; debajo, 4 huecos: tus cromos y
// "?" en los que aún faltan.
//
// Los cromos son de verdad: los sellos que consigues al hacer una foto a un
// monumento con la cámara (camera/stamps.dart). El país sale del aeropuerto
// más cercano, igual que en el Pasaporte (passport/passport.dart). La
// rareza (por la edad del monumento) decide el color del cromo.
//
// Con "reducir movimiento" no hay giros: las páginas cambian sin animación.
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/router.dart';
import '../../core/services.dart';
import '../../core/theme.dart';
import '../../l10n/generated/app_localizations.dart';
import '../../widgets/flyra_avatar.dart';
import '../camera/stamps.dart';
import '../passport/passport.dart';
import '../route/flight3d.dart' show CountryCodes;
import '../route/world_data.dart';

/// Huecos por página (como en la maqueta: 2 × 2).
const int albumSlots = 4;

/// Una página del álbum: título y 4 huecos (null = "?").
class AlbumPage {
  const AlbumPage({required this.title, required this.cards});

  final String title;
  final List<Stamp?> cards;
}

/// Reparte las páginas del Pasaporte (una por país) en páginas de 4 huecos.
/// Siempre hay un número PAR de páginas (el libro abierto enseña dos) y como
/// mínimo dos.
List<AlbumPage> albumPagesOf(
  List<PassportPage> pages, {
  required String Function(PassportPage) titleOf,
}) {
  final List<AlbumPage> out = <AlbumPage>[];
  for (final PassportPage p in pages) {
    final String title = titleOf(p);
    for (int i = 0; i < p.stamps.length; i += albumSlots) {
      final List<Stamp?> four = <Stamp?>[
        for (int j = i; j < i + albumSlots; j++)
          j < p.stamps.length ? p.stamps[j] : null,
      ];
      out.add(AlbumPage(title: title, cards: four));
    }
  }
  while (out.length < 2 || out.length.isOdd) {
    out.add(AlbumPage(title: '', cards: List<Stamp?>.filled(albumSlots, null)));
  }
  return out;
}

class HomeAlbum extends StatefulWidget {
  const HomeAlbum({super.key});

  @override
  State<HomeAlbum> createState() => _HomeAlbumState();
}

class _HomeAlbumState extends State<HomeAlbum> with TickerProviderStateMixin {
  // Tamaño de UNA página (el libro abierto mide el doble de ancho).
  static const double _w = 170;
  static const double _h = 236;

  late final AnimationController _cover = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  );
  late final AnimationController _leaf = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 850),
  );

  List<Stamp> _stamps = const <Stamp>[];
  List<PassportPage>? _pages; // null = aún agrupando por país
  int _cur = 0; // página de la izquierda (par)
  int _to = 0; // a dónde va la hoja que gira
  bool _swiped = false; // tras el primer giro se quita "Desliza..."
  double _dragDx = 0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_pages == null) _load(StampBook(ServicesScope.of(context).prefs).all());
  }

  void _load(List<Stamp> stamps) {
    _stamps = stamps;
    if (_stamps.isEmpty) {
      _pages = const <PassportPage>[];
      return;
    }
    // Agrupar por país necesita los aeropuertos (se cargan una vez).
    unawaited(() async {
      List<PassportPage> pages;
      try {
        final WorldData world = await WorldData.load();
        final CountryCodes codes = await CountryCodes.load();
        pages = pagesOf(_stamps, airports: world.airports.all, codes: codes);
      } on Object {
        pages = pagesOf(_stamps);
      }
      if (mounted) setState(() => _pages = pages);
    }());
  }

  @override
  void dispose() {
    _cover.dispose();
    _leaf.dispose();
    super.dispose();
  }

  bool get _open => _cover.value > 0 || _cover.isAnimating;

  Duration _speed(Duration d) =>
      MediaQuery.disableAnimationsOf(context) ? Duration.zero : d;

  void _openBook() {
    if (_cover.value > 0) return;
    _cover.duration = _speed(const Duration(milliseconds: 900));
    unawaited(_cover.forward());
  }

  void _closeBook() {
    _cover.duration = _speed(const Duration(milliseconds: 900));
    unawaited(_cover.reverse().then((_) => setState(() => _cur = 0)));
  }

  void _flip(int dir, int total) {
    if (_cover.value < 1 || _leaf.isAnimating) return;
    final int n = _cur + dir * 2;
    if (n < 0 || n > total - 2) return;
    setState(() {
      _swiped = true;
      _to = n;
    });
    _leaf.duration = _speed(const Duration(milliseconds: 850));
    unawaited(
      _leaf.forward(from: 0).then((_) {
        if (!mounted) return;
        setState(() => _cur = n);
        _leaf.value = 0;
      }),
    );
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    // Si al volver de la cámara hay sellos nuevos, se rehace el álbum.
    final List<Stamp> now = StampBook(ServicesScope.of(context).prefs).all();
    if (now.length != _stamps.length) _load(now);
    final List<PassportPage> grouped = _pages ?? const <PassportPage>[];
    final List<AlbumPage> pages = albumPagesOf(
      grouped,
      titleOf: (PassportPage p) {
        final String? c = p.country;
        if (c == null) return t.passportElsewhere;
        final String city = p.cities.isEmpty ? c : p.cities.first;
        return '${flagOf(c)} $city';
      },
    );
    final int total = pages.length;
    if (_cur > total - 2) _cur = 0;
    final TextTheme text = Theme.of(context).textTheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        // El libro. Se escala si la pantalla es estrecha.
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onHorizontalDragStart: (_) => _dragDx = 0,
          onHorizontalDragUpdate: (DragUpdateDetails d) =>
              _dragDx += d.delta.dx,
          onHorizontalDragEnd: (_) {
            if (_dragDx < -30) _flip(1, total);
            if (_dragDx > 30) _flip(-1, total);
          },
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: SizedBox(
              width: _w * 2 + 8,
              height: _h + 16,
              child: AnimatedBuilder(
                animation: Listenable.merge(<Listenable>[_cover, _leaf]),
                builder: (BuildContext context, Widget? _) =>
                    _book(t, pages, total),
              ),
            ),
          ),
        ),
        AnimatedBuilder(
          animation: _cover,
          builder: (BuildContext context, Widget? _) {
            if (!_open) {
              return Column(
                children: <Widget>[
                  const SizedBox(height: 14),
                  Text(
                    t.homeAlbumTap(_stamps.length),
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: NomadColors.textMuted,
                      fontSize: 12.5,
                    ),
                  ),
                  if (_stamps.isEmpty) ...<Widget>[
                    const SizedBox(height: 4),
                    Text(
                      t.homeAlbumHowTo,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: NomadColors.textMuted,
                        fontSize: 12.5,
                      ),
                    ),
                  ],
                ],
              );
            }
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                const SizedBox(height: 14),
                Row(
                  children: <Widget>[
                    Expanded(
                      child: Text(
                        t.homeAlbumPages(_cur + 1, _cur + 2, total),
                        style: text.labelLarge?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    OutlinedButton(
                      onPressed: _closeBook,
                      style: OutlinedButton.styleFrom(
                        shape: const StadiumBorder(),
                        visualDensity: VisualDensity.compact,
                        // El tema pone los botones a todo lo ancho: aquí no.
                        minimumSize: const Size(0, 36),
                      ),
                      child: Text(t.homeAlbumClose),
                    ),
                  ],
                ),
                if (!_swiped && total > 2) ...<Widget>[
                  const SizedBox(height: 10),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: <Widget>[
                      const Icon(
                        Icons.swipe_left_rounded,
                        size: 20,
                        color: Color(0xFF3DDC97),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        t.homeAlbumSwipe,
                        style: const TextStyle(
                          color: Color(0xFF3DDC97),
                          fontWeight: FontWeight.w700,
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            );
          },
        ),
        const SizedBox(height: 14),
        // "Cromos con amigos": la liga y los cambios.
        Material(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(20),
          child: InkWell(
            borderRadius: BorderRadius.circular(20),
            onTap: () => context.push(Routes.cards),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              child: Row(
                children: <Widget>[
                  const CircleAvatar(
                    radius: 17,
                    backgroundColor: Color(0x333DDC97),
                    child: Icon(
                      Icons.groups_rounded,
                      size: 20,
                      color: Color(0xFF3DDC97),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          t.cardsTitle,
                          style: const TextStyle(
                            fontWeight: FontWeight.w700,
                            fontSize: 14,
                          ),
                        ),
                        Text(
                          t.cardsSubtitle,
                          style: const TextStyle(
                            color: NomadColors.textMuted,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const Icon(
                    Icons.chevron_right_rounded,
                    color: Color(0xFF3DDC97),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// El libro: página derecha, hoja que gira, tapa y flechas.
  Widget _book(AppLocalizations t, List<AlbumPage> pages, int total) {
    final double c = Curves.easeInOutCubic.transform(_cover.value);
    final double l = Curves.easeInOutCubic.transform(_leaf.value);
    final bool turning = _leaf.value > 0 && _leaf.value < 1;
    final bool forward = _to > _cur;
    // Cerrado, el libro (una página de ancho) está en el centro; abierto, se
    // corre media página para que las dos páginas queden centradas.
    final double left = _w / 2 + 4 + c * _w / 2;

    Widget page(int i, {bool leftSide = false}) => _Page(
      page: i < pages.length ? pages[i] : null,
      number: i + 1,
      leftSide: leftSide,
    );

    // La hoja: gira sobre el lomo (borde izquierdo de la página derecha).
    Widget leaf(double angle, Widget front, Widget back) {
      final bool showBack = angle.abs() > math.pi / 2;
      return Transform(
        alignment: Alignment.centerLeft,
        transform: Matrix4.identity()
          ..setEntry(3, 2, 0.0012)
          ..rotateY(angle),
        child: showBack
            ? Transform(
                alignment: Alignment.center,
                transform: Matrix4.identity()..rotateY(math.pi),
                child: back,
              )
            : front,
      );
    }

    return Stack(
      clipBehavior: Clip.none,
      children: <Widget>[
        // Página derecha de abajo (la que queda al girar la hoja).
        Positioned(
          left: left,
          top: 8,
          width: _w,
          height: _h,
          child: page(turning && forward ? _to + 1 : _cur + 1),
        ),
        // Página izquierda (detrás de la tapa abierta).
        if (c >= 1)
          Positioned(
            left: left - _w,
            top: 8,
            width: _w,
            height: _h,
            child: page(turning && !forward ? _to : _cur, leftSide: true),
          ),
        // La hoja que gira.
        if (turning)
          Positioned(
            left: left,
            top: 8,
            width: _w,
            height: _h,
            child: forward
                ? leaf(-math.pi * l, page(_cur + 1), page(_to, leftSide: true))
                : leaf(
                    -math.pi * (1 - l),
                    page(_to + 1),
                    page(_cur, leftSide: true),
                  ),
          ),
        // La tapa: por delante "CROMOS"; al girar, por detrás, la página 1.
        if (c < 1)
          Positioned(
            left: left,
            top: 8,
            width: _w,
            height: _h,
            child: leaf(
              -math.pi * c,
              _Cover(
                title: t.homeAlbumCover,
                hint: t.homeAlbumOpen,
                semantics: t.homeAlbumOpenSem,
                onTap: _openBook,
              ),
              page(_cur, leftSide: true),
            ),
          ),
        // Flechas (solo con el libro abierto).
        if (c >= 1) ...<Widget>[
          Positioned(
            left: left - _w,
            top: 8 + _h / 2 - 20,
            child: _Arrow(
              icon: Icons.chevron_left_rounded,
              tooltip: t.homeAlbumPrev,
              onTap: _cur <= 0 ? null : () => _flip(-1, total),
            ),
          ),
          Positioned(
            left: left + _w - 34,
            top: 8 + _h / 2 - 20,
            child: _Arrow(
              icon: Icons.chevron_right_rounded,
              tooltip: t.homeAlbumNext,
              onTap: _cur >= total - 2 ? null : () => _flip(1, total),
            ),
          ),
        ],
      ],
    );
  }
}

class _Cover extends StatelessWidget {
  const _Cover({
    required this.title,
    required this.hint,
    required this.semantics,
    required this.onTap,
  });

  final String title;
  final String hint;
  final String semantics;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: semantics,
      excludeSemantics: true,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          decoration: BoxDecoration(
            borderRadius: const BorderRadius.horizontal(
              left: Radius.circular(4),
              right: Radius.circular(14),
            ),
            gradient: const LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: <Color>[Color(0xFF1D3D52), Color(0xFF2C2A75)],
            ),
            border: Border.all(color: const Color(0xFF4A5AA0)),
            boxShadow: const <BoxShadow>[
              BoxShadow(
                color: Color(0x88000000),
                blurRadius: 40,
                offset: Offset(0, 20),
              ),
            ],
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              const FlyraAvatar(size: 64),
              const SizedBox(height: 10),
              Text(
                title,
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w800,
                  fontSize: 16,
                  letterSpacing: 2,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                hint,
                style: const TextStyle(color: Color(0xFF3DDC97), fontSize: 11),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Una página de papel con su título, 4 huecos y el número abajo.
class _Page extends StatelessWidget {
  const _Page({
    required this.page,
    required this.number,
    required this.leftSide,
  });

  final AlbumPage? page;
  final int number;
  final bool leftSide;

  @override
  Widget build(BuildContext context) {
    final AlbumPage? p = page;
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 10, 10, 22),
      decoration: BoxDecoration(
        borderRadius: leftSide
            ? const BorderRadius.horizontal(
                left: Radius.circular(14),
                right: Radius.circular(4),
              )
            : const BorderRadius.horizontal(
                left: Radius.circular(4),
                right: Radius.circular(14),
              ),
        gradient: LinearGradient(
          begin: leftSide ? Alignment.centerRight : Alignment.centerLeft,
          end: leftSide ? Alignment.centerLeft : Alignment.centerRight,
          colors: const <Color>[Color(0xFFD9D1BA), Color(0xFFF0EAD9)],
          stops: const <double>[0, 0.1],
        ),
        boxShadow: const <BoxShadow>[
          BoxShadow(
            color: Color(0x88000000),
            blurRadius: 40,
            offset: Offset(0, 20),
          ),
        ],
      ),
      child: Stack(
        children: <Widget>[
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Text(
                (p?.title ?? '').toUpperCase(),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Color(0xFF2A2418),
                  fontWeight: FontWeight.w800,
                  fontSize: 10,
                  letterSpacing: 0.8,
                ),
              ),
              const SizedBox(height: 6),
              Expanded(
                child: GridView.count(
                  crossAxisCount: 2,
                  mainAxisSpacing: 6,
                  crossAxisSpacing: 6,
                  childAspectRatio: 3 / 3.7,
                  physics: const NeverScrollableScrollPhysics(),
                  padding: EdgeInsets.zero,
                  children: <Widget>[
                    for (final Stamp? s
                        in p?.cards ?? List<Stamp?>.filled(albumSlots, null))
                      _Card(stamp: s),
                  ],
                ),
              ),
            ],
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: -16,
            child: Text(
              '$number',
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Color(0xFF8A7E60),
                fontWeight: FontWeight.w700,
                fontSize: 10,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Un cromo (color según lo raro que es) o un hueco "?" si falta.
class _Card extends StatelessWidget {
  const _Card({required this.stamp});

  final Stamp? stamp;

  @override
  Widget build(BuildContext context) {
    final Stamp? s = stamp;
    if (s == null) {
      return Container(
        alignment: Alignment.center,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(7),
          border: Border.all(color: const Color(0xFFB8AE92), width: 1.5),
        ),
        child: const Text(
          '?',
          style: TextStyle(
            color: Color(0xFFB8AE92),
            fontWeight: FontWeight.w800,
            fontSize: 18,
          ),
        ),
      );
    }
    final List<Color> colors = switch (rarityOf(s.year)) {
      Rarity.legendary => const <Color>[Color(0xFF5A3FD0), Color(0xFF9B7BFF)],
      Rarity.epic => const <Color>[Color(0xFFE46A45), Color(0xFFFF8A65)],
      Rarity.rare => const <Color>[Color(0xFF2D6F9C), Color(0xFF58B4E6)],
      Rarity.common => const <Color>[Color(0xFF1FA874), Color(0xFF3DDC97)],
    };
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(7),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: colors,
        ),
        boxShadow: const <BoxShadow>[
          BoxShadow(
            color: Color(0x33000000),
            blurRadius: 5,
            offset: Offset(0, 2),
          ),
        ],
      ),
      child: Stack(
        children: <Widget>[
          const Center(
            child: Icon(
              Icons.account_balance_rounded,
              color: Colors.white,
              size: 24,
            ),
          ),
          Positioned(
            left: 2,
            right: 2,
            bottom: 3,
            child: Text(
              s.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w700,
                fontSize: 7.5,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Arrow extends StatelessWidget {
  const _Arrow({required this.icon, required this.tooltip, this.onTap});

  final IconData icon;
  final String tooltip;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: onTap == null ? 0.25 : 1,
      child: IconButton(
        tooltip: tooltip,
        onPressed: onTap,
        style: IconButton.styleFrom(
          backgroundColor: const Color(0xCC0B1217),
          side: const BorderSide(color: Color(0x55FFFFFF)),
          fixedSize: const Size(34, 34),
          minimumSize: const Size(34, 34),
          padding: EdgeInsets.zero,
        ),
        icon: Icon(icon, color: Colors.white, size: 18),
      ),
    );
  }
}
