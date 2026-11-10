// Inicio: la maqueta "ECLIPTA Inicio" tal cual (assets/inicio/inicio.html,
// dentro de un WebView):
//   1. Arriba, "ECLIPTA", "Probar aviso" (repite el último aviso de Flyra),
//      volver a ver la entrada de Flyra y la ciudad donde estás.
//   2. Flyra en grande: MANTENER PULSADA la bola es hablarle (el micro del
//      móvil escucha y la pregunta llega al chat). O escribirle en la caja.
//   3. "Todo en ECLIPTA": el carrusel de 19 cuadrados; el del centro abre su
//      pantalla.
//   4. "Mi pasaporte": se rellena escaneando pasaporte y DNI con la cámara.
//   5. "Mi álbum de cromos": tus sellos de monumentos en un libro.
//   6. El SOS: mantener 2 s, cuenta atrás de 5 y avisar a tus contactos por
//      WhatsApp o SMS (con tu ubicación) o llamar a emergencias.
//   7. Tus 3 contactos de emergencia.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';

import '../../auth/session.dart';
import '../../core/router.dart';
import '../../core/services.dart';
import '../../l10n/generated/app_localizations.dart';
import '../../widgets/user_avatar.dart' show isTrustedPhotoUrl;
import '../camera/stamps.dart';
import '../flights/flights_page.dart' show unpackJson;
import '../flyra/flyra_mini.dart';
import '../map/geo.dart';
import '../map/location.dart';
import '../money/money_screen.dart' show MoneyTab;
import '../passport/passport.dart';
import '../route/flight3d.dart' show CountryCodes;
import '../route/geo.dart' show LatLon;
import '../route/web_scene.dart';
import '../route/world_data.dart';
import '../settings/profile_photo.dart';
import '../sos/emergency_data.dart';
import '../sos/sos_screen.dart' show SosContactDialog;
import '../sos/sos_store.dart';
import '../sos/where_am_i.dart';
import '../visa/visa_data.dart' show CountryNames;
import 'home_album.dart';
import 'home_page.dart';
import 'my_passport.dart';

/// Qué abre cada cuadrado del carrusel (en el MISMO orden que la maqueta).
final List<void Function(BuildContext)> homeTiles =
    <void Function(BuildContext)>[
      (BuildContext c) => c.push(Routes.explore()),
      (BuildContext c) => c.push(Routes.nearby),
      (BuildContext c) => c.push(Routes.stays()),
      (BuildContext c) => c.go(Routes.flights),
      (BuildContext c) => c.push(Routes.before),
      (BuildContext c) => c.push(Routes.visa()),
      (BuildContext c) => c.push(Routes.airport()),
      (BuildContext c) => c.push(Routes.vault),
      (BuildContext c) => c.push(Routes.money()),
      (BuildContext c) => c.push(Routes.money(tab: MoneyTab.fx)),
      (BuildContext c) => c.push(Routes.travelWith),
      (BuildContext c) => c.push(Routes.copyTrip()),
      (BuildContext c) => c.push(Routes.memories),
      (BuildContext c) => c.push(Routes.drive),
      // Las audioguías viven en el Mapa: se abren al tocar una zona.
      (BuildContext c) => c.go(Routes.map),
      (BuildContext c) => c.push(Routes.radar()),
      (BuildContext c) => c.push(Routes.widgets),
      (BuildContext c) => c.push(Routes.assistant),
      (BuildContext c) => c.push(Routes.language),
    ];

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  /// El puente de la última pantalla abierta (lo miran los tests).
  static WebSceneBridge? lastBridge;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  late final AppServices _services = ServicesScope.of(context);
  final WebSceneBridge _bridge = HomeScreen.lastBridge = WebSceneBridge();
  final ProfilePhotoController _photo = ProfilePhotoController.instance;

  /// La página se lee una vez (se guarda el texto, no la espera).
  static String? _pageCache;
  String? _html;
  String? _sent;
  bool _started = false;

  String? _place;
  MyDocs? _docs;
  CountryNames? _names;
  bool _askedNames = false;
  List<AlbumPage>? _album;
  int _stamps = 0;
  List<String>? _friends;
  bool _listening = false;

  /// El SOS: dónde estás (se busca al empezar la cuenta atrás).
  bool _locating = false;
  GeoPoint? _here;
  Whereabouts _where = const Whereabouts();

  /// Tu foto del móvil ya leída para la página (ruta → data:...).
  final Map<String, String> _files = <String, String>{};

  @override
  void initState() {
    super.initState();
    _photo.addListener(_changed);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    unawaited(_start());
    unawaited(_findPlace());
    _loadAlbum();
    if (SessionScope.of(context).status == SessionStatus.signedIn) {
      unawaited(_loadFriends());
    }
  }

  @override
  void dispose() {
    _photo.removeListener(_changed);
    if (_listening) unawaited(_services.speechInput.stop());
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<void> _start() async {
    try {
      _pageCache ??= await rootBundle.loadString(homePage, cache: false);
    } on Object {
      return;
    }
    if (mounted) setState(() {});
  }

  /// La ciudad de arriba: solo si el GPS ya tiene permiso (no se pide aquí).
  Future<void> _findPlace() async {
    final String lang = Localizations.localeOf(context).languageCode;
    try {
      if (await _services.location.check() != LocationAccess.granted) return;
      final PositionFix? fix = await _services.location.current();
      if (fix == null) return;
      final Airports airports = await _services.loadAirports();
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

  /// Tus cromos, agrupados por país (como en el Pasaporte).
  void _loadAlbum() {
    final List<Stamp> stamps = StampBook(_services.prefs).all();
    _stamps = stamps.length;
    if (stamps.isEmpty) {
      _album = const <AlbumPage>[];
      return;
    }
    unawaited(() async {
      List<PassportPage> pages;
      try {
        final WorldData world = await WorldData.load();
        final CountryCodes codes = await CountryCodes.load();
        pages = pagesOf(stamps, airports: world.airports.all, codes: codes);
      } on Object {
        pages = pagesOf(stamps);
      }
      if (!mounted) return;
      final AppLocalizations t = AppLocalizations.of(context);
      setState(
        () => _album = albumPagesOf(
          pages,
          titleOf: (PassportPage p) {
            final String? c = p.country;
            if (c == null) return t.passportElsewhere;
            final String city = p.cities.isEmpty ? c : p.cities.first;
            return '${flagOf(c)} $city';
          },
        ),
      );
    }());
  }

  /// Los amigos con cromos que te faltan (del servidor, solo con cuenta).
  Future<void> _loadFriends() async {
    try {
      final List<String> f = await _services.leagues.friendsWithMissing();
      if (mounted && f.isNotEmpty) setState(() => _friends = f);
    } on Object {
      // Sin conexión o sin ligas: se queda la línea de siempre.
    }
  }

  /// La lista de países (para "España" en vez de "ESP"), una vez.
  void _needNames() {
    if (_askedNames) return;
    _askedNames = true;
    unawaited(
      CountryNames.load().then((CountryNames n) {
        if (mounted) setState(() => _names = n);
      }, onError: (Object _) {}),
    );
  }

  /// Lee tu foto del móvil para enseñarla en la tarjeta.
  Future<void> _readFile(String path) async {
    try {
      final List<int> bytes = await File(path).readAsBytes();
      _files[path] = 'data:image/jpeg;base64,${base64Encode(bytes)}';
    } on Object {
      _files[path] = '';
    }
    if (mounted) setState(() {});
  }

  // --- Lo que pide la página.

  /// "Probar aviso": Flyra repite su último aviso (o dice que no hay).
  void _note() {
    final FlyraNote? last = FlyraNotes.instance.last;
    FlyraNotes.instance.say(
      last ??
          const FlyraNote(
            FlyraNoteKind.tip,
            'Aún no tienes avisos. Cuando pase algo, te lo digo aquí.',
          ),
    );
  }

  /// Mantener pulsada la bola: escucha en el idioma de la app.
  Future<void> _listen() async {
    final String lang = Localizations.localeOf(context).languageCode;
    _listening = true;
    final String? heard = await _services.speechInput.listen(lang);
    _listening = false;
    if (!mounted) return;
    if (heard != null && heard.trim().isNotEmpty) _ask(heard);
  }

  void _ask(String question) =>
      unawaited(context.push(Routes.flyra(question: question.trim())));

  /// Escanear pasaporte y DNI (a pantalla completa, con la cámara).
  Future<void> _scan() async {
    final MyDocs before = _docs ?? MyDocs.load(_services.prefs);
    final MyDocs? after = await Navigator.of(context, rootNavigator: true)
        .push<MyDocs>(
          MaterialPageRoute<MyDocs>(
            fullscreenDialog: true,
            builder: (_) => PassportScanScreen(start: before),
          ),
        );
    if (after == null || !mounted) return;
    await after.save(_services.prefs);
    if (mounted) setState(() => _docs = after);
  }

  /// La foto de la tarjeta: hacer una o elegirla de la galería.
  Future<void> _choosePhoto() async {
    final AppLocalizations t = AppLocalizations.of(context);
    final ImageSource? from = await showModalBottomSheet<ImageSource>(
      context: context,
      showDragHandle: true,
      builder: (BuildContext sheet) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            ListTile(
              leading: const Icon(Icons.photo_camera_rounded),
              title: Text(t.profilePhotoTake),
              onTap: () => Navigator.pop(sheet, ImageSource.camera),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library_rounded),
              title: Text(t.profilePhotoGallery),
              onTap: () => Navigator.pop(sheet, ImageSource.gallery),
            ),
          ],
        ),
      ),
    );
    if (from != null) await _photo.pick(from);
  }

  /// Al empezar la cuenta atrás del SOS: dónde estás (para el mensaje y el
  /// número de emergencias de ese país).
  Future<void> _locate() {
    final Future<void>? running = _locatingNow;
    if (running != null) return running;
    return _locatingNow = _doLocate().whenComplete(() => _locatingNow = null);
  }

  Future<void>? _locatingNow;

  Future<void> _doLocate() async {
    setState(() => _locating = true);
    final LocationSource gps = _services.location;
    try {
      LocationAccess access = await gps.check();
      if (access == LocationAccess.denied) access = await gps.request();
      if (access == LocationAccess.granted) {
        // Primero la posición que ya sepa el móvil (al momento); si no,
        // la primera que dé el GPS.
        final PositionFix fix =
            await gps.current().timeout(
              const Duration(seconds: 5),
              onTimeout: () => null,
            ) ??
            await gps.watch().first.timeout(const Duration(seconds: 8));
        if (mounted) {
          // La posición se guarda YA: aunque luego falle saber la ciudad
          // (sin internet), el mensaje lleva tu ubicación.
          setState(() => _here = fix.point);
          try {
            final Whereabouts where = await whereabouts(fix.point);
            if (mounted) setState(() => _where = where);
          } on Object {
            // Sin ciudad: el mensaje va igual con las coordenadas.
          }
        }
      }
    } on Object {
      // Sin GPS: el SOS sigue funcionando (emergencias y contactos).
    }
    if (mounted) setState(() => _locating = false);
  }

  /// WhatsApp o SMS a un contacto: si aún no se sabe dónde estás, se
  /// espera a saberlo (un momento) para que el mensaje lleve tu ubicación.
  Future<void> _sendSos(SosContact who, {required bool whatsapp}) async {
    if (_here == null) await _locate();
    if (!mounted) return;
    final String text = _sosText();
    await _services.openLink(
      whatsapp ? whatsappUri(who, text) : smsUri(<SosContact>[who], text),
    );
  }

  String _sosText() => sosMessage(
    AppLocalizations.of(context).sosMessage,
    _here,
    noLocation: AppLocalizations.of(context).sosMessageNoLocation,
  );

  /// "Cambiar" o "Añadir" un contacto de emergencia (hueco [i]).
  Future<void> _pick(int i) async {
    final List<SosContact> all = loadContacts(_services.prefs);
    final SosContact? old = i < all.length ? all[i] : null;
    final SosContact? c = await showDialog<SosContact>(
      context: context,
      builder: (BuildContext context) => SosContactDialog(initial: old),
    );
    if (c == null || !mounted) return;
    final List<SosContact> now = <SosContact>[...all];
    if (old != null) {
      now[i] = c;
    } else if (now.length < maxSosContacts) {
      now.add(c);
    }
    await saveContacts(_services.prefs, now);
    if (mounted) setState(() {});
  }

  void _onMessage(String m) {
    final List<String> p = m.split(':');
    final int? n = p.length > 1 ? int.tryParse(p[1]) : null;
    final Map<String, Object?>? data = p.length == 3 ? unpackJson(p[2]) : null;
    final Object? q = data?['q'];
    final List<SosContact> people = loadContacts(_services.prefs);
    final SosContact? who = n != null && n >= 0 && n < people.length
        ? people[n]
        : null;
    switch (p.first) {
      case 'note':
        _note();
      case 'hold' when n == 1:
        if (!_listening) unawaited(_listen());
      case 'hold':
        if (_listening) unawaited(_services.speechInput.stop());
      case 'ask' when q is String && q.trim().isNotEmpty:
        _ask(q);
      case 'tile' when n != null && n >= 0 && n < homeTiles.length:
        homeTiles[n](context);
      case 'scan':
        unawaited(_scan());
      case 'photo':
        unawaited(_choosePhoto());
      case 'cards':
        unawaited(context.push(Routes.cards));
      case 'sos':
        unawaited(_locate());
      case 'wa' when who != null:
        unawaited(_sendSos(who, whatsapp: true));
      case 'sms' when who != null:
        unawaited(_sendSos(who, whatsapp: false));
      case 'call':
        unawaited(
          _services.openLink(telUri(numbersFor(_where.country).general)),
        );
      case 'pick' when n != null && n >= 0 && n < 3:
        unawaited(_pick(n));
      case 'more':
        unawaited(context.push(Routes.sos));
    }
  }

  Map<String, Object?> _data(AppLocalizations t) {
    final String lang = Localizations.localeOf(context).languageCode;
    final MyDocs docs = _docs ??= MyDocs.load(_services.prefs);
    final ReadDoc? pass = docs.passport;
    final ReadDoc? id = docs.id;
    final ReadDoc? any = pass ?? id;
    if (any != null) _needNames();
    // La foto: la que elegiste en el móvil o la de tu cuenta de Google.
    final ProfilePhotoChoice choice = _photo.choice;
    final String? path = choice.filePath;
    if (path != null && !_files.containsKey(path)) unawaited(_readFile(path));
    final String? google = SessionScope.of(context).user?.photoUrl;
    final String photo = path != null
        ? _files[path] ?? ''
        : choice.isNone && isTrustedPhotoUrl(google)
        ? google!
        : '';
    final List<AlbumPage> album = _album ?? const <AlbumPage>[];
    final List<String>? friends = _friends;
    final GeoPoint? here = _here;
    final String? city = _where.city;
    return <String, Object?>{
      'place': _place ?? '',
      'empty': t.homePassEmpty,
      'mrzEmpty': t.homePassMrzEmpty,
      'pass': <String, Object?>{
        'ape': any?.surname ?? '',
        'nom': any?.given ?? '',
        'nac': any == null ? '' : countryOf(_names, any.nationality, lang),
        'blood': MedicalCard.load(_services.prefs).blood ?? '',
        'num': pass?.numberTail ?? '',
        'exp': pass == null ? '' : passportDay(pass.expiry, lang),
        'dni': id?.numberTail ?? '',
        'nacim': any == null ? '' : passportDay(any.birth, lang),
        'val': id == null ? '' : passportDay(id.expiry, lang),
        'mrz': pass == null
            ? null
            : mrzLines(pass.nationality, pass.surname, pass.given),
        'cta': pass != null && id != null
            ? t.homePassBoth
            : pass != null
            ? t.homePassOnlyPass
            : id != null
            ? t.homePassOnlyId
            : t.homePassCta,
        'done': any != null,
        'photo': photo,
      },
      'album': <String, Object?>{
        'pages': albumJson(album),
        'tap': t.homeAlbumTap(_stamps),
        'howto': _stamps == 0 ? t.homeAlbumHowTo : '',
        'friends': friends == null
            ? t.cardsSubtitle
            : t.homeFriendsMissing(friends.length),
        'faces': <String>[
          for (final String f in (friends ?? const <String>[]).take(3))
            String.fromCharCodes(f.trim().runes.take(1)).toUpperCase(),
        ],
      },
      'contacts': contactsJson(loadContacts(_services.prefs)),
      'sos': <String, Object?>{
        'msg': _sosText(),
        'where': _locating
            ? t.sosLocating
            : here == null
            ? t.sosNoLocation
            : '${coordsText(here)}${city == null ? '' : ' · $city'}',
        'call': numbersFor(_where.country).general,
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
    final String push = homePushScript(data);
    if (_html == null) {
      _html = homePageWith(page, data);
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
