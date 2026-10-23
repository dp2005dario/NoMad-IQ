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

import 'map_patterns.dart';

/// Ids que usa la app para dibujar sus cosas encima del mapa.
abstract final class MapIds {
  static const String zonesSource = 'nomad-zones';
  static const String zonesFill = 'nomad-zones-fill';
  static const String zonesLine = 'nomad-zones-line';
  static const String zonesLabel = 'nomad-zones-label';
  static const String meSource = 'nomad-me';

  /// Texturas e iconos pintados por la app (ver map_patterns.dart).
  static const String cobblePattern = 'nq-cobble';
  static const String treesPattern = 'nq-trees';
  static const String wavesPattern = 'nq-waves';
  static const String arrowIcon = 'nq-oneway';
  static const String treeIcon = 'nq-tree';
  static const String roadMajorPattern = 'nq-road-major';
  static const String roadMinorPattern = 'nq-road-minor';
  static const String pavingPattern = 'nq-paving';
  static const String lampIcon = 'nq-lamp';
  static String carIcon(int i) => 'nq-car-$i';
  static String facade(Facade f) => 'nq-facade-${f.name}';
  static String poiIcon(PoiKind k) => 'nq-poi-${k.name}';
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
    required this.asphalt,
    required this.sidewalk,
    required this.curb,
    required this.laneMark,
    required this.cobble,
    required this.rail,
    required this.urban,
    required this.waterEdge,
    required this.light,
    required this.pitch,
    required this.roofTile,
    required this.roofSlate,
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

  // De cerca (zoom 16+) las calles dejan de ser "líneas" y parecen calles de
  // verdad: asfalto en el centro, acera a los lados y el bordillo marcando
  // el borde. Plazas y calles peatonales, con color de adoquín.
  final Color asphalt;
  final Color sidewalk;
  final Color curb;
  final Color laneMark;
  final Color cobble;
  final Color rail;

  /// Manzanas de casas y comercios (un tono apenas distinto del fondo).
  final Color urban;

  /// La orilla del agua, un poco más clara: da sensación de reflejo.
  final Color waterEdge;

  /// El color de la "luz del sol" que sombrea los edificios en 3D.
  final Color light;

  /// Césped de los campos de deporte (más vivo que el de los parques).
  final Color pitch;

  /// Tejados: de teja (rojizo) y de pizarra (oscuro).
  final Color roofTile;
  final Color roofSlate;

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
    asphalt: Color(0xFF6B7178),
    sidewalk: Color(0xFFEEE8DC),
    curb: Color(0xFFA39B8E),
    laneMark: Color(0xFFFFFFFF),
    cobble: Color(0xFFD9C7A8),
    rail: Color(0xFF9A948B),
    urban: Color(0xFFD5D6CC),
    waterEdge: Color(0xFFA9D6F0),
    light: Color(0xFFFFF4E0),
    pitch: Color(0xFF7DC27A),
    roofTile: Color(0xFFC9714F),
    roofSlate: Color(0xFF6E7681),
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
    asphalt: Color(0xFF4E4752),
    sidewalk: Color(0xFF8C7F86),
    curb: Color(0xFF5E5560),
    laneMark: Color(0xFFF2D9B8),
    cobble: Color(0xFFA48A7E),
    rail: Color(0xFF5B5260),
    urban: Color(0xFF675E70),
    waterEdge: Color(0xFF8FAED4),
    light: Color(0xFFFFC08A),
    pitch: Color(0xFF4F7D55),
    roofTile: Color(0xFF9A5A4C),
    roofSlate: Color(0xFF4F4A5A),
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
    asphalt: Color(0xFF232C3E),
    sidewalk: Color(0xFF2E384B),
    curb: Color(0xFF3B4760),
    // De noche las marcas viales "brillan" como con los faros.
    laneMark: Color(0xFFE8D9A0),
    cobble: Color(0xFF3A3A44),
    rail: Color(0xFF34405A),
    urban: Color(0xFF0F171E),
    waterEdge: Color(0xFF2F6E9E),
    light: Color(0xFF9DB4FF),
    pitch: Color(0xFF1B3B2C),
    roofTile: Color(0xFF3A2A33),
    roofSlate: Color(0xFF1E2636),
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
    // Más allá de 18 crecen como el mundo real (x2 por nivel de zoom): si
    // no, al acercarse mucho las calles se quedarían finas entre edificios
    // cada vez más grandes.
    20,
    z18 * 4,
  ];

  // Un color que cambia con el zoom: de lejos, la calle "de plano" de
  // siempre; de cerca (16+), asfalto de verdad.
  List<Object?> byZoom(Color far, Color near) => <Object?>[
    'interpolate',
    <Object?>['linear'],
    <Object?>['zoom'],
    15,
    hex(far),
    16.5,
    hex(near),
  ];
  // Un filtro "la clase de la calle es una de estas".
  List<Object?> classIn(List<String> classes) => <Object?>[
    'in',
    <Object?>['get', 'class'],
    <Object?>['literal', classes],
  ];
  const List<String> minorClasses = <String>['minor', 'service'];
  const List<String> majorClasses = <String>[
    'motorway',
    'trunk',
    'primary',
    'secondary',
    'tertiary',
  ];
  const List<String> footClasses = <String>['pedestrian', 'path', 'track'];
  final List<Object?> isLine = <Object?>[
    'all',
    <Object?>[
      '==',
      <Object?>['geometry-type'],
      'LineString',
    ],
    // Lo que va por un túnel no se pinta como calle (ver 'road-tunnel').
    <Object?>[
      '!=',
      <Object?>['get', 'brunnel'],
      'tunnel',
    ],
  ];
  // Un tamaño que crece con el zoom (para iconos de decoración).
  List<Object?> zoomed(double z16, double z19) => <Object?>[
    'interpolate',
    <Object?>['exponential', 2],
    <Object?>['zoom'],
    16,
    z16,
    19,
    z19,
    20,
    z19 * 2,
  ];
  // Iconos "tumbados" en el suelo, girados con la calle y sin tapar a nadie.
  const Map<String, Object?> flatOnGround = <String, Object?>{
    'icon-rotation-alignment': 'map',
    'icon-pitch-alignment': 'map',
    'icon-allow-overlap': true,
    'icon-ignore-placement': true,
  };
  // Un número "al azar" pero fijo para cada edificio o calle (sale de su id
  // de OpenStreetMap): cada uno saca siempre la misma fachada, tejado o
  // coche (no parpadea), pero los vecinos varían.
  // to-number con 0 de reserva: algunos elementos no traen número.
  List<Object?> pickOf(int n) => <Object?>[
    '%',
    <Object?>[
      'to-number',
      <Object?>['id'],
      0,
    ],
    n,
  ];
  final List<Object?> pick3 = pickOf(3);
  // Altura de cada edificio (6 m si OpenStreetMap no la sabe) y de dónde
  // empieza (los soportales y pasarelas no tocan el suelo).
  final List<Object?> height = <Object?>[
    'coalesce',
    <Object?>['get', 'render_height'],
    6,
  ];
  final List<Object?> base = <Object?>[
    'coalesce',
    <Object?>['get', 'render_min_height'],
    0,
  ];
  final List<Object?> isArea = <Object?>[
    '==',
    <Object?>['geometry-type'],
    'Polygon',
  ];

  return <String, Object?>{
    'version': 8,
    'name': 'NomadIQ ${look.name}',
    // Lo lee la superficie del mapa para saber qué texturas añadir.
    'metadata': <String, Object?>{'nomadiq:look': look.name},
    'glyphs': glyphsUrl,
    // El "sol" que ilumina los edificios en 3D: una cara clara y otra en
    // sombra, como en las maquetas. Fijo respecto a la pantalla, así al
    // girar el mapa la luz no cambia de golpe.
    'light': <String, Object?>{
      'anchor': 'viewport',
      'color': hex(p.light),
      'intensity': look == MapLook.night ? 0.25 : 0.4,
      'position': <double>[1.3, 210, 35],
    },
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
      // Las manzanas de la ciudad, para que se distingan del campo.
      <String, Object?>{
        'id': 'landuse-urban',
        'type': 'fill',
        'source': 'openmaptiles',
        'source-layer': 'landuse',
        'filter': classIn(<String>[
          'residential',
          'commercial',
          'retail',
          'neighbourhood',
          'suburb',
          'quarter',
        ]),
        'paint': <String, Object?>{'fill-color': hex(p.urban)},
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
      // Árboles dibujados encima del verde (solo de cerca).
      <String, Object?>{
        'id': 'park-trees',
        'type': 'fill',
        'source': 'openmaptiles',
        'source-layer': 'park',
        'minzoom': 15,
        'paint': <String, Object?>{'fill-pattern': MapIds.treesPattern},
      },
      <String, Object?>{
        'id': 'wood-trees',
        'type': 'fill',
        'source': 'openmaptiles',
        'source-layer': 'landcover',
        'minzoom': 15,
        'filter': classIn(<String>['wood']),
        'paint': <String, Object?>{'fill-pattern': MapIds.treesPattern},
      },
      // Campos de fútbol, pistas y parques infantiles: césped con línea blanca.
      <String, Object?>{
        'id': 'sports',
        'type': 'fill',
        'source': 'openmaptiles',
        'source-layer': 'landuse',
        'minzoom': 14,
        'filter': classIn(<String>['pitch', 'stadium', 'playground']),
        'paint': <String, Object?>{'fill-color': hex(p.pitch)},
      },
      <String, Object?>{
        'id': 'sports-lines',
        'type': 'line',
        'source': 'openmaptiles',
        'source-layer': 'landuse',
        'minzoom': 16,
        'filter': classIn(<String>['pitch', 'stadium']),
        'paint': <String, Object?>{
          'line-color': '#ffffff',
          'line-opacity': 0.8,
          'line-width': 1.5,
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
        'id': 'water-edge',
        'type': 'line',
        'source': 'openmaptiles',
        'source-layer': 'water',
        'minzoom': 13,
        'paint': <String, Object?>{
          'line-color': hex(p.waterEdge),
          'line-width': width(0.5, 3),
          'line-blur': 1,
        },
      },
      <String, Object?>{
        'id': 'water-waves',
        'type': 'fill',
        'source': 'openmaptiles',
        'source-layer': 'water',
        'minzoom': 14,
        'paint': <String, Object?>{'fill-pattern': MapIds.wavesPattern},
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
      // Aeropuertos: plataformas en gris y pistas con su línea central.
      <String, Object?>{
        'id': 'aeroway-area',
        'type': 'fill',
        'source': 'openmaptiles',
        'source-layer': 'aeroway',
        'minzoom': 11,
        'filter': isArea,
        'paint': <String, Object?>{
          'fill-color': hex(p.curb),
          'fill-opacity': 0.6,
        },
      },
      <String, Object?>{
        'id': 'runway',
        'type': 'line',
        'source': 'openmaptiles',
        'source-layer': 'aeroway',
        'minzoom': 11,
        'filter': <Object?>[
          'all',
          <Object?>[
            '==',
            <Object?>['geometry-type'],
            'LineString',
          ],
          classIn(<String>['runway', 'taxiway']),
        ],
        'paint': <String, Object?>{
          'line-color': hex(p.asphalt),
          // Más ancha la pista que las calles de rodaje.
          'line-width': <Object?>[
            'interpolate',
            <Object?>['exponential', 1.6],
            <Object?>['zoom'],
            11,
            <Object?>[
              'match',
              <Object?>['get', 'class'],
              'runway',
              3,
              1,
            ],
            18,
            <Object?>[
              'match',
              <Object?>['get', 'class'],
              'runway',
              120,
              30,
            ],
          ],
        },
      },
      <String, Object?>{
        'id': 'runway-marks',
        'type': 'line',
        'source': 'openmaptiles',
        'source-layer': 'aeroway',
        'minzoom': 14,
        'filter': <Object?>[
          'all',
          <Object?>[
            '==',
            <Object?>['geometry-type'],
            'LineString',
          ],
          classIn(<String>['runway']),
        ],
        'paint': <String, Object?>{
          'line-color': '#ffffff',
          'line-width': width(0.3, 3),
          'line-dasharray': <double>[6, 4],
        },
      },
      // Túneles: la calle se intuye, discontinua y transparente.
      <String, Object?>{
        'id': 'road-tunnel',
        'type': 'line',
        'source': 'openmaptiles',
        'source-layer': 'transportation',
        'minzoom': 14,
        'filter': <Object?>[
          'all',
          <Object?>[
            '==',
            <Object?>['get', 'brunnel'],
            'tunnel',
          ],
          classIn(<String>[
            ...majorClasses,
            ...minorClasses,
            'rail',
            'transit',
          ]),
        ],
        'paint': <String, Object?>{
          'line-color': hex(p.asphalt),
          'line-opacity': 0.35,
          'line-width': width(0.5, 14),
          'line-dasharray': <double>[1, 1],
        },
      },
      // Sombra de los puentes sobre el suelo: parece que "flotan".
      <String, Object?>{
        'id': 'bridge-shadow',
        'type': 'line',
        'source': 'openmaptiles',
        'source-layer': 'transportation',
        'minzoom': 15,
        'filter': <Object?>[
          '==',
          <Object?>['get', 'brunnel'],
          'bridge',
        ],
        'paint': <String, Object?>{
          'line-color': '#000000',
          'line-opacity': 0.35,
          'line-width': width(1, 34),
          'line-blur': 6,
          'line-translate': <double>[5, 7],
        },
      },
      // Plazas y calles peatonales dibujadas como superficie: adoquín.
      <String, Object?>{
        'id': 'pedestrian-area',
        'type': 'fill',
        'source': 'openmaptiles',
        'source-layer': 'transportation',
        'minzoom': 14,
        'filter': <Object?>['all', isArea, classIn(footClasses)],
        'paint': <String, Object?>{'fill-pattern': MapIds.cobblePattern},
      },
      // Las calles se pintan en tres pasadas, de la más ancha a la más
      // estrecha, como capas de pintura: bordillo, acera y asfalto. Lo que
      // asoma de cada una por los lados es lo que se ve de la anterior.
      <String, Object?>{
        'id': 'road-minor-curb',
        'type': 'line',
        'source': 'openmaptiles',
        'source-layer': 'transportation',
        'minzoom': 15,
        'filter': <Object?>['all', isLine, classIn(minorClasses)],
        'layout': <String, Object?>{'line-cap': 'round', 'line-join': 'round'},
        'paint': <String, Object?>{
          'line-color': hex(p.curb),
          'line-width': width(0.8, 36),
        },
      },
      <String, Object?>{
        'id': 'road-minor-sidewalk',
        'type': 'line',
        'source': 'openmaptiles',
        'source-layer': 'transportation',
        'minzoom': 15,
        'filter': <Object?>['all', isLine, classIn(minorClasses)],
        'layout': <String, Object?>{'line-cap': 'round', 'line-join': 'round'},
        'paint': <String, Object?>{
          'line-color': hex(p.sidewalk),
          'line-width': width(0.7, 33),
        },
      },
      <String, Object?>{
        'id': 'road-major-curb',
        'type': 'line',
        'source': 'openmaptiles',
        'source-layer': 'transportation',
        'minzoom': 15,
        'filter': <Object?>['all', isLine, classIn(majorClasses)],
        'layout': <String, Object?>{'line-cap': 'round', 'line-join': 'round'},
        'paint': <String, Object?>{
          'line-color': hex(p.curb),
          'line-width': width(1.2, 52),
        },
      },
      <String, Object?>{
        'id': 'road-major-sidewalk',
        'type': 'line',
        'source': 'openmaptiles',
        'source-layer': 'transportation',
        'minzoom': 15,
        'filter': <Object?>['all', isLine, classIn(majorClasses)],
        'layout': <String, Object?>{'line-cap': 'round', 'line-join': 'round'},
        'paint': <String, Object?>{
          'line-color': hex(p.sidewalk),
          'line-width': width(1.2, 48),
        },
      },
      // Baldosas de la acera (de cerca): encima del color liso de la acera.
      for (final bool major in <bool>[false, true])
        <String, Object?>{
          'id': major ? 'road-major-paving' : 'road-minor-paving',
          'type': 'line',
          'source': 'openmaptiles',
          'source-layer': 'transportation',
          'minzoom': 17,
          'filter': <Object?>[
            'all',
            isLine,
            classIn(major ? majorClasses : minorClasses),
          ],
          'layout': <String, Object?>{
            'line-cap': 'round',
            'line-join': 'round',
          },
          'paint': <String, Object?>{
            'line-pattern': MapIds.pavingPattern,
            'line-width': major ? width(1.2, 48) : width(0.7, 33),
            'line-opacity': <Object?>[
              'interpolate',
              <Object?>['linear'],
              <Object?>['zoom'],
              17,
              0,
              17.6,
              1,
            ],
          },
        },
      <String, Object?>{
        'id': 'road-minor',
        'type': 'line',
        'source': 'openmaptiles',
        'source-layer': 'transportation',
        'minzoom': 13,
        'filter': <Object?>['all', isLine, classIn(minorClasses)],
        'layout': <String, Object?>{'line-cap': 'round', 'line-join': 'round'},
        'paint': <String, Object?>{
          'line-color': byZoom(p.minorRoad, p.asphalt),
          'line-width': width(0.5, 20),
        },
      },
      <String, Object?>{
        'id': 'road-major',
        'type': 'line',
        'source': 'openmaptiles',
        'source-layer': 'transportation',
        'filter': <Object?>['all', isLine, classIn(majorClasses)],
        'layout': <String, Object?>{'line-cap': 'round', 'line-join': 'round'},
        'paint': <String, Object?>{
          'line-color': byZoom(p.majorRoad, p.asphalt),
          'line-width': width(1.2, 34),
        },
      },
      // De cerca, la calzada "de verdad": asfalto con grano, cunetas, líneas
      // de borde, carriles y raya del centro (ver paintRoad). Va encima del
      // color liso de arriba, que es lo que se ve de lejos.
      for (final bool major in <bool>[false, true])
        <String, Object?>{
          'id': major ? 'road-major-texture' : 'road-minor-texture',
          'type': 'line',
          'source': 'openmaptiles',
          'source-layer': 'transportation',
          'minzoom': 16,
          'filter': <Object?>[
            'all',
            isLine,
            classIn(major ? majorClasses : minorClasses),
          ],
          'layout': <String, Object?>{'line-cap': 'butt', 'line-join': 'round'},
          'paint': <String, Object?>{
            'line-pattern': major
                ? MapIds.roadMajorPattern
                : MapIds.roadMinorPattern,
            'line-width': major ? width(1.2, 34) : width(0.5, 20),
            // Aparece poco a poco al acercarse (sin "salto").
            'line-opacity': <Object?>[
              'interpolate',
              <Object?>['linear'],
              <Object?>['zoom'],
              16,
              0,
              16.6,
              1,
            ],
          },
        },
      // Flechas de sentido único (muy de cerca).
      <String, Object?>{
        'id': 'oneway-arrows',
        'type': 'symbol',
        'source': 'openmaptiles',
        'source-layer': 'transportation',
        'minzoom': 17,
        'filter': <Object?>[
          'all',
          isLine,
          <Object?>[
            'in',
            <Object?>['get', 'oneway'],
            <Object?>[
              'literal',
              <int>[1, -1],
            ],
          ],
        ],
        'layout': <String, Object?>{
          'symbol-placement': 'line',
          'symbol-spacing': 90,
          'icon-image': MapIds.arrowIcon,
          'icon-size': 0.6,
          'icon-rotate': <Object?>[
            'match',
            <Object?>['get', 'oneway'],
            -1,
            180,
            0,
          ],
          'icon-rotation-alignment': 'map',
          'icon-allow-overlap': true,
        },
        'paint': <String, Object?>{'icon-opacity': 0.8},
      },
      // Calles peatonales y caminos: adoquín con un borde punteado.
      <String, Object?>{
        'id': 'footway',
        'type': 'line',
        'source': 'openmaptiles',
        'source-layer': 'transportation',
        'minzoom': 14,
        'filter': <Object?>['all', isLine, classIn(footClasses)],
        'layout': <String, Object?>{'line-cap': 'round', 'line-join': 'round'},
        'paint': <String, Object?>{
          'line-pattern': MapIds.cobblePattern,
          'line-width': width(0.5, 10),
        },
      },
      // Vías de tren y metro en superficie: una línea con "traviesas".
      <String, Object?>{
        'id': 'rail',
        'type': 'line',
        'source': 'openmaptiles',
        'source-layer': 'transportation',
        'minzoom': 13,
        'filter': <Object?>[
          'all',
          isLine,
          classIn(<String>['rail', 'transit']),
        ],
        'paint': <String, Object?>{
          'line-color': hex(p.rail),
          'line-width': width(0.6, 3),
        },
      },
      <String, Object?>{
        'id': 'rail-ties',
        'type': 'line',
        'source': 'openmaptiles',
        'source-layer': 'transportation',
        'minzoom': 15,
        'filter': <Object?>[
          'all',
          isLine,
          classIn(<String>['rail', 'transit']),
        ],
        'paint': <String, Object?>{
          'line-color': hex(p.rail),
          'line-width': width(2, 9),
          'line-dasharray': <double>[0.15, 1.2],
        },
      },
      // Tráfico: coches parados por el carril derecho de las avenidas. Es
      // decoración (no es tráfico en tiempo real), pero da vida a la calle.
      <String, Object?>{
        'id': 'traffic',
        'type': 'symbol',
        'source': 'openmaptiles',
        'source-layer': 'transportation',
        'minzoom': 16.5,
        'filter': <Object?>['all', isLine, classIn(majorClasses)],
        'layout': <String, Object?>{
          'symbol-placement': 'line',
          'symbol-spacing': 110,
          'icon-image': <Object?>[
            'match',
            pickOf(carColors.length),
            for (int i = 1; i < carColors.length; i++) ...<Object?>[
              i,
              MapIds.carIcon(i),
            ],
            MapIds.carIcon(0),
          ],
          'icon-size': zoomed(0.35, 1.2),
          'icon-offset': <double>[0, 9],
          ...flatOnGround,
        },
      },
      // Árboles a los dos lados de las calles (muy de cerca).
      for (final double side in <double>[-1, 1])
        <String, Object?>{
          'id': side < 0 ? 'street-trees-left' : 'street-trees-right',
          'type': 'symbol',
          'source': 'openmaptiles',
          'source-layer': 'transportation',
          'minzoom': 17.5,
          'filter': <Object?>['all', isLine, classIn(minorClasses)],
          'layout': <String, Object?>{
            'symbol-placement': 'line',
            'symbol-spacing': 45,
            'icon-image': MapIds.treeIcon,
            // Pequeños: una copa cabe en la acera, no tapa la calle.
            'icon-size': zoomed(0.2, 0.75),
            // En medio de la acera (el desplazamiento crece con el icono).
            'icon-offset': <double>[0, side * 36],
            ...flatOnGround,
          },
        },
      // Farolas encendidas al atardecer y de noche.
      if (look != MapLook.day)
        <String, Object?>{
          'id': 'street-lamps',
          'type': 'symbol',
          'source': 'openmaptiles',
          'source-layer': 'transportation',
          'minzoom': 16,
          'filter': <Object?>[
            'all',
            isLine,
            classIn(<String>[...majorClasses, ...minorClasses]),
          ],
          'layout': <String, Object?>{
            'symbol-placement': 'line',
            'symbol-spacing': 70,
            'icon-image': MapIds.lampIcon,
            'icon-size': zoomed(0.6, 2),
            'icon-offset': <double>[0, -14],
            ...flatOnGround,
          },
          'paint': <String, Object?>{
            'icon-opacity': look == MapLook.night ? 0.95 : 0.6,
          },
        },
      // Sombra de los edificios en el suelo (hacia abajo a la derecha, como
      // la luz del estilo): les da peso y profundidad.
      <String, Object?>{
        'id': 'building-shadow',
        'type': 'fill',
        'source': 'openmaptiles',
        'source-layer': 'building',
        'minzoom': 15,
        'paint': <String, Object?>{
          'fill-color': '#000000',
          'fill-opacity': look == MapLook.night ? 0.35 : 0.18,
          'fill-translate': <Object?>[
            'interpolate',
            <Object?>['linear'],
            <Object?>['zoom'],
            15,
            <Object?>[
              'literal',
              <double>[2, 3],
            ],
            19,
            <Object?>[
              'literal',
              <double>[14, 20],
            ],
          ],
        },
      },
      // Las "huellas" de los edificios en 2D (se ven antes que el 3D).
      <String, Object?>{
        'id': 'building-flat',
        'type': 'fill',
        'source': 'openmaptiles',
        'source-layer': 'building',
        'minzoom': 13,
        'maxzoom': 14.5,
        'paint': <String, Object?>{
          'fill-color': hex(p.building),
          'fill-opacity': 0.7,
        },
      },
      // Los edificios en 3D: la altura sale de OpenStreetMap (render_height).
      // Se ven "de pie" al inclinar el mapa con el botón 3D. De lejos son
      // bloques de color; de cerca (16+) llevan fachada con ventanas.
      <String, Object?>{
        'id': 'building-3d',
        'type': 'fill-extrusion',
        'source': 'openmaptiles',
        'source-layer': 'building',
        'minzoom': 14,
        'maxzoom': 16,
        'paint': <String, Object?>{
          'fill-extrusion-color': <Object?>[
            'interpolate',
            <Object?>['linear'],
            height,
            0,
            hex(p.building),
            60,
            hex(p.buildingTop),
          ],
          'fill-extrusion-height': height,
          'fill-extrusion-base': base,
          'fill-extrusion-opacity': 1,
          // Más oscuro abajo y más claro arriba: los edificios "pesan".
          'fill-extrusion-vertical-gradient': true,
        },
      },
      <String, Object?>{
        'id': 'building-facade',
        'type': 'fill-extrusion',
        'source': 'openmaptiles',
        'source-layer': 'building',
        'minzoom': 16,
        'paint': <String, Object?>{
          // Los altos (más de 40 m) son de cristal; el resto, ladrillo,
          // cristal o piedra según el edificio.
          'fill-extrusion-pattern': <Object?>[
            'case',
            <Object?>['>', height, 40],
            MapIds.facade(Facade.glass),
            <Object?>[
              'match',
              pick3,
              0,
              MapIds.facade(Facade.brick),
              1,
              MapIds.facade(Facade.glass),
              MapIds.facade(Facade.stone),
            ],
          ],
          'fill-extrusion-height': height,
          'fill-extrusion-base': base,
          'fill-extrusion-opacity': 1,
        },
      },
      // La textura también caería en el tejado (ventanas en el techo). Una
      // "tapa" fina de color encima lo evita: es un truco barato.
      <String, Object?>{
        'id': 'building-roof',
        'type': 'fill-extrusion',
        'source': 'openmaptiles',
        'source-layer': 'building',
        'minzoom': 16,
        'paint': <String, Object?>{
          // Tejados de teja, de zinc gris o de pizarra.
          'fill-extrusion-color': <Object?>[
            'match',
            pick3,
            0,
            hex(p.roofTile),
            1,
            hex(p.buildingTop),
            hex(p.roofSlate),
          ],
          'fill-extrusion-height': <Object?>['+', height, 0.2],
          'fill-extrusion-base': height,
          'fill-extrusion-opacity': 1,
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
      // Números de portal (solo muy de cerca).
      <String, Object?>{
        'id': 'housenumbers',
        'type': 'symbol',
        'source': 'openmaptiles',
        'source-layer': 'housenumber',
        'minzoom': 18,
        'layout': <String, Object?>{
          'text-field': <Object?>['get', 'housenumber'],
          'text-font': regular,
          'text-size': 10,
        },
        'paint': <String, Object?>{
          'text-color': hex(p.label),
          'text-halo-color': hex(p.labelHalo),
          'text-halo-width': 1,
          'text-opacity': 0.8,
        },
      },
      // Sitios con icono: restaurantes, cafés, museos, metro, hoteles...
      <String, Object?>{
        'id': 'poi',
        'type': 'symbol',
        'source': 'openmaptiles',
        'source-layer': 'poi',
        'minzoom': 15,
        // Los más importantes primero; de cerca salen todos.
        'filter': <Object?>[
          '<=',
          <Object?>['get', 'rank'],
          <Object?>[
            'step',
            <Object?>['zoom'],
            8,
            16,
            20,
            17,
            60,
          ],
        ],
        'layout': <String, Object?>{
          'icon-image': _poiIcon(),
          'icon-size': 0.5,
          'text-field': name,
          'text-font': regular,
          'text-size': 11,
          'text-max-width': 8,
          'text-offset': <double>[0, 1.3],
          'text-anchor': 'top',
          'text-optional': true,
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

/// Qué icono lleva cada sitio, según su clase en OpenMapTiles. Los que no
/// encajan en ningún tipo salen solo con el nombre.
List<Object?> _poiIcon() {
  const Map<PoiKind, List<String>> classes = <PoiKind, List<String>>{
    PoiKind.food: <String>['restaurant', 'fast_food', 'food_court'],
    PoiKind.cafe: <String>['cafe', 'ice_cream', 'bakery'],
    PoiKind.bar: <String>['bar', 'pub', 'beer', 'nightclub'],
    PoiKind.culture: <String>[
      'museum',
      'art_gallery',
      'attraction',
      'monument',
      'castle',
      'theatre',
      'cinema',
      'place_of_worship',
    ],
    PoiKind.shop: <String>[
      'shop',
      'grocery',
      'clothing_store',
      'shoe_shop',
      'jewelry',
      'books',
      'gift',
      'mall',
    ],
    PoiKind.lodging: <String>['lodging', 'campsite'],
    PoiKind.transport: <String>[
      'railway',
      'bus',
      'ferry_terminal',
      'aerialway',
    ],
    PoiKind.health: <String>['hospital', 'pharmacy', 'doctors', 'dentist'],
  };
  return <Object?>[
    'match',
    <Object?>['get', 'class'],
    for (final MapEntry<PoiKind, List<String>> e
        in classes.entries) ...<Object?>[e.value, MapIds.poiIcon(e.key)],
    '',
  ];
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
