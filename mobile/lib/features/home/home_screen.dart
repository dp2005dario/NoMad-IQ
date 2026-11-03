// Inicio (maqueta "ECLIPTA Inicio"):
//   1. Arriba, "ECLIPTA" y la ciudad donde estás (si el GPS ya tiene
//      permiso).
//   2. Flyra en grande: una bola que "respira" con ondas. TOCARLA abre el
//      chat; MANTENERLA PULSADA es hablarle (el micro del móvil escucha y la
//      pregunta llega al chat). Debajo, Flyra se presenta palabra a palabra
//      y una caja para escribirle.
//   3. "Todo en ECLIPTA": un carrusel infinito de cuadrados con foto que se
//      inclinan en 3D al deslizar (el del centro, grande y nítido).
//   4. "Mi pasaporte": se rellena escaneando pasaporte y DNI.
//   5. "Mi álbum de cromos": un libro que se abre y pasa páginas.
//   6. El SOS: un cuarto de acero que hay que mantener pulsado 2 s.
//   7. Atajos que aún no están en el carrusel (cromos, sellos...).
//
// Animaciones: duran un rato y se paran (no gastan batería sin fin) y con
// "reducir movimiento" del móvil no hay ninguna.
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/router.dart';
import 'home_album.dart';
import 'home_sos.dart';
import 'my_passport.dart';
import '../../core/services.dart';
import '../../core/theme.dart';
import '../../l10n/generated/app_localizations.dart';
import '../../widgets/flyra_avatar.dart';
import '../map/geo.dart';
import '../map/location.dart' show LocationAccess;
import '../money/money_screen.dart' show MoneyTab;
import '../route/geo.dart' show LatLon;
import '../route/world_data.dart';
import '../sos/where_am_i.dart' show nearestAirport;
import '../visa/visa_data.dart' show CountryNames;

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    final TextTheme text = Theme.of(context).textTheme;
    return Scaffold(
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(0, 16, 0, 120),
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Row(
                children: <Widget>[
                  const Text(
                    'ECLIPTA',
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 3,
                    ),
                  ),
                  const Spacer(),
                  // Ajustes y Avisos están en la barra de abajo (pestaña
                  // Ajustes), no aquí: así Inicio es igual que la maqueta.
                  const _WhereChip(),
                ],
              ),
            ),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 20),
              child: _FlyraHero(),
            ),
            const SizedBox(height: 28),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  // Como la maqueta: una línea pequeña en mayúsculas y el
                  // título grande debajo.
                  Text(
                    t.homeAllTitle.toUpperCase(),
                    style: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 1.3,
                      color: NomadColors.textMuted,
                    ),
                  ),
                  Text(t.homeAllSub, style: text.titleLarge),
                ],
              ),
            ),
            const _Carousel(),
            const SizedBox(height: 28),
            // "Mi pasaporte": se rellena escaneando pasaporte y DNI.
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Text(
                    t.homePassEyebrow.toUpperCase(),
                    style: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 1.3,
                      color: NomadColors.textMuted,
                    ),
                  ),
                  Text(t.homePassTitle, style: text.titleLarge),
                  const SizedBox(height: 12),
                  const HomePassport(),
                ],
              ),
            ),
            const SizedBox(height: 36),
            // "Mi álbum de cromos": los sellos de los monumentos.
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Text(
                    t.homeAlbumEyebrow.toUpperCase(),
                    style: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 1.3,
                      color: NomadColors.textMuted,
                    ),
                  ),
                  Text(t.homeAlbumTitle, style: text.titleLarge),
                  const SizedBox(height: 12),
                  const HomeAlbum(),
                ],
              ),
            ),
            const SizedBox(height: 36),
            // El SOS de la maqueta: un cuarto de acero; mantener 2 s.
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 20),
              child: HomeSos(),
            ),
            const SizedBox(height: 20),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Text(t.shortcutsTitle, style: text.titleLarge),
            ),
            const SizedBox(height: 12),
            // Rejilla que se adapta: 2 columnas en móvil, más en tablet. La
            // altura de cada atajo NO es fija: con letra grande (accesibilidad)
            // o escrituras altas (árabe, hindi) crece en vez de cortarse.
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: LayoutBuilder(
                builder: (BuildContext context, BoxConstraints box) {
                  const double gap = 12;
                  final int columns = (box.maxWidth / 200).floor().clamp(2, 6);
                  final double width =
                      (box.maxWidth - gap * (columns - 1)) / columns;
                  final List<Widget> tiles = <Widget>[
                    // Preguntarle a Flyra en voz alta (o escrito).
                    _Shortcut(
                      icon: Icons.mic_rounded,
                      color: NomadColors.group,
                      label: t.voiceTitle,
                      onTap: () => context.push(Routes.voice),
                    ),
                    // Liga y cambios de cromos con tus amigos.
                    _Shortcut(
                      icon: Icons.style_rounded,
                      color: NomadColors.group,
                      label: t.cardsTitle,
                      onTap: () => context.push(Routes.cards),
                    ),
                    // La carta del restaurante, traducida y explicada.
                    _Shortcut(
                      icon: Icons.restaurant_menu_rounded,
                      color: NomadColors.money,
                      label: t.menuTitle,
                      onTap: () => context.push(Routes.menu),
                    ),
                    // Los sellos de los monumentos que reconoce la cámara.
                    _Shortcut(
                      icon: Icons.approval_rounded,
                      color: const Color(0xFFE9C46A),
                      label: t.passportTitle,
                      onTap: () => context.push(Routes.passport),
                    ),
                  ];
                  return Wrap(
                    spacing: gap,
                    runSpacing: gap,
                    children: <Widget>[
                      for (final Widget tile in tiles)
                        SizedBox(width: width, child: tile),
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Flyra en grande: la bola que respira, las ondas, la pista y la caja.
class _FlyraHero extends StatefulWidget {
  const _FlyraHero();

  @override
  State<_FlyraHero> createState() => _FlyraHeroState();
}

class _FlyraHeroState extends State<_FlyraHero>
    with SingleTickerProviderStateMixin {
  late final AppServices _services = ServicesScope.of(context);

  // Una "respiración" dura 5 s (2,5 s de ida y 2,5 de vuelta). Se repite
  // unas cuantas veces al abrir Inicio y luego Flyra se queda quieta.
  late final AnimationController _breath = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2500),
  );
  final TextEditingController _input = TextEditingController();
  bool _listening = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      _breath.stop();
    } else if (!_breath.isAnimating && _breath.value == 0) {
      unawaited(_breath.repeat(reverse: true, count: 8));
    }
  }

  @override
  void dispose() {
    if (_listening) unawaited(_services.speechInput.stop());
    _breath.dispose();
    _input.dispose();
    super.dispose();
  }

  /// Abre el chat (con la pregunta ya escrita, si la hay).
  void _openChat([String? question]) {
    final String q = (question ?? '').trim();
    unawaited(context.push(Routes.flyra(question: q.isEmpty ? null : q)));
  }

  /// Mantener pulsada la bola: escucha en el idioma de la app.
  Future<void> _holdStart() async {
    final String lang = Localizations.localeOf(context).languageCode;
    setState(() => _listening = true);
    final String? heard = await _services.speechInput.listen(lang);
    if (!mounted) return;
    setState(() => _listening = false);
    if (heard != null && heard.trim().isNotEmpty) _openChat(heard);
  }

  Future<void> _holdEnd() async {
    if (_listening) await _services.speechInput.stop();
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    return Column(
      children: <Widget>[
        Semantics(
          // container: un nodo propio (si no, se junta con la caja de abajo).
          container: true,
          button: true,
          label: t.talkToFlyra,
          hint: t.homeHoldToTalk,
          excludeSemantics: true,
          child: GestureDetector(
            onTap: _openChat,
            onLongPressStart: (_) => unawaited(_holdStart()),
            onLongPressEnd: (_) => unawaited(_holdEnd()),
            child: SizedBox.square(
              dimension: 240,
              child: AnimatedBuilder(
                animation: _breath,
                builder: (BuildContext context, Widget? _) =>
                    _Orb(breath: _breath.value, listening: _listening),
              ),
            ),
          ),
        ),
        _Greeting(text: t.homeFlyraHello),
        const SizedBox(height: 6),
        Text(
          _listening ? t.voiceListening : t.homeHoldToTalk,
          style: Theme.of(context).textTheme.titleMedium,
        ),
        Text(
          t.homeHearsYou,
          style: const TextStyle(color: NomadColors.textMuted, fontSize: 12.5),
        ),
        const SizedBox(height: 12),
        // La caja: escribir y enviar abre el chat con la pregunta.
        TextField(
          controller: _input,
          textInputAction: TextInputAction.send,
          onSubmitted: (String v) {
            _input.clear();
            _openChat(v);
          },
          decoration: InputDecoration(
            hintText: t.homeWriteFlyra,
            filled: true,
            fillColor: NomadColors.surfaceHigh,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(20),
              borderSide: BorderSide.none,
            ),
            suffixIcon: IconButton(
              tooltip: t.flyraSend,
              onPressed: () {
                final String v = _input.text;
                _input.clear();
                _openChat(v);
              },
              icon: const Icon(Icons.send_rounded, color: NomadColors.mint),
            ),
          ),
        ),
      ],
    );
  }
}

/// "Soy Flyra, ¿en qué puedo ayudarte?" apareciendo palabra a palabra
/// (como en la maqueta). Con "reducir movimiento", sale entera.
class _Greeting extends StatefulWidget {
  const _Greeting({required this.text});

  final String text;

  @override
  State<_Greeting> createState() => _GreetingState();
}

class _GreetingState extends State<_Greeting>
    with SingleTickerProviderStateMixin {
  late final List<String> _words = widget.text.split(' ');
  late final AnimationController _show = AnimationController(
    vsync: this,
    duration: Duration(milliseconds: 220 * _words.length + 400),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_show.status != AnimationStatus.dismissed) return;
    if (MediaQuery.disableAnimationsOf(context)) {
      _show.value = 1;
    } else {
      unawaited(_show.forward());
    }
  }

  @override
  void dispose() {
    _show.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Semantics(
    label: widget.text,
    excludeSemantics: true,
    child: AnimatedBuilder(
      animation: _show,
      builder: (BuildContext context, Widget? _) {
        final int n = (_words.length * _show.value).ceil();
        return Text(
          _words.take(n).join(' '),
          textAlign: TextAlign.center,
          style: const TextStyle(
            fontSize: 19,
            fontWeight: FontWeight.w800,
            height: 1.2,
          ),
        );
      },
    ),
  );
}

/// La ciudad donde estás ("Lisboa, Portugal"): la del aeropuerto más cercano
/// a menos de 80 km. Solo si el GPS ya tiene permiso (Inicio no lo pide).
/// Sin dato, no se enseña nada (nada inventado).
class _WhereChip extends StatefulWidget {
  const _WhereChip();

  @override
  State<_WhereChip> createState() => _WhereChipState();
}

class _WhereChipState extends State<_WhereChip> {
  String? _place;
  bool _asked = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_asked) return;
    _asked = true;
    unawaited(_find());
  }

  Future<void> _find() async {
    final AppServices services = ServicesScope.of(context);
    final String lang = Localizations.localeOf(context).languageCode;
    try {
      if (await services.location.check() != LocationAccess.granted) return;
      final PositionFix? fix = await services.location.current();
      if (fix == null) return;
      final Airports airports = await services.loadAirports();
      final Airport? a = nearestAirport(
        airports.all,
        LatLon(fix.point.lat, fix.point.lon),
      );
      if (a == null ||
          fix.point.distanceTo(GeoPoint(a.position.lat, a.position.lon)) >
              80000) {
        return;
      }
      String place = a.city;
      try {
        final CountryNames names = await CountryNames.load();
        place = '${a.city}, ${names.name(a.country, lang)}';
      } on Object {
        // Sin nombres de país: solo la ciudad.
      }
      if (mounted) setState(() => _place = place);
    } on Object {
      // Sin GPS o sin datos: no se enseña la ciudad.
    }
  }

  @override
  Widget build(BuildContext context) {
    final String? place = _place;
    if (place == null) return const SizedBox.shrink();
    return Flexible(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: NomadColors.surfaceHigh,
          borderRadius: BorderRadius.circular(99),
          border: Border.all(color: const Color(0xFF243540)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const Icon(
              Icons.place_outlined,
              size: 14,
              color: NomadColors.textMuted,
            ),
            const SizedBox(width: 4),
            Flexible(
              child: Text(
                place,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 12,
                  color: NomadColors.textMuted,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// La bola de Flyra. [breath] va de 0 a 1 (inspira/espira); al escuchar se
/// hace un poco más grande y brilla más.
class _Orb extends StatelessWidget {
  const _Orb({required this.breath, required this.listening});

  final double breath;
  final bool listening;

  @override
  Widget build(BuildContext context) {
    final double scale = listening ? 1.12 : 1 + 0.06 * breath;
    return Stack(
      alignment: Alignment.center,
      children: <Widget>[
        // Tres ondas que salen de la bola, desfasadas (menta, violeta, menta).
        for (int i = 0; i < 3; i++)
          _Wave(
            t: (breath / 3 + i / 3) % 1,
            color: i == 1 ? const Color(0xFF9B7BFF) : NomadColors.mint,
          ),
        Transform.scale(
          scale: scale,
          child: Container(
            width: 168,
            height: 168,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: const RadialGradient(
                center: Alignment(-0.36, -0.44),
                colors: <Color>[
                  Color(0xFF7CF0BC),
                  NomadColors.mint,
                  Color(0xFF5A5BD9),
                  Color(0xFF9B7BFF),
                ],
                stops: <double>[0, 0.38, 0.78, 1],
              ),
              boxShadow: <BoxShadow>[
                BoxShadow(
                  color: NomadColors.mint.withValues(
                    alpha: listening ? 0.65 : 0.33,
                  ),
                  blurRadius: listening ? 80 : 60,
                ),
                BoxShadow(
                  color: const Color(0xFF9B7BFF).withValues(alpha: 0.2),
                  blurRadius: 120,
                ),
              ],
            ),
            child: const FlyraAvatar(size: 100),
          ),
        ),
      ],
    );
  }
}

/// Una onda: un aro que crece y se desvanece ([t] de 0 a 1).
class _Wave extends StatelessWidget {
  const _Wave({required this.t, required this.color});

  final double t;
  final Color color;

  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: Transform.scale(
      scale: 0.8 + 0.6 * t,
      child: Container(
        width: 172,
        height: 172,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(
            color: color.withValues(alpha: 0.6 * (1 - t)),
            width: 1.5,
          ),
        ),
      ),
    ),
  );
}

/// Un cuadrado del carrusel: foto, icono, nombre y una línea.
class _Tile {
  const _Tile(this.title, this.sub, this.color, this.open, {this.photo = true});

  final String Function(AppLocalizations) title;
  final String Function(AppLocalizations) sub;
  final Color color;
  final void Function(BuildContext) open;

  /// Widgets no tiene foto (en la maqueta es un dibujo): fondo de color.
  final bool photo;
}

// En el MISMO orden que la maqueta (icono-N y foto-N de assets/inicio/).
final List<_Tile> _tiles = <_Tile>[
  _Tile(
    (AppLocalizations t) => t.planExplore,
    (AppLocalizations t) => t.homeSub0,
    NomadColors.mint,
    (BuildContext c) => c.push(Routes.explore()),
  ),
  _Tile(
    (AppLocalizations t) => t.mapNearby,
    (AppLocalizations t) => t.homeSub1,
    const Color(0xFF58B4E6),
    (BuildContext c) => c.push(Routes.nearby),
  ),
  _Tile(
    (AppLocalizations t) => t.homeTitleHotels,
    (AppLocalizations t) => t.homeSub2,
    const Color(0xFF9B7BFF),
    (BuildContext c) => c.push(Routes.stays()),
  ),
  _Tile(
    (AppLocalizations t) => t.navFlights,
    (AppLocalizations t) => t.homeSub3,
    const Color(0xFF58B4E6),
    (BuildContext c) => c.go(Routes.flights),
  ),
  _Tile(
    (AppLocalizations t) => t.beforeTitle,
    (AppLocalizations t) => t.homeSub4,
    const Color(0xFF9B7BFF),
    (BuildContext c) => c.push(Routes.before),
  ),
  _Tile(
    (AppLocalizations t) => t.visaTitle,
    (AppLocalizations t) => t.homeSub5,
    NomadColors.mint,
    (BuildContext c) => c.push(Routes.visa()),
  ),
  _Tile(
    (AppLocalizations t) => t.airportTitle,
    (AppLocalizations t) => t.homeSub6,
    const Color(0xFF58B4E6),
    (BuildContext c) => c.push(Routes.airport()),
  ),
  _Tile(
    (AppLocalizations t) => t.shortcutVault,
    (AppLocalizations t) => t.homeSub7,
    const Color(0xFF9B7BFF),
    (BuildContext c) => c.push(Routes.vault),
  ),
  _Tile(
    (AppLocalizations t) => t.shortcutExpenses,
    (AppLocalizations t) => t.homeSub8,
    const Color(0xFFFFC857),
    (BuildContext c) => c.push(Routes.money()),
  ),
  _Tile(
    (AppLocalizations t) => t.moneyTabFx,
    (AppLocalizations t) => t.homeSub9,
    NomadColors.mint,
    (BuildContext c) => c.push(Routes.money(tab: MoneyTab.fx)),
  ),
  _Tile(
    (AppLocalizations t) => t.homeTitleWith,
    (AppLocalizations t) => t.homeSub10,
    const Color(0xFFFF8A9A),
    (BuildContext c) => c.push(Routes.travelWith),
  ),
  _Tile(
    (AppLocalizations t) => t.copyTitle,
    (AppLocalizations t) => t.homeSub11,
    const Color(0xFF9B7BFF),
    (BuildContext c) => c.push(Routes.copyTrip()),
  ),
  _Tile(
    (AppLocalizations t) => t.memTitle,
    (AppLocalizations t) => t.homeSub12,
    const Color(0xFF58B4E6),
    (BuildContext c) => c.push(Routes.memories),
  ),
  _Tile(
    (AppLocalizations t) => t.driveShort,
    (AppLocalizations t) => t.homeSub13,
    const Color(0xFFFFC857),
    (BuildContext c) => c.push(Routes.drive),
  ),
  // Las audioguías viven en el Mapa: se abren al tocar una zona.
  _Tile(
    (AppLocalizations t) => t.shortcutAudioguides,
    (AppLocalizations t) => t.homeSub14,
    const Color(0xFF9B7BFF),
    (BuildContext c) => c.go(Routes.map),
  ),
  _Tile(
    (AppLocalizations t) => t.mapRadar,
    (AppLocalizations t) => t.homeSub15,
    const Color(0xFFFF8A65),
    (BuildContext c) => c.push(Routes.radar()),
  ),
  _Tile(
    (AppLocalizations t) => t.widgetsTitle,
    (AppLocalizations t) => t.homeSub16,
    const Color(0xFF58B4E6),
    (BuildContext c) => c.push(Routes.widgets),
    photo: false,
  ),
  _Tile(
    (AppLocalizations t) => t.assistantTitle,
    (AppLocalizations t) => t.homeSub17,
    NomadColors.mint,
    (BuildContext c) => c.push(Routes.assistant),
  ),
  _Tile(
    (AppLocalizations t) => t.shortcutLanguage,
    (AppLocalizations t) => t.homeSub18,
    NomadColors.mint,
    (BuildContext c) => c.push(Routes.language),
  ),
];

/// El carrusel "infinito": empieza en una página muy alta y cada página es
/// el cuadrado número (página % 19), así se puede deslizar sin fin.
class _Carousel extends StatefulWidget {
  const _Carousel();

  @override
  State<_Carousel> createState() => _CarouselState();
}

class _CarouselState extends State<_Carousel> {
  static final int _start = _tiles.length * 500;
  final PageController _pages = PageController(
    viewportFraction: 0.66,
    initialPage: _start,
  );
  int _current = _start;

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    final bool still = MediaQuery.disableAnimationsOf(context);
    final int n = _tiles.length;
    // 8 puntitos (como la maqueta): marcan por dónde vas de los 19.
    final int dot = ((_current % n) / (n - 1) * 7).round();
    return Column(
      children: <Widget>[
        SizedBox(
          height: 300,
          child: PageView.builder(
            controller: _pages,
            onPageChanged: (int p) => setState(() => _current = p),
            itemBuilder: (BuildContext context, int page) {
              final _Tile tile = _tiles[page % n];
              return AnimatedBuilder(
                animation: _pages,
                builder: (BuildContext context, Widget? child) {
                  // Cuánto se aleja del centro (0 = en el centro).
                  final double off =
                      _pages.hasClients && _pages.position.haveDimensions
                      ? (_pages.page ?? page.toDouble()) - page
                      : (_current - page).toDouble();
                  final double a = math.min(off.abs(), 1);
                  final Matrix4 m = Matrix4.identity()
                    ..setEntry(3, 2, 0.0012)
                    ..rotateY(still ? 0 : off.clamp(-1.5, 1.5) * 0.35);
                  return Opacity(
                    opacity: 1 - 0.4 * a,
                    child: Transform(
                      alignment: Alignment.center,
                      transform: m,
                      child: Transform.scale(scale: 1 - 0.14 * a, child: child),
                    ),
                  );
                },
                child: _TileCard(
                  index: page % n,
                  tile: tile,
                  t: t,
                  onTap: () {
                    if (page != _current) {
                      unawaited(
                        _pages.animateToPage(
                          page,
                          duration: const Duration(milliseconds: 350),
                          curve: Curves.easeOutCubic,
                        ),
                      );
                    } else {
                      tile.open(context);
                    }
                  },
                ),
              );
            },
          ),
        ),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            for (int i = 0; i < 8; i++)
              AnimatedContainer(
                duration: const Duration(milliseconds: 300),
                margin: const EdgeInsets.symmetric(horizontal: 2.5),
                width: i == dot ? 18 : 5,
                height: 5,
                decoration: BoxDecoration(
                  color: i == dot ? NomadColors.mint : const Color(0xFF243540),
                  borderRadius: BorderRadius.circular(9),
                ),
              ),
          ],
        ),
      ],
    );
  }
}

class _TileCard extends StatelessWidget {
  const _TileCard({
    required this.index,
    required this.tile,
    required this.t,
    required this.onTap,
  });

  final int index;
  final _Tile tile;
  final AppLocalizations t;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final String title = tile.title(t);
    final String sub = tile.sub(t);
    return Semantics(
      button: true,
      label: '$title. $sub',
      excludeSemantics: true,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 12),
        child: Material(
          clipBehavior: Clip.antiAlias,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(30),
            side: BorderSide(color: tile.color.withValues(alpha: 0.35)),
          ),
          color: const Color(0xFF0F1A22),
          child: InkWell(
            onTap: onTap,
            child: Stack(
              fit: StackFit.expand,
              children: <Widget>[
                if (tile.photo)
                  Image.asset(
                    'assets/inicio/foto-$index.webp',
                    fit: BoxFit.cover,
                    excludeFromSemantics: true,
                    errorBuilder: (BuildContext c, Object e, StackTrace? s) =>
                        const SizedBox.shrink(),
                  )
                else
                  DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: RadialGradient(
                        center: Alignment.topLeft,
                        radius: 1.3,
                        colors: <Color>[
                          tile.color.withValues(alpha: 0.45),
                          const Color(0xFF0F1A22),
                        ],
                      ),
                    ),
                  ),
                // Oscurece abajo para que el texto se lea sobre la foto.
                const DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: <Color>[
                        Color(0x330B1217),
                        Color(0x000B1217),
                        Color(0xE60B1217),
                      ],
                      stops: <double>[0, 0.3, 1],
                    ),
                  ),
                ),
                PositionedDirectional(
                  top: 14,
                  start: 14,
                  child: Image.asset(
                    'assets/inicio/icono-$index.webp',
                    width: 64,
                    height: 64,
                    excludeFromSemantics: true,
                    errorBuilder: (BuildContext c, Object e, StackTrace? s) =>
                        const SizedBox.shrink(),
                  ),
                ),
                PositionedDirectional(
                  start: 18,
                  end: 18,
                  bottom: 16,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.w800,
                          height: 1.05,
                          shadows: <Shadow>[
                            Shadow(color: Color(0xAA000000), blurRadius: 8),
                          ],
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        sub,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 12,
                          color: Color(0xFFD6E2DE),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// "dario.perez@gmail.com" -> "Dario". Solo para el saludo: la app aún no
/// pide el nombre (llegará con el perfil). Nunca se envía a ningún sitio.
String? displayName(String? email) {
  final String local = (email ?? '')
      .split('@')
      .first
      .split(RegExp(r'[._+-]'))
      .first;
  if (local.isEmpty) return null;
  return local[0].toUpperCase() + local.substring(1);
}

class _Shortcut extends StatelessWidget {
  const _Shortcut({
    required this.icon,
    required this.color,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final Color color;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Icon(icon, color: color, size: 28),
              const SizedBox(height: 20),
              Text(
                label,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
