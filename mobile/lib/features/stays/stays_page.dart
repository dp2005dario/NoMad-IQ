// Lo que la app le da a la página de "Hoteles" (la maqueta, en
// assets/stays/hoteles.html): los textos en tu idioma, los sitios para
// elegir (tu destino, cerca de ti, seis monumentos famosos y "en el mapa") y
// las ZONAS reales para dormir alrededor del sitio elegido, con los precios
// que tú apuntas. Dart puro: se prueba sin WebView.
import 'dart:convert';
import 'dart:math' as math;

import '../../l10n/generated/app_localizations.dart';
import '../map/geo.dart';
import 'stays_api.dart';

/// Dónde está la página y la marca donde la app mete sus datos.
const String staysPage = 'assets/stays/hoteles.html';
const String staysMarker =
    '/*ECLIPTA*/{"lang":"es","t":{},"chips":[],"cur":0,"zones":[],'
    '"nights":3,"msg":"","retry":false,"attr":""}';

/// Qué es cada chip.
enum StayChipKind { target, here, landmark, map }

/// Un sitio de la fila de chips.
class StayChip {
  const StayChip({
    required this.kind,
    required this.ill,
    required this.name,
    required this.short,
    this.city = '',
    this.height = '',
    this.year = '',
    this.point,
  });

  final StayChipKind kind;

  /// El dibujo de la tarjeta ("eiffel"... o "generic").
  final String ill;
  final String name;
  final String short;
  final String city;

  /// Datos de verdad del monumento (altura y año).
  final String height;
  final String year;

  /// Dónde está (null en "cerca de ti" y "en el mapa": lo da el GPS o tú).
  final GeoPoint? point;

  Map<String, Object?> toJson() => <String, Object?>{
    'kind': kind.name,
    'ill': ill,
    'name': name,
    'short': short,
    'city': city,
    'h': height,
    'yr': year,
  };
}

/// Los seis monumentos de la maqueta, con su sitio y sus datos reales.
List<StayChip> landmarkChips(AppLocalizations t) => <StayChip>[
  StayChip(
    kind: StayChipKind.landmark,
    ill: 'eiffel',
    name: t.hoEiffel,
    short: t.hoEiffelS,
    city: t.hoParis,
    height: '330 m',
    year: '1889',
    point: const GeoPoint(48.8584, 2.2945),
  ),
  StayChip(
    kind: StayChipKind.landmark,
    ill: 'sagrada',
    name: t.hoSagrada,
    short: t.hoSagradaS,
    city: t.hoBarcelona,
    height: '172 m',
    year: t.hoSince('1882'),
    point: const GeoPoint(41.4036, 2.1744),
  ),
  StayChip(
    kind: StayChipKind.landmark,
    ill: 'coliseo',
    name: t.hoColiseo,
    short: t.hoColiseo,
    city: t.hoRome,
    height: '48 m',
    year: t.hoAD('80'),
    point: const GeoPoint(41.8902, 12.4922),
  ),
  StayChip(
    kind: StayChipKind.landmark,
    ill: 'bigben',
    name: t.hoBigBen,
    short: t.hoBigBen,
    city: t.hoLondon,
    height: '96 m',
    year: '1859',
    point: const GeoPoint(51.5007, -0.1246),
  ),
  StayChip(
    kind: StayChipKind.landmark,
    ill: 'brandeburgo',
    name: t.hoBrandenburg,
    short: t.hoBrandenburgS,
    city: t.hoBerlin,
    height: '26 m',
    year: '1791',
    point: const GeoPoint(52.5163, 13.3777),
  ),
  StayChip(
    kind: StayChipKind.landmark,
    ill: 'disney',
    name: t.hoDisney,
    short: t.hoDisneyS,
    city: t.hoMarne,
    height: '43 m',
    year: '1992',
    point: const GeoPoint(48.8722, 2.7758),
  ),
];

/// Lo que apuntas de una zona (lo que viste en Booking).
class StayPrices {
  double? night;
  double? fare;
}

/// Los textos de la página (las claves que usa la página).
Map<String, String> staysTexts(AppLocalizations t) {
  // Estos textos piden un número: se pone uno que no sale nunca y se cambia
  // por la marca que entiende la página.
  const int a = 7919, b = 7907;
  return <String, String>{
    'title': t.hoTitle,
    'legend': t.hoLegend,
    'cheap': t.hoCheap,
    'mid': t.hoMid,
    'dear': t.hoDear,
    'credit': t.nbCredit,
    'zoomIn': t.exwZoomIn,
    'zoomOut': t.exwZoomOut,
    'tilt': t.nbTilt,
    'center': t.hoCenter,
    'best': t.hoBest,
    'pinCount': t.hoPinCount('{n}'),
    'loading': t.hoLoading,
    'chosen': t.hoChosen,
    'tapZone': t.hoTapZone,
    'none': t.staysNone,
    'retry': t.guideRetry,
    'perNight': t.hoPerNight,
    'noData': t.exwNoData,
    'nightsTrain': t.hoNightsTrain('{n}'),
    'close': t.exwClose,
    'lodgings': t
        .staysLodgings(a, b)
        .replaceFirst('$a', '{n}')
        .replaceFirst('$b', '{budget}'),
    'away': t.hoAway('{km}', '{place}'),
    'nightCap': t.hoNightCap,
    'enter': t.hoEnter,
    'toMon': t.hoToMon,
    'minutes': t.hoMinutes('{n}'),
    'round': t.hoRound,
    'byWalk': t.hoByWalk('{place}'),
    'byTrain': t.hoByTrain('{name}'),
    'examples': t.hoExamples('{list}'),
    'stay': t.hoStay,
    'less': t.hoLessNights,
    'more': t.hoMoreNights,
    'nightsN': t.hoNightsN('{n}'),
    'transport': t.hoTransport,
    'daysN': t.hoDaysN('{n}'),
    'total': t.hoTotal,
    'book': t.staysSeePrices,
    'route': t.hoRoute,
    'hint': t.hoEnterHint,
    'nearest': t.hoNearest,
    'save': t.hoSave('{money}', '{n}', '{place}'),
    'nearSite': t.staysNearSite,
    'nearTitle': t.hoNearTitle,
    'k_hotel': t.hoKindHotel,
    'k_hostel': t.hoKindHostel,
    'k_guest_house': t.hoKindGuest,
    'k_motel': t.hoKindMotel,
    'k_apartment': t.hoKindApartment,
    'openMaps': t.hoOpenMaps,
    'hotelPrices': t.hoHotelPrices,
  };
}

/// Metros al este y al sur de [p] visto desde [from] (como el mapa).
(double, double) metersFrom(GeoPoint from, GeoPoint p) => (
  (p.lon - from.lon) * 111320 * math.cos(from.lat * math.pi / 180),
  -(p.lat - from.lat) * 110540,
);

/// Metros en línea recta de [a] a [b] (para "a 350 m").
double distanceMeters(GeoPoint a, GeoPoint b) {
  final (double x, double y) = metersFrom(a, b);
  return math.sqrt(x * x + y * y);
}

/// Los alojamientos ordenados por lo cerca que están de TI (el servidor
/// los ordena desde el centro de su casilla, que puede estar a 1 km).
List<NearHotel> nearestHotels(
  GeoPoint center,
  List<NearHotel> hotels, {
  int limit = 15,
}) {
  final List<NearHotel> list = List<NearHotel>.of(hotels)
    ..sort(
      (NearHotel a, NearHotel b) => distanceMeters(
        center,
        a.point,
      ).compareTo(distanceMeters(center, b.point)),
    );
  return list.take(limit).toList();
}

/// Todo lo que necesita la página.
Map<String, Object?> staysPageData({
  required AppLocalizations t,
  required String language,
  required List<StayChip> chips,
  required int current,
  required int nights,
  GeoPoint? center,
  StayArea? area,
  Map<String, StayPrices> prices = const <String, StayPrices>{},
  Map<String, String> photos = const <String, String>{},
  String? message,
  bool retry = false,
}) => <String, Object?>{
  'lang': language,
  't': staysTexts(t),
  'chips': <Object?>[for (final StayChip c in chips) c.toJson()],
  'cur': current,
  'zones': <Object?>[
    if (center != null && area != null)
      for (final StayZone z in area.zones)
        () {
          final (double x, double y) = metersFrom(center, z.point);
          final StayPrices? p = prices[z.id];
          return <String, Object?>{
            'name': z.name,
            'x': x.round(),
            'y': y.round(),
            'km': z.km,
            'min': z.minutes,
            'by': z.by.name,
            'n': z.lodgings,
            'budget': z.budget,
            'ex': z.examples,
            'night': p?.night,
            'fare': p?.fare,
          };
        }(),
  ],
  // Los alojamientos más cerca, como en Google Maps: nombre, tipo,
  // estrellas, metros hasta el sitio y su foto (si ya llegó).
  'hotels': <Object?>[
    if (center != null && area != null && message == null)
      for (final NearHotel h in nearestHotels(center, area.hotels))
        <String, Object?>{
          'id': h.id,
          'name': h.name,
          'kind': h.kind,
          'stars': h.stars,
          'm': (distanceMeters(center, h.point) / 10).round() * 10,
          'img': photos[h.id] ?? '',
        },
  ],
  'nights': nights,
  'msg': message ?? '',
  'retry': retry,
  'attr': area?.attribution ?? '',
};

/// La página lista para enseñar.
String staysPageWith(String page, Map<String, Object?> data) {
  // "<" como \u003c: ningún nombre de OpenStreetMap puede cerrar el script.
  final String json = jsonEncode(data).replaceAll('<', r'\u003c');
  return page.replaceFirst(staysMarker, json);
}
