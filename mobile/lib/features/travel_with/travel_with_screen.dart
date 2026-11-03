// "Viajo con mi perro" (maqueta 49 "ViajoCon"): solo perros.
//   - Arriba, su foto y su nombre (los eliges tú y se quedan en el móvil).
//   - ¿Cabina o bodega?, según lo que pesa con el transportín.
//   - Lo que pide la UE (microchip, rabia, pasaporte), con casillas.
//   - "Para <nombre>, cerca de ti": veterinarios, parques para perros y
//     hoteles que admiten perros, sacados de OpenStreetMap (gratis) por el
//     mismo servicio que "Cerca de ti". Si OSM no tiene nada, se dice así:
//     nunca se inventa un sitio.
import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';

import '../../core/api_client.dart';
import '../../core/services.dart';
import '../../core/theme.dart';
import '../../l10n/generated/app_localizations.dart';
import '../map/geo.dart';
import '../map/location.dart';
import '../nearby/nearby_api.dart';
import 'travel_with.dart';

/// Cuántos sitios de cada tipo se enseñan como mucho (los más cercanos).
const int shownDogSpots = 8;

class TravelWithScreen extends StatelessWidget {
  const TravelWithScreen({super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(AppLocalizations.of(context).twTitle)),
    body: const _PetTab(),
  );
}

// --- Mascota -----------------------------------------------------------------

class _PetTab extends StatefulWidget {
  const _PetTab();

  @override
  State<_PetTab> createState() => _PetTabState();
}

class _PetTabState extends State<_PetTab> {
  late final AppServices _services = ServicesScope.of(context);
  late final PetChecks _checks = PetChecks(_services.prefs);
  late DogProfile _dog = DogProfile.load(_services.prefs);
  late final TextEditingController _name = TextEditingController(
    text: _dog.name ?? '',
  );
  final TextEditingController _pet = TextEditingController();
  final TextEditingController _carrier = TextEditingController(text: '2');
  Set<PetCheck>? _done;

  // "Para tu perro, cerca de ti".
  NearbyKind _kind = NearbyKind.vet;
  bool _loading = false;
  bool _noLocation = false;
  bool _noSignal = false;
  ApiError? _error;
  GeoPoint? _me;
  NearbyList? _found;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_search()));
  }

  @override
  void dispose() {
    _name.dispose();
    _pet.dispose();
    _carrier.dispose();
    super.dispose();
  }

  /// Lee un número escrito con coma o con punto ("6,5" o "6.5").
  static double? _kg(String text) =>
      double.tryParse(text.trim().replaceAll(',', '.'));

  Future<void> _toggle(PetCheck check) async {
    final bool ready = !(_done ?? <PetCheck>{}).contains(check);
    await _checks.set(check, ready: ready);
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
        maxWidth: 512, // para un círculo de 96 px sobra
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
      if (old != null && old != dest) {
        try {
          await File(old).delete();
        } on Object {
          // ya no estaba: da igual
        }
      }
    } on Object {
      // Sin permiso de cámara, cancelado a medias...: se queda la de antes.
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

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    final TextTheme text = Theme.of(context).textTheme;
    final Set<PetCheck> done = _done ??= _checks.done();
    final double? petKg = _kg(_pet.text);
    final double carrierKg = _kg(_carrier.text) ?? 0;
    final PetPlace? place = petKg == null || petKg <= 0
        ? null
        : petPlace(petKg: petKg, carrierKg: carrierKg);
    final int max = cabinMaxKg.round();
    final String who = _dog.name ?? t.twDogDefault;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
      children: <Widget>[
        Row(
          children: <Widget>[
            _DogPhoto(
              path: _dog.photoPath,
              tooltip: t.twDogPhoto,
              onTap: () => unawaited(_pickPhoto(t)),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: TextField(
                controller: _name,
                maxLength: DogProfile.maxName,
                textCapitalization: TextCapitalization.words,
                onChanged: _rename,
                decoration: InputDecoration(
                  labelText: t.twDogName,
                  hintText: t.twDogDefault,
                  counterText: '',
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Text(
          t.twSubtitle,
          style: text.bodyMedium?.copyWith(color: NomadColors.textMuted),
        ),
        const SizedBox(height: 16),
        Row(
          children: <Widget>[
            Expanded(
              child: _KgField(
                controller: _pet,
                label: t.twPetWeight,
                onChanged: () => setState(() {}),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _KgField(
                controller: _carrier,
                label: t.twCarrierWeight,
                onChanged: () => setState(() {}),
              ),
            ),
          ],
        ),
        if (place != null) ...<Widget>[
          const SizedBox(height: 16),
          _Verdict(
            color: place == PetPlace.cabin
                ? NomadColors.mint
                : NomadColors.money,
            icon: place == PetPlace.cabin
                ? Icons.airline_seat_recline_normal_rounded
                : Icons.luggage_rounded,
            title: place == PetPlace.cabin ? t.twCabin : t.twHold,
            body: place == PetPlace.cabin
                ? t.twCabinWhy(max)
                : t.twHoldWhy(max),
          ),
        ],
        const SizedBox(height: 24),
        Text(t.twEuTitle, style: text.labelLarge),
        const SizedBox(height: 8),
        for (final PetCheck c in PetCheck.values)
          Card(
            child: CheckboxListTile(
              value: done.contains(c),
              onChanged: (_) => unawaited(_toggle(c)),
              controlAffinity: ListTileControlAffinity.leading,
              title: Text(switch (c) {
                PetCheck.microchip => t.twChip,
                PetCheck.rabies => t.twRabies,
                PetCheck.passport => t.twPassport,
              }),
              subtitle: Text(switch (c) {
                PetCheck.microchip => t.twChipWhy,
                PetCheck.rabies => t.twRabiesWhy(rabiesWaitDays),
                PetCheck.passport => t.twPassportWhy,
              }),
            ),
          ),
        const SizedBox(height: 24),
        Text(t.twNearTitle(who), style: text.titleMedium),
        const SizedBox(height: 8),
        ..._near(t, text),
        const SizedBox(height: 12),
        _Tip(icon: Icons.public_rounded, text: t.twOutsideEu),
        _Tip(icon: Icons.hotel_rounded, text: t.twPetHotels),
        const SizedBox(height: 12),
        Text(
          t.twPetDisclaimer,
          style: text.bodySmall?.copyWith(color: NomadColors.textMuted),
        ),
      ],
    );
  }

  /// Veterinarios, parques y hoteles cerca (o por qué no se pueden ver).
  List<Widget> _near(AppLocalizations t, TextTheme text) {
    final GeoPoint? me = _me;
    final NearbyList? found = _found;
    if (_loading) {
      return const <Widget>[Center(child: CircularProgressIndicator())];
    }
    if (_noLocation || _error != null || me == null || found == null) {
      return <Widget>[
        Text(
          _noLocation
              ? (_noSignal ? t.nearbyNoSignal : t.cameraNoLocation)
              : _error == ApiError.network
              ? t.errorNetwork
              : t.errorUnavailable,
        ),
        const SizedBox(height: 8),
        FilledButton(onPressed: _search, child: Text(t.guideRetry)),
      ];
    }
    final (String, IconData, Color) look = _dogLook(t, _kind);
    final List<NearbySpot> list = found
        .of(_kind, me)
        .take(shownDogSpots)
        .toList();
    return <Widget>[
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: <Widget>[
          for (final NearbyKind k in _dogKinds)
            ChoiceChip(
              avatar: Icon(
                _dogLook(t, k).$2,
                size: 18,
                color: _dogLook(t, k).$3,
              ),
              label: Text(_dogLook(t, k).$1),
              selected: _kind == k,
              onSelected: (_) => setState(() => _kind = k),
            ),
        ],
      ),
      const SizedBox(height: 8),
      if (list.isEmpty)
        Text(t.twNearNone, style: text.bodyLarge)
      else
        for (final NearbySpot s in list)
          Card(
            child: ListTile(
              leading: Icon(look.$2, color: look.$3),
              title: Text(s.name ?? look.$1),
              subtitle: Text(
                <String>[
                  t.nearbyMeters(me.distanceTo(s.point).round()),
                  ?s.openingHours,
                ].join(' · '),
              ),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  if (s.phone case final String phone)
                    IconButton(
                      tooltip: t.twCall,
                      icon: const Icon(Icons.call_rounded),
                      onPressed: () => unawaited(
                        _services.openLink(
                          Uri(scheme: 'tel', path: phone.replaceAll(' ', '')),
                        ),
                      ),
                    ),
                  if (s.website case final Uri web)
                    IconButton(
                      tooltip: t.twWeb,
                      icon: const Icon(Icons.language_rounded),
                      onPressed: () => unawaited(_services.openLink(web)),
                    ),
                  IconButton(
                    tooltip: t.nearbyGo,
                    icon: const Icon(Icons.directions_walk_rounded),
                    onPressed: () => _go(s.point),
                  ),
                ],
              ),
            ),
          ),
      const SizedBox(height: 4),
      Text(
        found.attribution,
        style: const TextStyle(fontSize: 11, color: NomadColors.textMuted),
      ),
    ];
  }
}

const List<NearbyKind> _dogKinds = <NearbyKind>[
  NearbyKind.vet,
  NearbyKind.dogPark,
  NearbyKind.petStay,
];

(String, IconData, Color) _dogLook(AppLocalizations t, NearbyKind k) =>
    switch (k) {
      NearbyKind.vet => (
        t.twVets,
        Icons.local_hospital_rounded,
        NomadColors.safety,
      ),
      NearbyKind.dogPark => (t.twParks, Icons.park_rounded, NomadColors.mint),
      _ => (t.twStays, Icons.hotel_rounded, NomadColors.flights),
    };

/// La foto de tu perro en un círculo, con un anillo de colores que da una
/// vuelta al abrir la pantalla y otra cada vez que cambias la foto (no gira
/// sin parar: gasta batería. Quieto si el móvil pide "reducir movimiento").
class _DogPhoto extends StatefulWidget {
  const _DogPhoto({
    required this.path,
    required this.tooltip,
    required this.onTap,
  });

  final String? path;
  final String tooltip;
  final VoidCallback onTap;

  @override
  State<_DogPhoto> createState() => _DogPhotoState();
}

class _DogPhotoState extends State<_DogPhoto>
    with SingleTickerProviderStateMixin {
  late final AnimationController _spin = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1600),
  );
  late final Animation<double> _turn = CurvedAnimation(
    parent: _spin,
    curve: Curves.easeOutCubic,
  );

  void _play() {
    if (MediaQuery.disableAnimationsOf(context)) return;
    unawaited(_spin.forward(from: 0));
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_spin.status == AnimationStatus.dismissed) _play();
  }

  @override
  void didUpdateWidget(_DogPhoto old) {
    super.didUpdateWidget(old);
    if (old.path != widget.path) _play();
  }

  @override
  void dispose() {
    _spin.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final String? path = widget.path;
    final File? file = path == null ? null : File(path);
    return Semantics(
      button: true,
      label: widget.tooltip,
      child: Tooltip(
        message: widget.tooltip,
        child: GestureDetector(
          onTap: widget.onTap,
          child: SizedBox.square(
            dimension: 96,
            child: Stack(
              alignment: Alignment.center,
              children: <Widget>[
                RotationTransition(
                  turns: _turn,
                  child: Container(
                    decoration: const BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: SweepGradient(
                        colors: <Color>[
                          NomadColors.mint,
                          NomadColors.flights,
                          NomadColors.group,
                          NomadColors.mint,
                        ],
                        transform: GradientRotation(-math.pi / 2),
                      ),
                    ),
                  ),
                ),
                CircleAvatar(
                  radius: 44,
                  backgroundColor: NomadColors.textMuted.withValues(alpha: 0.2),
                  foregroundImage: file != null && file.existsSync()
                      ? FileImage(file)
                      : null,
                  child: const Icon(Icons.pets_rounded, size: 40),
                ),
                const Positioned(
                  right: 2,
                  bottom: 2,
                  child: CircleAvatar(
                    radius: 14,
                    child: Icon(Icons.photo_camera_rounded, size: 16),
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

class _KgField extends StatelessWidget {
  const _KgField({
    required this.controller,
    required this.label,
    required this.onChanged,
  });

  final TextEditingController controller;
  final String label;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) => TextField(
    controller: controller,
    keyboardType: const TextInputType.numberWithOptions(decimal: true),
    inputFormatters: <TextInputFormatter>[
      FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]')),
    ],
    onChanged: (_) => onChanged(),
    decoration: InputDecoration(labelText: label),
  );
}

// --- Piezas comunes ------------------------------------------------------------

/// La tarjeta de colores con la respuesta ("puede ir en cabina", "mejor no
/// volar"...).
class _Verdict extends StatelessWidget {
  const _Verdict({
    required this.color,
    required this.icon,
    required this.title,
    required this.body,
  });

  final Color color;
  final IconData icon;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.12),
      borderRadius: BorderRadius.circular(20),
      border: Border.all(color: color),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Icon(icon, color: color),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                title,
                style: Theme.of(context).textTheme.titleMedium
                    ?.copyWith(color: color),
              ),
              const SizedBox(height: 4),
              Text(body),
            ],
          ),
        ),
      ],
    ),
  );
}

class _Tip extends StatelessWidget {
  const _Tip({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Icon(icon, size: 20, color: NomadColors.textMuted),
        const SizedBox(width: 12),
        Expanded(child: Text(text)),
      ],
    ),
  );
}
