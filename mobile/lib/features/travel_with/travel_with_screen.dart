// "Viajo con mi perro" (maqueta "ViajoCon"): la maqueta tal cual
// (assets/travel_with/viajocon.html) con los datos de TU perro:
//   - arriba, su foto y su nombre (los eliges tú y se quedan en el móvil);
//   - lo que pide la UE (microchip, rabia, pasaporte), con sellos;
//   - veterinarios, parques para perros y hoteles que admiten perros DE
//     VERDAD cerca de ti, en un mapa de OpenStreetMap y en una lista con
//     Llamar, Web e Ir (sacados de OpenStreetMap por el mismo servicio que
//     "Cerca de ti"). Si OSM no tiene nada, se dice así: nunca se inventa;
//   - la maleta de tu perro (se guarda en el móvil);
//   - "En el avión": con lo que pesa y el transportín, cabina o bodega.
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';

import '../../core/api_client.dart';
import '../../core/services.dart';
import '../../l10n/generated/app_localizations.dart';
import '../map/geo.dart';
import '../map/location.dart';
import '../memories/memories_page.dart' show changedKeys;
import '../memories/memories_screen.dart' show memoryImage;
import '../nearby/nearby_api.dart';
import '../route/web_scene.dart';
import 'travel_with.dart';
import 'travel_with_page.dart';

/// Cuántos sitios de cada tipo se enseñan como mucho (los más cercanos).
const int shownDogSpots = 8;

/// Los tipos de sitio para tu perro, en el orden de la maqueta.
const List<NearbyKind> _dogKinds = <NearbyKind>[
  NearbyKind.vet,
  NearbyKind.dogPark,
  NearbyKind.petStay,
];

class TravelWithScreen extends StatefulWidget {
  const TravelWithScreen({super.key});

  /// La última conexión con la página (para las pruebas).
  static WebSceneBridge? lastBridge;

  @override
  State<TravelWithScreen> createState() => _TravelWithScreenState();
}

class _TravelWithScreenState extends State<TravelWithScreen> {
  late final AppServices _services = ServicesScope.of(context);
  final WebSceneBridge _bridge = TravelWithScreen.lastBridge = WebSceneBridge();

  // La página se lee una vez y se guarda (como String, no como Future).
  static String? _pageCache;
  String? _html;

  /// Lo que ya sabe la página (solo se le manda lo que cambia: la foto
  /// pesa).
  Map<String, Object?> _shown = <String, Object?>{};

  late final PetChecks _checks = PetChecks(_services.prefs);
  late final DogBag _bagStore = DogBag(_services.prefs);
  late DogProfile _dog = DogProfile.load(_services.prefs);
  late Set<PetCheck> _done = _checks.done();
  late Set<int> _bag = _bagStore.packed();

  /// La foto como imagen para la página ('' = sin foto) y cuántas veces ha
  /// cambiado (para que salten las huellas).
  String _photo = '';
  int _popN = 0;

  /// Lo que pesa, tal cual lo escribes ("5,5").
  String _petKg = '';
  String _carrierKg = '2';

  // "Para tu perro, cerca de ti".
  NearbyKind _kind = NearbyKind.vet;
  bool _loading = true;
  bool _noLocation = false;
  bool _noSignal = false;
  ApiError? _error;
  GeoPoint? _me;
  NearbyList? _found;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_open()));
  }

  Future<void> _open() async {
    try {
      _pageCache ??= await rootBundle.loadString(travelWithPage, cache: false);
    } on Object {
      return;
    }
    await _loadPhoto(pop: false);
    if (mounted) setState(() {});
    await _search();
  }

  /// Lee la foto guardada y la deja lista para la página.
  Future<void> _loadPhoto({required bool pop}) async {
    final String? path = _dog.photoPath;
    String img = '';
    if (path != null) {
      try {
        img = await memoryImage(await File(path).readAsBytes(), 360) ?? '';
      } on Object {
        img = '';
      }
    }
    if (!mounted) return;
    setState(() {
      _photo = img;
      if (pop && img.isNotEmpty) _popN++;
    });
  }

  /// Lee un número escrito con coma o con punto ("6,5" o "6.5").
  static double? _kg(String text) =>
      double.tryParse(text.trim().replaceAll(',', '.'));

  Future<void> _toggle(PetCheck check) async {
    await _checks.set(check, ready: !_done.contains(check));
    if (mounted) setState(() => _done = _checks.done());
  }

  /// El nombre se guarda según escribes (solo en el móvil).
  void _rename(String raw) {
    setState(() => _dog = _dog.withName(raw));
    unawaited(_dog.save(_services.prefs));
  }

  /// Hacer una foto o elegirla de la galería. Se copia a la carpeta privada
  /// de la app (así no depende de que la borres de la galería).
  Future<void> _pickPhoto(AppLocalizations t) async {
    final ImageSource? source = await showModalBottomSheet<ImageSource>(
      context: context,
      builder: (BuildContext ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            ListTile(
              leading: const Icon(Icons.photo_camera_rounded),
              title: Text(t.profilePhotoTake),
              onTap: () => Navigator.pop(ctx, ImageSource.camera),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library_rounded),
              title: Text(t.profilePhotoGallery),
              onTap: () => Navigator.pop(ctx, ImageSource.gallery),
            ),
          ],
        ),
      ),
    );
    if (source == null) return;
    try {
      final XFile? shot = await ImagePicker().pickImage(
        source: source,
        maxWidth: 512, // para un círculo de 150 px sobra
        maxHeight: 512,
        imageQuality: 85,
      );
      if (shot == null) return;
      final Directory dir = await getApplicationSupportDirectory();
      // Nombre nuevo cada vez: así no se ve la foto vieja que Flutter guarda.
      final String dest =
          '${dir.path}/perro_${DateTime.now().millisecondsSinceEpoch}.jpg';
      await File(shot.path).copy(dest);
      final String? old = _dog.photoPath;
      if (!mounted) return;
      setState(() => _dog = _dog.withPhoto(dest));
      await _dog.save(_services.prefs);
      await _loadPhoto(pop: true);
      if (old != null && old != dest) await _deleteFile(old);
    } on Object {
      // Sin permiso de cámara, cancelado a medias...: se queda la de antes.
    }
  }

  /// "Quitar foto": se borra también del móvil.
  Future<void> _removePhoto() async {
    final String? old = _dog.photoPath;
    setState(() {
      _dog = _dog.withPhoto(null);
      _photo = '';
    });
    await _dog.save(_services.prefs);
    if (old != null) await _deleteFile(old);
  }

  static Future<void> _deleteFile(String path) async {
    try {
      await File(path).delete();
    } on Object {
      // ya no estaba: da igual
    }
  }

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
      _noSignal = true;
      return null;
    }
  }

  Future<void> _search() async {
    setState(() {
      _loading = true;
      _noLocation = false;
      _error = null;
    });
    final GeoPoint? me = await _position();
    if (!mounted) return;
    if (me == null) {
      setState(() => (_loading = false, _noLocation = true));
      return;
    }
    try {
      final NearbyList found = await _services.nearby.near(me);
      if (mounted) setState(() => (_me = me, _found = found, _loading = false));
    } on ApiException catch (e) {
      if (mounted) setState(() => (_error = e.error, _loading = false));
    }
  }

  /// Los sitios del tipo elegido, del más cercano al más lejano.
  List<NearbySpot> _list() {
    final GeoPoint? me = _me;
    final NearbyList? found = _found;
    if (me == null || found == null) return <NearbySpot>[];
    return found.of(_kind, me).take(shownDogSpots).toList();
  }

  /// "Ir": Google Maps andando hasta ese punto (un enlace, gratis).
  void _go(GeoPoint p) => unawaited(
    _services.openBooking(
      Uri.https('www.google.com', '/maps/dir/', <String, String>{
        'api': '1',
        'destination':
            '${p.lat.toStringAsFixed(5)},${p.lon.toStringAsFixed(5)}',
        'travelmode': 'walking',
      }),
    ),
  );

  void _onMessage(String m) {
    final int i = m.indexOf(':');
    final String what = i < 0 ? m : m.substring(0, i);
    final String arg = i < 0 ? '' : m.substring(i + 1);
    switch (what) {
      case 'back':
        if (context.canPop()) context.pop();
      case 'photo':
        unawaited(_pickPhoto(AppLocalizations.of(context)));
      case 'nophoto':
        unawaited(_removePhoto());
      case 'name':
        _rename(arg);
      case 'check':
        final int n = int.tryParse(arg) ?? -1;
        if (n >= 0 && n < PetCheck.values.length) {
          unawaited(_toggle(PetCheck.values[n]));
        }
      case 'kind':
        for (final NearbyKind k in _dogKinds) {
          if (k.name == arg) setState(() => _kind = k);
        }
      case 'spot':
        final List<String> parts = arg.split(':');
        final List<NearbySpot> list = _list();
        final int n = int.tryParse(parts.first) ?? -1;
        if (n < 0 || n >= list.length || parts.length < 2) return;
        final NearbySpot s = list[n];
        switch (parts[1]) {
          case 'go':
            _go(s.point);
          case 'call':
            if (s.phone case final String phone) {
              unawaited(
                _services.openLink(
                  Uri(scheme: 'tel', path: phone.replaceAll(' ', '')),
                ),
              );
            }
          case 'web':
            if (s.website case final Uri web) {
              unawaited(_services.openLink(web));
            }
        }
      case 'goNear':
        final List<NearbySpot> list = _list();
        if (list.isNotEmpty) _go(list.first.point);
      case 'retry':
        unawaited(_search());
      case 'bag':
        final int n = int.tryParse(arg) ?? -1;
        unawaited(
          _bagStore.toggle(n).then((Set<int> b) {
            if (mounted) setState(() => _bag = b);
          }),
        );
      case 'petKg':
        setState(() => _petKg = arg);
      case 'carrierKg':
        setState(() => _carrierKg = arg);
    }
  }

  Map<String, Object?> _data(AppLocalizations t) {
    final String? name = _dog.name;
    final String who = name ?? t.twDogDefault;
    final String whoUp = name ?? 'Tu perro';
    final double? petKg = _kg(_petKg);
    final double carrierKg = _kg(_carrierKg) ?? 0;
    final PetPlace? place = petKg == null || petKg <= 0
        ? null
        : petPlace(petKg: petKg, carrierKg: carrierKg);
    final int max = cabinMaxKg.round();
    final GeoPoint? me = _me;
    final List<NearbySpot> list = _list();

    String? msg;
    bool retry = false;
    if (_loading) {
      msg = 'Buscando cerca de ti…';
    } else if (_noLocation) {
      msg = _noSignal ? t.nearbyNoSignal : t.cameraNoLocation;
      retry = true;
    } else if (_error != null) {
      msg = _error == ApiError.network ? t.errorNetwork : t.errorUnavailable;
      retry = true;
    } else if (list.isEmpty) {
      msg = t.twNearNone;
    }
    final String shortKind = switch (_kind) {
      NearbyKind.vet => 'Veterinario',
      NearbyKind.dogPark => 'Parque',
      _ => 'Hotel',
    };

    return <String, Object?>{
      't': <String, Object?>{
        'title': t.twTitle,
        'back': MaterialLocalizations.of(context).backButtonTooltip,
        'photoAria': t.twDogPhoto,
        'nameHint': t.twDogName,
        'remove': 'Quitar foto',
        'source': 'FUENTE · Normas de la UE para viajar con mascotas (web oficial Your Europe)',
        'outsideEu': t.twOutsideEu,
        'mapLabel': t.twNearTitle(who),
        'nearH': 'Veterinarios, parques y hoteles',
        'retry': t.guideRetry,
        'goNear': 'Abrir el mapa y llevarme andando',
        'call': t.twCall,
        'web': t.twWeb,
        'go': t.nearbyGo,
        'planeH': 'EN EL AVIÓN',
        'planeP':
            'En cabina suelen dejar hasta unos $max kg con transportín. Cada aerolínea tiene su norma: confírmalo con la tuya.',
        'petKg': t.twPetWeight,
        'carrierKg': t.twCarrierWeight,
        'disclaimer': '${t.twPetDisclaimer} ${t.twPetHotels}',
      },
      'name': name ?? '',
      'photo': _photo,
      'popN': _popN,
      'photoHint': _photo.isNotEmpty
          ? '¡Qué guapo${name == null ? '' : ', $name'}! La foto y el nombre se quedan solo en tu móvil.'
          : 'Toca el círculo o la cámara para poner la foto de $who',
      'chips': <Object?>[
        <String, Object?>{'t': 'Perro', 'c': '#FFB86B'},
        if (petKg != null && petKg > 0)
          <String, Object?>{
            't': '${kgLabel(petKg + carrierKg)} kg con transportín',
            'c': '#6CA8FF',
          },
        if (place != null)
          <String, Object?>{
            't': place == PetPlace.cabin ? 'Va en cabina' : 'Va en bodega',
            'c': place == PetPlace.cabin ? '#3DDC97' : '#FFB86B',
          },
      ],
      'petH': 'Pasaporte de $who para la UE',
      'bagH': 'Maleta de $who',
      'bagFullTxt': '¡$whoUp lo tiene todo! 🐾',
      'checks': <Object?>[
        for (final PetCheck c in PetCheck.values)
          <String, Object?>{
            'label': switch (c) {
              PetCheck.microchip => t.twChip,
              PetCheck.rabies => t.twRabies,
              PetCheck.passport => t.twPassport,
            },
            'sub': switch (c) {
              PetCheck.microchip => t.twChipWhy,
              PetCheck.rabies => t.twRabiesWhy(rabiesWaitDays),
              PetCheck.passport => t.twPassportWhy,
            },
            'on': _done.contains(c),
          },
      ],
      'me': me == null ? null : <String, Object?>{'lat': me.lat, 'lon': me.lon},
      'pins': <Object?>[
        if (me != null && _found != null)
          for (final NearbyKind k in _dogKinds)
            if (_found!.of(k, me) case [final NearbySpot s, ...])
              <String, Object?>{
                'k': k.name,
                't':
                    s.name ??
                    switch (k) {
                      NearbyKind.vet => 'Veterinario',
                      NearbyKind.dogPark => 'Parque',
                      _ => 'Hotel',
                    },
                'lat': s.point.lat,
                'lon': s.point.lon,
              },
      ],
      'cats': <Object?>[
        <String, Object?>{'k': NearbyKind.vet.name, 't': 'Veterinarios'},
        <String, Object?>{'k': NearbyKind.dogPark.name, 't': 'Parques'},
        <String, Object?>{'k': NearbyKind.petStay.name, 't': 'Hoteles'},
      ],
      'kind': _kind.name,
      'spots': <Object?>[
        if (me != null)
          for (final NearbySpot s in list)
            <String, Object?>{
              'name': s.name ?? shortKind,
              'sub': <String>[
                t.nearbyMeters(me.distanceTo(s.point).round()),
                ?s.openingHours,
              ].join(' · '),
              'phone': s.phone != null,
              'web': s.website != null,
            },
      ],
      'nearMsg': msg ?? '',
      'canRetry': retry,
      'canGo': list.isNotEmpty,
      'attr': _found?.attribution ?? '',
      'bag': <Object?>[
        for (int i = 0; i < dogBagItems.length; i++)
          <String, Object?>{'t': dogBagItems[i], 'on': _bag.contains(i)},
      ],
      'petKg': _petKg,
      'carrierKg': _carrierKg,
      'verdict': place == null
          ? null
          : <String, Object?>{
              'cabin': place == PetPlace.cabin,
              'h': place == PetPlace.cabin ? t.twCabin : t.twHold,
              'p': place == PetPlace.cabin
                  ? t.twCabinWhy(max)
                  : t.twHoldWhy(max),
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
    if (_html == null) {
      _html = travelWithPageWith(page, data);
      _shown = data;
    } else {
      final Map<String, Object?> diff = changedKeys(_shown, data);
      if (diff.isNotEmpty) {
        _shown = data;
        unawaited(_bridge.run(travelWithPushScript(diff)));
      }
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
