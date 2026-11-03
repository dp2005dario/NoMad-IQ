// Un mapa pequeño con puntos de colores (el mismo mapa de OpenStreetMap con
// MapLibre que la pantalla Mapa). Lo usan Eventos ("Dónde pasan") y Cajeros.
//
// - Cada punto lleva su color; el elegido sale más grande.
// - Tocar cerca de un punto (a menos de [pickMeters]) lo elige.
// - Con [tilt] el mapa se inclina en 3D (edificios en relieve).
// - Si se sabe dónde estás ([me]), sale tu punto y el botón de centrar.
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/services.dart';
import '../../core/theme.dart';
import '../../l10n/generated/app_localizations.dart';
import 'geo.dart';
import 'map_style.dart';
import 'map_surface.dart';

/// Un punto del mapa.
class MapPin {
  const MapPin({required this.id, required this.point, required this.color});

  final String id;
  final GeoPoint point;
  final Color color;
}

class PinMap extends StatefulWidget {
  const PinMap({
    super.key,
    required this.pins,
    required this.onPick,
    this.selected,
    this.me,
    this.tilt = false,
    this.aspectRatio = 1.4,
    this.pickMeters = 600,
    this.controls = false,
  });

  final List<MapPin> pins;

  /// El id del punto elegido (sale más grande).
  final String? selected;

  /// Dónde estás tú (punto verde), si se sabe.
  final GeoPoint? me;

  /// Empezar inclinado en 3D.
  final bool tilt;
  final double aspectRatio;

  /// Más lejos de esto no cuenta como tocar un punto.
  final double pickMeters;

  /// Botones de 3D y de centrar en ti.
  final bool controls;
  final ValueChanged<MapPin> onPick;

  @override
  State<PinMap> createState() => _PinMapState();
}

class _PinMapState extends State<PinMap> {
  late final AppServices _services = ServicesScope.of(context);
  MapSurfaceController? _map;
  Map<String, Object?>? _style;
  late bool _tilted = widget.tilt;

  static String _hex(Color c) =>
      '#${(c.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}';

  @override
  void didUpdateWidget(PinMap old) {
    super.didUpdateWidget(old);
    if (old.selected != widget.selected ||
        old.pins != widget.pins ||
        old.me != widget.me) {
      unawaited(_draw());
    }
    final MapPin? sel = _selected;
    if (sel != null && old.selected != widget.selected) {
      unawaited(_map?.flyTo(sel.point));
    }
  }

  MapPin? get _selected {
    for (final MapPin p in widget.pins) {
      if (p.id == widget.selected) return p;
    }
    return null;
  }

  /// Los puntos en GeoJSON (lo que entiende MapLibre).
  Future<void> _draw() async {
    final MapSurfaceController? map = _map;
    if (map == null) return;
    await map.showPins(<String, Object?>{
      'type': 'FeatureCollection',
      'features': <Object?>[
        for (final MapPin p in widget.pins)
          <String, Object?>{
            'type': 'Feature',
            'id': p.id,
            'geometry': <String, Object?>{
              'type': 'Point',
              'coordinates': <double>[p.point.lon, p.point.lat],
            },
            'properties': <String, Object?>{
              'color': _hex(p.color),
              'selected': p.id == widget.selected,
            },
          },
      ],
    });
    await map.showMe(widget.me);
  }

  /// Tocar el mapa: el punto más cercano al dedo (si está cerca).
  void _tap(GeoPoint at) {
    MapPin? best;
    double bestM = double.infinity;
    for (final MapPin p in widget.pins) {
      final double m = at.distanceTo(p.point);
      if (m < bestM) (best, bestM) = (p, m);
    }
    if (best != null && bestM <= widget.pickMeters) widget.onPick(best);
  }

  Future<void> _toggleTilt() async {
    setState(() => _tilted = !_tilted);
    await _map?.setTilt(_tilted ? 55 : 0);
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    final List<GeoPoint> all = <GeoPoint>[
      for (final MapPin p in widget.pins) p.point,
      ?widget.me,
    ];
    double minLat = 90, maxLat = -90, minLon = 180, maxLon = -180;
    for (final GeoPoint p in all) {
      minLat = math.min(minLat, p.lat);
      maxLat = math.max(maxLat, p.lat);
      minLon = math.min(minLon, p.lon);
      maxLon = math.max(maxLon, p.lon);
    }
    if (all.isEmpty) (minLat, maxLat, minLon, maxLon) = (0, 0, 0, 0);
    // El zum para que quepan todos: cada nivel ve la mitad que el anterior.
    final double span = math.max(
      math.max(maxLat - minLat, maxLon - minLon),
      0.005,
    );
    final double zoom = (math.log(360 / span) / math.ln2 - 1.2).clamp(9, 16);
    _style ??= buildMapStyle(
      look: resolveLook(MapLook.auto, DateTime.now()),
      language: Localizations.localeOf(context).languageCode,
      tilesUrl: _services.tilesUrl,
      glyphsUrl: _services.glyphsUrl,
    );
    return AspectRatio(
      aspectRatio: widget.aspectRatio,
      child: Container(
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: NomadColors.outline),
        ),
        child: Stack(
          children: <Widget>[
            Positioned.fill(
              child: _services.mapSurface(
                MapSurfaceSpec(
                  style: _style!,
                  initialCenter: GeoPoint(
                    (minLat + maxLat) / 2,
                    (minLon + maxLon) / 2,
                  ),
                  initialZoom: zoom,
                  onReady: (MapSurfaceController c) {
                    _map = c;
                    if (_tilted) unawaited(c.setTilt(55));
                    unawaited(_draw());
                  },
                  onIdle: () {},
                  onTap: _tap,
                ),
              ),
            ),
            if (widget.controls)
              PositionedDirectional(
                top: 8,
                end: 8,
                child: Column(
                  children: <Widget>[
                    _MapButton(
                      icon: Icons.view_in_ar_rounded,
                      label: t.mapTiltTooltip,
                      on: _tilted,
                      onTap: () => unawaited(_toggleTilt()),
                    ),
                    if (widget.me != null) ...<Widget>[
                      const SizedBox(height: 6),
                      _MapButton(
                        icon: Icons.my_location_rounded,
                        label: t.mapMyLocation,
                        on: false,
                        onTap: () => unawaited(_map?.flyTo(widget.me!)),
                      ),
                    ],
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _MapButton extends StatelessWidget {
  const _MapButton({
    required this.icon,
    required this.label,
    required this.on,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool on;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    toggled: on,
    label: label,
    excludeSemantics: true,
    child: Material(
      color: on ? NomadColors.mint : const Color(0xE00E181E),
      borderRadius: BorderRadius.circular(11),
      child: InkWell(
        borderRadius: BorderRadius.circular(11),
        onTap: onTap,
        child: SizedBox.square(
          dimension: 40,
          child: Icon(
            icon,
            size: 20,
            color: on ? NomadColors.background : NomadColors.text,
          ),
        ),
      ),
    ),
  );
}
