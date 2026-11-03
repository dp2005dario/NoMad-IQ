// Cajeros cerca (maqueta "Cajeros cerca", la del mapa 3D como Cerca de ti).
//
// 1. Al tocar "Buscar cajeros cerca" se pide la ubicación (solo entonces,
//    para que se entienda por qué).
// 2. Se pregunta al servidor por la zona (redondeada a ~1 km). Los datos son
//    de OpenStreetMap.
// 3. Tres pestañas como la maqueta: "Sin comisión", "Abiertos 24 h" y
//    "Todos". Arriba el mapa de verdad (MapLibre, inclinado en 3D) con un
//    punto por cajero; abajo las tarjetas, de la más cercana a la más lejana.
// 4. "Ir" abre Google Maps andando hasta el cajero.
// 5. Si el servidor no responde, Flyra lo dice y enseña los últimos cajeros
//    que se guardaron de esta zona, con su fecha.
// 6. El aviso más útil de todos: si el cajero ofrece "cobrar en tu moneda",
//    di que no (la "conversión dinámica" suele salir un 5-10 % más cara).
//
// Lo que la maqueta tiene y aquí NO, porque OpenStreetMap no lo dice: cuánto
// cobra cada cajero en euros (solo si cobra o no), "con tu tarjeta" (haría
// falta saber tu banco y sus acuerdos) y "cierra en N min". Las fachadas
// dibujadas de la maqueta eran de adorno: aquí sale la inicial del banco.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../core/api_client.dart';
import '../../core/services.dart';
import '../../core/settings.dart';
import '../../core/theme.dart';
import '../../l10n/generated/app_localizations.dart';
import '../map/geo.dart';
import '../map/location.dart';
import '../map/pin_map.dart';
import '../../widgets/flyra_avatar.dart';
import 'atms_api.dart';

/// Cuántos cajeros se enseñan como mucho (los más cercanos).
const int shownAtms = 15;

enum _Phase { idle, working, noLocation, failed, done }

/// Las pestañas de la maqueta.
enum _Tab { free, open24h, all }

class AtmsPanel extends StatefulWidget {
  const AtmsPanel({super.key});

  @override
  State<AtmsPanel> createState() => _AtmsPanelState();
}

class _AtmsPanelState extends State<AtmsPanel> {
  late final AppServices _services = ServicesScope.of(context);
  _Phase _phase = _Phase.idle;
  ApiError? _error;
  GeoPoint? _me;
  AtmList? _found;
  String? _selected;
  _Tab _tab = _Tab.free;

  /// Cuándo se guardaron los cajeros que se ven (null = recién bajados).
  DateTime? _cachedAt;

  Future<GeoPoint?> _position() async {
    final LocationSource gps = _services.location;
    LocationAccess access = await gps.check();
    if (access == LocationAccess.denied) access = await gps.request();
    if (access != LocationAccess.granted) return null;
    try {
      final PositionFix fix = await gps.watch().first.timeout(
        const Duration(seconds: 15),
      );
      return fix.point;
    } on TimeoutException {
      return null;
    } on StateError {
      return null;
    }
  }

  Future<void> _search() async {
    setState(() => _phase = _Phase.working);
    final GeoPoint? me = await _position();
    if (!mounted) return;
    if (me == null) {
      setState(() => _phase = _Phase.noLocation);
      return;
    }
    try {
      final AtmList found = await _services.atms.near(me);
      await saveAtmCache(_services.prefs, me, found);
      if (!mounted) return;
      setState(() {
        _me = me;
        _found = found;
        _cachedAt = null;
        _selected = null;
        _tab = _bestTab(found, me);
        _phase = _Phase.done;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      // Sin servidor: los últimos guardados de esta zona, si los hay.
      final (AtmList, DateTime)? cached = readAtmCache(_services.prefs, me);
      setState(() {
        _error = e.error;
        if (cached == null) {
          _phase = _Phase.failed;
        } else {
          _me = me;
          _found = cached.$1;
          _cachedAt = cached.$2;
          _selected = null;
          _tab = _bestTab(cached.$1, me);
          _phase = _Phase.done;
        }
      });
    }
  }

  /// Empieza en "Sin comisión" si hay alguno; si no, en "Todos".
  static _Tab _bestTab(AtmList found, GeoPoint me) =>
      found.atms.any((Atm a) => a.fee == false) ? _Tab.free : _Tab.all;

  static bool _inTab(_Tab tab, Atm a) => switch (tab) {
    _Tab.free => a.fee == false,
    _Tab.open24h => a.open24h,
    _Tab.all => true,
  };

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    final TextTheme text = Theme.of(context).textTheme;
    final GeoPoint? me = _me;
    final AtmList? found = _found;
    final List<Atm> near = me == null || found == null
        ? const <Atm>[]
        : found.sortedFrom(me).take(shownAtms * 2).toList();
    final List<Atm> atms = near
        .where((Atm a) => _inTab(_tab, a))
        .take(shownAtms)
        .toList();
    final String tag = Localizations.localeOf(context).toLanguageTag();
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 40),
      children: <Widget>[
        if (_phase == _Phase.done && me != null) ...<Widget>[
          if (_cachedAt != null) ...<Widget>[
            _FlyraWarn(
              title: t.atmsOfflineTitle,
              text: t.atmsOfflineText(
                DateFormat.yMMMd(tag).add_Hm().format(_cachedAt!),
              ),
              onRetry: _search,
            ),
            const SizedBox(height: 12),
          ],
          SegmentedButton<_Tab>(
            showSelectedIcon: false,
            segments: <ButtonSegment<_Tab>>[
              ButtonSegment<_Tab>(value: _Tab.free, label: Text(t.atmsTabFree)),
              ButtonSegment<_Tab>(
                value: _Tab.open24h,
                label: Text(t.atmsTab24h),
              ),
              ButtonSegment<_Tab>(value: _Tab.all, label: Text(t.atmsTabAll)),
            ],
            selected: <_Tab>{_tab},
            onSelectionChanged: (Set<_Tab> v) =>
                setState(() => (_tab = v.first, _selected = null)),
          ),
          const SizedBox(height: 12),
          if (near.isEmpty)
            Text(t.abroadAtmsNone, style: text.bodyLarge)
          else ...<Widget>[
            PinMap(
              pins: <MapPin>[
                for (final Atm a in atms)
                  MapPin(id: a.id, point: a.point, color: feeColor(a.fee)),
              ],
              selected: _selected,
              me: me,
              tilt: true,
              controls: true,
              aspectRatio: 1.25,
              pickMeters: 250,
              onPick: (MapPin p) => setState(() => _selected = p.id),
            ),
            const SizedBox(height: 12),
            if (atms.isEmpty)
              Text(t.atmsNoneInTab, style: text.bodyLarge)
            else
              for (final Atm a in atms)
                _AtmCard(
                  atm: a,
                  meters: a.point.distanceTo(me).round(),
                  selected: a.id == _selected,
                  onTap: () => setState(() => _selected = a.id),
                  onGo: () => unawaited(_go(a.point)),
                  onMap: () => unawaited(_services.openBooking(a.mapUrl)),
                ),
          ],
          const SizedBox(height: 4),
          Text(
            found!.attribution,
            style: const TextStyle(fontSize: 11, color: NomadColors.textMuted),
          ),
          const SizedBox(height: 12),
        ] else ...<Widget>[
          Text(t.abroadAtmsIntro, style: text.bodyLarge),
          const SizedBox(height: 16),
          if (_phase == _Phase.noLocation)
            _Problem(t.cameraNoLocation)
          else if (_phase == _Phase.failed)
            _FlyraWarn(
              title: t.atmsOfflineTitle,
              text: _error == ApiError.network
                  ? t.errorNetwork
                  : t.errorUnavailable,
              onRetry: _search,
            ),
          const SizedBox(height: 8),
          FilledButton.icon(
            onPressed: _phase == _Phase.working ? null : _search,
            icon: _phase == _Phase.working
                ? const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.near_me_rounded),
            label: Text(t.abroadAtmsSearch),
          ),
          const SizedBox(height: 16),
        ],
        const _DccTip(),
      ],
    );
  }

  /// "Ir": Google Maps andando hasta el cajero (un enlace, gratis).
  Future<void> _go(GeoPoint p) => _services.openBooking(
    Uri.https('www.google.com', '/maps/dir/', <String, String>{
      'api': '1',
      'destination': '${p.lat.toStringAsFixed(5)},${p.lon.toStringAsFixed(5)}',
      'travelmode': 'walking',
    }),
  );
}

/// Guarda los últimos cajeros de la zona (por si luego falla el servidor).
Future<void> saveAtmCache(SettingsStore prefs, GeoPoint at, AtmList list) =>
    prefs.writeData(
      LocalData.atmsCache,
      jsonEncode(<String, Object?>{
        'lat': at.lat,
        'lon': at.lon,
        'saved_at': DateTime.now().toUtc().toIso8601String(),
        'list': list.toJson(),
      }),
    );

/// Los cajeros guardados, solo si son de esta zona (a menos de 3 km).
(AtmList, DateTime)? readAtmCache(SettingsStore prefs, GeoPoint me) {
  try {
    final Object? json = jsonDecode(
      prefs.readData(LocalData.atmsCache) ?? 'null',
    );
    if (json is! Map<String, Object?>) return null;
    final Object? lat = json['lat'];
    final Object? lon = json['lon'];
    final DateTime? at = DateTime.tryParse('${json['saved_at']}');
    if (lat is! num || lon is! num || at == null) return null;
    if (GeoPoint(lat.toDouble(), lon.toDouble()).distanceTo(me) > 3000) {
      return null;
    }
    return (AtmList.parse(json['list']), at.toLocal());
  } on FormatException {
    return null;
  } on ApiException {
    return null;
  }
}

/// Flyra avisa de que algo no carga (como en la maqueta).
class _FlyraWarn extends StatelessWidget {
  const _FlyraWarn({
    required this.title,
    required this.text,
    required this.onRetry,
  });

  final String title;
  final String text;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF121B21),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0x73FFB86B)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const FlyraAvatar(size: 40),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  title,
                  style: const TextStyle(fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 4),
                Text(text, style: const TextStyle(color: Color(0xFFB9C6CC))),
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: TextButton(
                    onPressed: onRetry,
                    child: Text(t.guideRetry),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Problem extends StatelessWidget {
  const _Problem(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: Text(text, style: const TextStyle(color: NomadColors.safety)),
  );
}

/// "Si el cajero te ofrece cobrar en tu moneda, di que no".
class _DccTip extends StatelessWidget {
  const _DccTip();

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF2A2418),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: NomadColors.money),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const Icon(Icons.lightbulb_rounded, color: NomadColors.money),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  t.abroadDccTitle,
                  style: const TextStyle(fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 4),
                Text(
                  t.abroadDccText,
                  style: const TextStyle(color: NomadColors.textMuted),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// El color de la comisión: verde = no cobra, amarillo = no se sabe,
/// rojo = cobra.
Color feeColor(bool? fee) => fee == false
    ? NomadColors.mint
    : fee == null
    ? const Color(0xFFFFD166)
    : NomadColors.safety;

String distanceText(AppLocalizations t, int meters) => meters < 1000
    ? t.abroadMeters(meters)
    : t.abroadKm((meters / 1000).toStringAsFixed(1));

/// Las letras del banco para su insignia ("Seven Bank" → "SB"). No son
/// logos: solo las iniciales sobre un color sacado del nombre.
String bankInitials(String? name) {
  if (name == null || name.trim().isEmpty) return '€';
  final List<String> words = name
      .trim()
      .split(RegExp(r'\s+'))
      .where((String w) => w.isNotEmpty)
      .toList();
  if (words.length == 1) {
    final String w = words.first;
    return (w.length <= 4 ? w : w.substring(0, 3)).toUpperCase();
  }
  return words
      .take(3)
      .map((String w) => w.characters.first)
      .join()
      .toUpperCase();
}

const List<Color> _bankColors = <Color>[
  Color(0xFF1973B8),
  Color(0xFFE0453A),
  Color(0xFF00609C),
  Color(0xFFD9531E),
  Color(0xFF00744A),
  Color(0xFF1E3F9E),
  Color(0xFF00789F),
  Color(0xFFC7900E),
];

Color bankColor(String? name) {
  int h = 0;
  for (final int c in (name ?? '').codeUnits) {
    h = (h * 31 + c) & 0x7fffffff;
  }
  return _bankColors[h % _bankColors.length];
}

/// Una tarjeta de cajero: insignia del banco con su chapa de comisión, el
/// nombre, a cuánto está, el horario y "Ir".
class _AtmCard extends StatelessWidget {
  const _AtmCard({
    required this.atm,
    required this.meters,
    required this.selected,
    required this.onTap,
    required this.onGo,
    required this.onMap,
  });

  final Atm atm;
  final int meters;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onGo;
  final VoidCallback onMap;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    final String? bank = atm.operator ?? atm.name;
    final Color fee = feeColor(atm.fee);
    final List<String> meta = <String>[
      if (atm.open24h)
        t.abroadOpen24h
      else if (atm.openingHours != null)
        atm.openingHours!,
      if (atm.inBank) t.abroadInBank,
      if (atm.currencies.isNotEmpty) atm.currencies.join(' · '),
    ];
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: NomadColors.surface,
        borderRadius: BorderRadius.circular(22),
        child: InkWell(
          borderRadius: BorderRadius.circular(22),
          onTap: onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 250),
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(22),
              border: Border.all(
                color: selected ? NomadColors.mint : NomadColors.outline,
                width: selected ? 1.6 : 1,
              ),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                // La insignia: el color y las iniciales del banco, con la
                // chapa de la comisión encima.
                Container(
                  width: 84,
                  height: 96,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(16),
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: <Color>[
                        bankColor(bank),
                        Color.lerp(bankColor(bank), Colors.black, 0.45)!,
                      ],
                    ),
                  ),
                  child: Stack(
                    children: <Widget>[
                      Center(
                        child: Text(
                          bankInitials(bank),
                          style: const TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.w900,
                            color: Colors.white,
                          ),
                        ),
                      ),
                      PositionedDirectional(
                        start: 6,
                        top: 6,
                        end: 6,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 4,
                            vertical: 3,
                          ),
                          decoration: BoxDecoration(
                            color: fee,
                            borderRadius: BorderRadius.circular(9),
                          ),
                          child: Text(
                            atm.fee == false
                                ? t.abroadFeeNo
                                : atm.fee == null
                                ? t.abroadFeeUnknown
                                : t.abroadFeeYes,
                            textAlign: TextAlign.center,
                            maxLines: 2,
                            style: const TextStyle(
                              fontSize: 9.5,
                              height: 1.1,
                              fontWeight: FontWeight.w900,
                              color: NomadColors.background,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        atm.label ?? t.abroadAtmUnnamed,
                        style: const TextStyle(
                          fontSize: 15.5,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '${distanceText(t, meters)} · '
                        '${t.atmsWalk((meters / 75).ceil().clamp(1, 999))}',
                        style: const TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      if (meta.isNotEmpty)
                        Text(
                          meta.join(' · '),
                          style: const TextStyle(
                            fontSize: 12,
                            color: NomadColors.textMuted,
                          ),
                        ),
                      const SizedBox(height: 6),
                      // Wrap: si no caben (idiomas largos), bajan de línea.
                      Wrap(
                        spacing: 6,
                        runSpacing: 4,
                        children: <Widget>[
                          // El tema hace los botones de ancho completo: aquí
                          // van en fila, así que se les da un tamaño fijo.
                          FilledButton.icon(
                            style: FilledButton.styleFrom(
                              minimumSize: const Size(64, 40),
                            ),
                            onPressed: onGo,
                            icon: const Icon(
                              Icons.directions_walk_rounded,
                              size: 18,
                            ),
                            label: Text(t.atmsGo),
                          ),
                          TextButton(
                            style: TextButton.styleFrom(
                              minimumSize: const Size(64, 40),
                            ),
                            onPressed: onMap,
                            child: Text(t.atmsSeeOsm),
                          ),
                        ],
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
