// Zonas de ejemplo para los tests, con la forma del GeoJSON del geo-engine.
import 'package:nomadiq/features/map/geo.dart';

/// Un cuadrado de lado 2×[half] grados alrededor de (lat, lon), con un
/// agujero opcional en el centro.
Map<String, Object?> square(
  String id,
  String name,
  String kind,
  double lat,
  double lon,
  double half, {
  double? hole,
}) {
  List<List<double>> ring(double h) => <List<double>>[
    <double>[lon - h, lat - h],
    <double>[lon + h, lat - h],
    <double>[lon + h, lat + h],
    <double>[lon - h, lat + h],
    <double>[lon - h, lat - h],
  ];
  return <String, Object?>{
    'type': 'Feature',
    'id': id,
    'geometry': <String, Object?>{
      'type': 'MultiPolygon',
      'coordinates': <Object?>[
        <Object?>[ring(half), if (hole != null) ring(hole)],
      ],
    },
    'properties': <String, Object?>{
      'slug': name.toLowerCase().replaceAll(' ', '-'),
      'name': name,
      'kind': kind,
    },
  };
}

const GeoPoint solCenter = GeoPoint(40.41694, -3.70361);
const GeoPoint airportCenter = GeoPoint(40.4936, -3.5668);

const String solId = '6f1c2a10-0000-4000-8000-000000000001';

final Map<String, Object?> solFeature = square(
  solId,
  'Puerta del Sol',
  'tourist_area',
  solCenter.lat,
  solCenter.lon,
  0.001,
);
final Map<String, Object?> madridFeature = square(
  '6f1c2a10-0000-4000-8000-000000000002',
  'Centro de Madrid',
  'city_center',
  solCenter.lat,
  solCenter.lon,
  0.02,
);
final Map<String, Object?> airportFeature = square(
  '6f1c2a10-0000-4000-8000-000000000003',
  'Aeropuerto de Barajas',
  'airport',
  airportCenter.lat,
  airportCenter.lon,
  0.02,
);

Zone solZone() => Zone.fromFeature(solFeature)!;
Zone madridZone() => Zone.fromFeature(madridFeature)!;
Zone airportZone() => Zone.fromFeature(airportFeature)!;

Map<String, Object?> zonesCollection({bool truncated = false}) =>
    <String, Object?>{
      'type': 'FeatureCollection',
      'features': <Object?>[madridFeature, solFeature, airportFeature],
      'truncated': truncated,
      'dataset_version': 1,
    };
