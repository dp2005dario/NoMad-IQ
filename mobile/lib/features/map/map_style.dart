// El "estilo" del mapa: qué se dibuja y de qué color (agua, calles,
// edificios en 3D, nombres...). Es un JSON con el formato estándar de
// MapLibre (https://maplibre.org/maplibre-style-spec/).
//
// Lo generamos en código en vez de tenerlo en un archivo fijo porque cambia:
//   - según la hora: de día, al atardecer o de noche (como en las maquetas);
//   - según tu idioma: las calles y ciudades se rotulan en tu idioma si el
//     mapa tiene el nombre traducido.
//
// Los datos (las "teselas") son de OpenStreetMap y los sirve OpenFreeMap,
// gratis y sin registrarse ni rastrear a nadie. Siguen el esquema
// "OpenMapTiles": por eso las capas se llaman water, building, transportation...
import 'package:flutter/painting.dart';

/// Ids que usa la app para dibujar sus cosas encima del mapa.
abstract final class MapIds {
  static const String zonesSource = 'nomad-zones';
  static const String zonesFill = 'nomad-zones-fill';
  static const String zonesLine = 'nomad-zones-line';
  static const String zonesLabel = 'nomad-zones-label';
  static const String meSource = 'nomad-me';
}

/// Cómo se ve el mapa. "auto" elige según la hora.
enum MapLook { auto, day, dusk, night }

/// Elige el aspecto real: de 7 a 18 h día, de 18 a 21 h atardecer, si no noche.
MapLook resolveLook(MapLook chosen, DateTime now) {
  if (chosen != MapLook.auto) return chosen;
  final int h = now.hour;
  if (h >= 7 && h < 18) return MapLook.day;
  if (h >= 18 && h < 21) return MapLook.dusk;
  return MapLook.night;
}

/// Los colores de cada aspecto (sacados de las maquetas del Mapa).
class MapPalette {
  const MapPalette({
    required this.background,
    required this.water,
    required this.park,
    required this.minorRoad,
    required this.majorRoad,
    required this.building,
    required this.buildingTop,
    required this.label,
    required this.labelHalo,
  });

  final Color background;
  final Color water;
  final Color park;
  final Color minorRoad;
  final Color majorRoad;
  final Color building;
  final Color buildingTop;
  final Color label;
  final Color labelHalo;

  static const MapPalette day = MapPalette(
    background: Color(0xFFDCE0D6),
    water: Color(0xFF7FC0E6),
    park: Color(0xFFA9CFA0),
    minorRoad: Color(0xFFF4F1EA),
    majorRoad: Color(0xFFFFFFFF),
    building: Color(0xFFC3B6A2),
    buildingTop: Color(0xFFF7F2E9),
    label: Color(0xFF39474F),
    labelHalo: Color(0xFFF4F1EA),
  );

  static const MapPalette dusk = MapPalette(
    background: Color(0xFF6F6577),
    water: Color(0xFF6E8EB8),
    park: Color(0xFF3F6B4E),
    minorRoad: Color(0xFF958797),
    majorRoad: Color(0xFFB29C90),
    building: Color(0xFF7E5F66),
    buildingTop: Color(0xFFE2B08C),
    label: Color(0xFFF5E6DC),
    labelHalo: Color(0xFF3B3443),
  );

  /// La noche usa el fondo de la app (#0B1217): es el aspecto "de marca".
  static const MapPalette night = MapPalette(
    background: Color(0xFF0B1217),
    water: Color(0xFF1F527A),
    park: Color(0xFF16302A),
    minorRoad: Color(0xFF1C2638),
    majorRoad: Color(0xFF2A3449),
    building: Color(0xFF161D2C),
    buildingTop: Color(0xFF2A3449),
    label: Color(0xFF8FA2B4),
    labelHalo: Color(0xFF0B1217),
  );

  static MapPalette of(MapLook look) => switch (look) {
    MapLook.day => day,
    MapLook.dusk => dusk,
    MapLook.night || MapLook.auto => night,
  };
}

/// Colores de las zonas de NomadIQ (iguales en los tres aspectos).
abstract final class ZoneColors {
  static const Color audioguide = Color(0xFF3DDC97); // menta: hay audioguía
  static const Color airport = Color(0xFF6CA8FF); // azul de Vuelos
  static const Color restricted = Color(0xFFFF8A65); // naranja de seguridad
}

/// "#RRGGBB", que es como MapLibre entiende los colores.
String hex(Color c) {
  String two(double v) =>
      (v * 255).round().clamp(0, 255).toRadixString(16).padLeft(2, '0');
  return '#${two(c.r)}${two(c.g)}${two(c.b)}';
}

/// Una colección GeoJSON vacía (para las fuentes que se rellenan después).
const Map<String, Object?> emptyFeatures = <String, Object?>{
  'type': 'FeatureCollection',
  'features': <Object?>[],
};

/// Construye el estilo completo.
/// [language] = código del idioma de la app ("es", "ar", "zh"...).
Map<String, Object?> buildMapStyle({
  required MapLook look,
  required String language,
  required Uri tilesUrl,
  required String glyphsUrl,
}) {
  final MapPalette p = MapPalette.of(look);
  // El nombre en tu idioma; si no lo hay, en alfabeto latino; si tampoco,
  // el nombre local. Así un turista español en Tokio ve "Shinjuku" y no
  // 新宿, pero un japonés sí ve 新宿.
  final List<Object?> name = <Object?>[
    'coalesce',
    <Object?>['get', 'name:$language'],
    <Object?>['get', 'name:latin'],
    <Object?>['get', 'name'],
  ];
  const List<String> regular = <String>['Noto Sans Regular'];
  const List<String> bold = <String>['Noto Sans Bold'];
  // Grosor de las calles según el zoom (más cerca = más gruesas).
  List<Object?> width(double z12, double z18) => <Object?>[
    'interpolate',
    <Object?>['exponential', 1.6],
    <Object?>['zoom'],
    12,
    z12,
    18,
    z18,
  ];

  return <String, Object?>{
    'version': 8,
    'name': 'NomadIQ ${look.name}',
    'glyphs': glyphsUrl,
    'sources': <String, Object?>{
      'openmaptiles': <String, Object?>{
        'type': 'vector',
        'url': tilesUrl.toString(),
      },
      MapIds.zonesSource: <String, Object?>{
        'type': 'geojson',
        'data': emptyFeatures,
      },
      MapIds.meSource: <String, Object?>{
        'type': 'geojson',
        'data': emptyFeatures,
      },
    },
    'layers': <Object?>[
      <String, Object?>{
        'id': 'background',
        'type': 'background',
        'paint': <String, Object?>{'background-color': hex(p.background)},
      },
      <String, Object?>{
        'id': 'park',
        'type': 'fill',
        'source': 'openmaptiles',
        'source-layer': 'park',
        'paint': <String, Object?>{'fill-color': hex(p.park)},
      },
      <String, Object?>{
        'id': 'landcover-green',
        'type': 'fill',
        'source': 'openmaptiles',
        'source-layer': 'landcover',
        'filter': <Object?>[
          'in',
          <Object?>['get', 'class'],
          <Object?>[
            'literal',
            <String>['wood', 'grass', 'farmland'],
          ],
        ],
        'paint': <String, Object?>{
          'fill-color': hex(p.park),
          'fill-opacity': 0.6,
        },
      },
      <String, Object?>{
        'id': 'water',
        'type': 'fill',
        'source': 'openmaptiles',
        'source-layer': 'water',
        'paint': <String, Object?>{'fill-color': hex(p.water)},
      },
      <String, Object?>{
        'id': 'waterway',
        'type': 'line',
        'source': 'openmaptiles',
        'source-layer': 'waterway',
        'paint': <String, Object?>{
          'line-color': hex(p.water),
          'line-width': width(1, 4),
        },
      },
      <String, Object?>{
        'id': 'road-minor',
        'type': 'line',
        'source': 'openmaptiles',
        'source-layer': 'transportation',
        'minzoom': 13,
        'filter': <Object?>[
          'in',
          <Object?>['get', 'class'],
          <Object?>[
            'literal',
            <String>['minor', 'service', 'pedestrian', 'path', 'track'],
          ],
        ],
        'layout': <String, Object?>{'line-cap': 'round', 'line-join': 'round'},
        'paint': <String, Object?>{
          'line-color': hex(p.minorRoad),
          'line-width': width(0.5, 9),
        },
      },
      <String, Object?>{
        'id': 'road-major',
        'type': 'line',
        'source': 'openmaptiles',
        'source-layer': 'transportation',
        'filter': <Object?>[
          'in',
          <Object?>['get', 'class'],
          <Object?>[
            'literal',
            <String>['motorway', 'trunk', 'primary', 'secondary', 'tertiary'],
          ],
        ],
        'layout': <String, Object?>{'line-cap': 'round', 'line-join': 'round'},
        'paint': <String, Object?>{
          'line-color': hex(p.majorRoad),
          'line-width': width(1.2, 16),
        },
      },
      // Los edificios en 3D: la altura sale de OpenStreetMap (render_height).
      // Se ven "de pie" al inclinar el mapa con el botón 3D.
      <String, Object?>{
        'id': 'building-3d',
        'type': 'fill-extrusion',
        'source': 'openmaptiles',
        'source-layer': 'building',
        'minzoom': 14,
        'paint': <String, Object?>{
          'fill-extrusion-color': <Object?>[
            'interpolate',
            <Object?>['linear'],
            <Object?>[
              'coalesce',
              <Object?>['get', 'render_height'],
              0,
            ],
            0,
            hex(p.building),
            60,
            hex(p.buildingTop),
          ],
          'fill-extrusion-height': <Object?>[
            'coalesce',
            <Object?>['get', 'render_height'],
            6,
          ],
          'fill-extrusion-base': <Object?>[
            'coalesce',
            <Object?>['get', 'render_min_height'],
            0,
          ],
          'fill-extrusion-opacity': 0.9,
        },
      },
      // Nuestras zonas: un velo de color con su borde.
      <String, Object?>{
        'id': MapIds.zonesFill,
        'type': 'fill',
        'source': MapIds.zonesSource,
        'paint': <String, Object?>{
          'fill-color': _zoneColor(),
          'fill-opacity': <Object?>[
            'case',
            <Object?>['get', 'selected'],
            0.32,
            0.16,
          ],
        },
      },
      <String, Object?>{
        'id': MapIds.zonesLine,
        'type': 'line',
        'source': MapIds.zonesSource,
        'paint': <String, Object?>{
          'line-color': _zoneColor(),
          'line-width': <Object?>[
            'case',
            <Object?>['get', 'selected'],
            3.5,
            1.5,
          ],
        },
      },
      <String, Object?>{
        'id': 'road-names',
        'type': 'symbol',
        'source': 'openmaptiles',
        'source-layer': 'transportation_name',
        'minzoom': 14,
        'layout': <String, Object?>{
          'symbol-placement': 'line',
          'text-field': name,
          'text-font': regular,
          'text-size': 11,
        },
        'paint': <String, Object?>{
          'text-color': hex(p.label),
          'text-halo-color': hex(p.labelHalo),
          'text-halo-width': 1.4,
        },
      },
      <String, Object?>{
        'id': 'poi-names',
        'type': 'symbol',
        'source': 'openmaptiles',
        'source-layer': 'poi',
        'minzoom': 16,
        'filter': <Object?>[
          '<=',
          <Object?>['get', 'rank'],
          20,
        ],
        'layout': <String, Object?>{
          'text-field': name,
          'text-font': regular,
          'text-size': 11,
          'text-max-width': 8,
        },
        'paint': <String, Object?>{
          'text-color': hex(p.label),
          'text-halo-color': hex(p.labelHalo),
          'text-halo-width': 1.2,
        },
      },
      <String, Object?>{
        'id': 'place-names',
        'type': 'symbol',
        'source': 'openmaptiles',
        'source-layer': 'place',
        'layout': <String, Object?>{
          'text-field': name,
          'text-font': bold,
          'text-size': <Object?>[
            'match',
            <Object?>['get', 'class'],
            'city',
            16,
            'town',
            14,
            12,
          ],
          'text-max-width': 8,
        },
        'paint': <String, Object?>{
          'text-color': hex(p.label),
          'text-halo-color': hex(p.labelHalo),
          'text-halo-width': 1.6,
        },
      },
      <String, Object?>{
        'id': MapIds.zonesLabel,
        'type': 'symbol',
        'source': MapIds.zonesSource,
        'minzoom': 12,
        'layout': <String, Object?>{
          'text-field': <Object?>['get', 'name'],
          'text-font': bold,
          'text-size': 13,
          'text-max-width': 9,
        },
        'paint': <String, Object?>{
          'text-color': _zoneColor(),
          'text-halo-color': hex(p.labelHalo),
          'text-halo-width': 1.8,
        },
      },
      // Tú: un punto menta con un halo que indica el error del GPS.
      <String, Object?>{
        'id': 'nomad-me-halo',
        'type': 'circle',
        'source': MapIds.meSource,
        'paint': <String, Object?>{
          'circle-color': hex(ZoneColors.audioguide),
          'circle-opacity': 0.18,
          'circle-radius': 22,
        },
      },
      <String, Object?>{
        'id': 'nomad-me-dot',
        'type': 'circle',
        'source': MapIds.meSource,
        'paint': <String, Object?>{
          'circle-color': hex(ZoneColors.audioguide),
          'circle-radius': 7,
          'circle-stroke-color': '#ffffff',
          'circle-stroke-width': 2.5,
        },
      },
    ],
  };
}

List<Object?> _zoneColor() => <Object?>[
  'match',
  <Object?>['get', 'kind'],
  'airport',
  hex(ZoneColors.airport),
  'restricted',
  hex(ZoneColors.restricted),
  hex(ZoneColors.audioguide),
];
