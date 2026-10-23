// La "superficie" del mapa: el dibujo en sí, hecho por MapLibre.
//
// MapLibre dibuja con la tarjeta gráfica del móvil (código nativo de Android
// e iOS), así que en los tests de Flutter no puede funcionar. Por eso la
// pantalla del mapa no usa MapLibre directamente, sino esta pequeña
// "interfaz": en la app real la cumple MapLibreSurface y en los tests, un
// mapa falso que solo apunta lo que le piden.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:maplibre_gl/maplibre_gl.dart';

import 'geo.dart';
import 'map_style.dart';

/// Lo que la pantalla le puede pedir al mapa.
abstract interface class MapSurfaceController {
  /// Dibuja estas zonas (un FeatureCollection de GeoJSON).
  Future<void> showZones(Map<String, Object?> features);

  /// Dibuja tu posición (o la quita, con null).
  Future<void> showMe(GeoPoint? me);

  /// Mueve la cámara con una animación suave.
  Future<void> flyTo(GeoPoint target, {double? zoom});

  /// Inclina la cámara: 0 = vista desde arriba (2D), 60 = en perspectiva (3D).
  Future<void> setTilt(double degrees);

  /// El rectángulo que se ve ahora mismo.
  Future<GeoBox?> visibleBox();
}

/// Todo lo que la superficie necesita para dibujarse.
class MapSurfaceSpec {
  const MapSurfaceSpec({
    required this.style,
    required this.initialCenter,
    required this.initialZoom,
    required this.onReady,
    required this.onIdle,
    required this.onTap,
  });

  /// El estilo (ver map_style.dart). Si cambia, el mapa se redibuja entero
  /// y vuelve a llamar a [onReady].
  final Map<String, Object?> style;
  final GeoPoint initialCenter;
  final double initialZoom;

  /// El estilo ya está cargado: se pueden dibujar zonas y la posición.
  final void Function(MapSurfaceController controller) onReady;

  /// La cámara dejó de moverse (momento de pedir zonas nuevas).
  final VoidCallback onIdle;

  /// Toque en el mapa, en coordenadas.
  final void Function(GeoPoint point) onTap;
}

typedef MapSurfaceBuilder = Widget Function(MapSurfaceSpec spec);

/// El mapa de verdad, con MapLibre.
class MapLibreSurface extends StatefulWidget {
  const MapLibreSurface({super.key, required this.spec});

  final MapSurfaceSpec spec;

  @override
  State<MapLibreSurface> createState() => _MapLibreSurfaceState();
}

class _MapLibreSurfaceState extends State<MapLibreSurface> {
  MapLibreMapController? _controller;
  // El JSON del estilo se calcula una vez por estilo distinto: convertirlo
  // a texto en cada redibujado sería trabajo tirado.
  Map<String, Object?>? _styleFor;
  String _styleJson = '';

  String get _style {
    if (!identical(_styleFor, widget.spec.style)) {
      _styleFor = widget.spec.style;
      _styleJson = jsonEncode(widget.spec.style);
    }
    return _styleJson;
  }

  @override
  Widget build(BuildContext context) {
    final MapSurfaceSpec spec = widget.spec;
    return MapLibreMap(
      styleString: _style,
      initialCameraPosition: CameraPosition(
        target: LatLng(spec.initialCenter.lat, spec.initialCenter.lon),
        zoom: spec.initialZoom,
      ),
      onMapCreated: (MapLibreMapController c) => _controller = c,
      onStyleLoadedCallback: () {
        final MapLibreMapController? c = _controller;
        if (c != null) spec.onReady(_MapLibreController(c));
      },
      onCameraIdle: spec.onIdle,
      onMapClick: (_, LatLng at) =>
          spec.onTap(GeoPoint(at.latitude, at.longitude)),
      // La brújula aparece al girar el mapa; al tocarla vuelve al norte.
      compassEnabled: true,
      // Los créditos de OpenStreetMap son obligatorios (licencia ODbL):
      // el botón (i) los muestra.
      attributionButtonPosition: AttributionButtonPosition.bottomLeft,
      minMaxZoomPreference: const MinMaxZoomPreference(2, 19),
    );
  }
}

class _MapLibreController implements MapSurfaceController {
  _MapLibreController(this._c);

  final MapLibreMapController _c;

  @override
  Future<void> showZones(Map<String, Object?> features) =>
      _c.setGeoJsonSource(MapIds.zonesSource, features);

  @override
  Future<void> showMe(GeoPoint? me) => _c.setGeoJsonSource(
    MapIds.meSource,
    me == null
        ? emptyFeatures
        : <String, Object?>{
            'type': 'FeatureCollection',
            'features': <Object?>[
              <String, Object?>{
                'type': 'Feature',
                'id': 'me',
                'geometry': <String, Object?>{
                  'type': 'Point',
                  'coordinates': <double>[me.lon, me.lat],
                },
                'properties': <String, Object?>{},
              },
            ],
          },
  );

  @override
  Future<void> flyTo(GeoPoint target, {double? zoom}) async {
    final LatLng at = LatLng(target.lat, target.lon);
    await _c.animateCamera(
      zoom == null
          ? CameraUpdate.newLatLng(at)
          : CameraUpdate.newLatLngZoom(at, zoom),
      duration: const Duration(milliseconds: 900),
    );
  }

  @override
  Future<void> setTilt(double degrees) async {
    await _c.animateCamera(
      CameraUpdate.tiltTo(degrees),
      duration: const Duration(milliseconds: 600),
    );
  }

  @override
  Future<GeoBox?> visibleBox() async {
    final LatLngBounds b = await _c.getVisibleRegion();
    final GeoBox box = GeoBox(
      minLon: b.southwest.longitude,
      minLat: b.southwest.latitude,
      maxLon: b.northeast.longitude,
      maxLat: b.northeast.latitude,
    );
    // Cerca de la línea de cambio de fecha (el Pacífico) el rectángulo
    // "da la vuelta" al mundo: ahí no pedimos zonas.
    return box.isValid ? box : null;
  }
}
