// Escala de regalo (maqueta "Escala"): dos viajes por el precio de uno.
//
// Varias aerolíneas dejan PARAR unos días en su ciudad (Estambul, Doha,
// Reikiavik, Lisboa...) cuando vuelas con ellas a otro sitio, sin subir el
// precio del billete o con hoteles regalados o rebajados. Son programas
// públicos de cada aerolínea, así que la lista va dentro de la app: no hace
// falta servidor ni pagar ningún servicio.
//
// Aquí está la lista y la cuenta de qué escalas "pillan de camino" entre tu
// origen y tu destino (sin dar una vuelta enorme).
import '../route/geo.dart';
import '../route/world_data.dart';

/// Zonas del mundo, para saber a dónde vuela cada aerolínea (Icelandair, por
/// ejemplo, solo une Europa y Norteamérica: no sirve para ir a Tokio).
enum WorldRegion {
  europe,
  northAmerica,
  southAmerica,
  africa,
  middleEast,
  asia,
  oceania,
}

/// La zona de un punto, con cajas de latitud y longitud (aproximadas, pero
/// de sobra para esto).
WorldRegion regionOf(LatLon p) {
  final double lat = p.lat;
  final double lon = p.lon;
  if (lon < -30) {
    return lat > 12 ? WorldRegion.northAmerica : WorldRegion.southAmerica;
  }
  if (lat < -10 && lon >= 110) return WorldRegion.oceania;
  if (lat >= 12 && lat <= 42 && lon >= 34 && lon < 63) {
    return WorldRegion.middleEast;
  }
  if (lon < 45) return lat > 35 ? WorldRegion.europe : WorldRegion.africa;
  if (lat > 35 && lon < 60) return WorldRegion.europe;
  return WorldRegion.asia;
}

/// Qué te da la aerolínea si paras en su ciudad.
enum StopoverRule {
  /// El billete cuesta lo mismo; el hotel lo pagas tú.
  sameFare,

  /// Puede regalarte el hotel (1-2 noches, según tarifa y horas de escala).
  freeHotel,

  /// La aerolínea vende hoteles y visitas a precio especial para la parada.
  hotelDeal,

  /// Se puede parar, pero el precio depende de la tarifa (su web lo dice).
  checkFare,
}

class StopoverProgram {
  const StopoverProgram({
    required this.hub,
    required this.airline,
    required this.airlineName,
    required this.url,
    this.maxNights,
    required this.rule,
    this.regions,
  });

  /// Las zonas a las que vuela desde su ciudad; null = a todo el mundo.
  final Set<WorldRegion>? regions;

  /// El aeropuerto donde paras ("IST").
  final String hub;

  /// Código de la aerolínea ("TK"): sirve para encontrar sus vuelos.
  final String airline;

  /// El nombre de la aerolínea (es una marca: no se traduce).
  final String airlineName;

  /// La página oficial del programa (allí se reserva el vuelo con parada).
  final String url;

  /// Cuántas noches deja como mucho (null = su web no lo dice).
  final int? maxNights;
  final StopoverRule rule;
}

/// Los programas de escala más conocidos. Las condiciones cambian, así que la
/// app siempre dice "compruébalo en la página de la aerolínea".
///
/// Cada enlace, noches y regla se comprobó en la web oficial el 25-10-2026.
/// Finnair y Singapore Airlines se quitaron: no encontramos su programa
/// en sus webs oficiales (nada que no se pueda comprobar).
const List<StopoverProgram> stopoverPrograms = <StopoverProgram>[
  StopoverProgram(
    hub: 'IST',
    airline: 'TK',
    airlineName: 'Turkish Airlines',
    url: 'https://www.turkishairlines.com/en-int/flights/stopover/',
    maxNights: 7,
    rule: StopoverRule.freeHotel,
  ),
  StopoverProgram(
    hub: 'DOH',
    airline: 'QR',
    airlineName: 'Qatar Airways',
    url: 'https://discoverqatar.qa/stopover',
    maxNights: 4,
    rule: StopoverRule.hotelDeal,
  ),
  StopoverProgram(
    hub: 'KEF',
    airline: 'FI',
    airlineName: 'Icelandair',
    url: 'https://www.icelandair.com/flights/stopover/',
    maxNights: 7,
    rule: StopoverRule.sameFare,
    regions: <WorldRegion>{WorldRegion.europe, WorldRegion.northAmerica},
  ),
  StopoverProgram(
    hub: 'LIS',
    airline: 'TP',
    airlineName: 'TAP Air Portugal',
    url: 'https://www.flytap.com/en-us/stopover',
    maxNights: 10,
    rule: StopoverRule.sameFare,
    regions: <WorldRegion>{
      WorldRegion.europe,
      WorldRegion.northAmerica,
      WorldRegion.southAmerica,
      WorldRegion.africa,
    },
  ),
  StopoverProgram(
    hub: 'DXB',
    airline: 'EK',
    airlineName: 'Emirates',
    url: 'https://www.emirates.com/us/english/discover-dubai/dubai-stopover',
    rule: StopoverRule.hotelDeal,
  ),
  StopoverProgram(
    hub: 'AUH',
    airline: 'EY',
    airlineName: 'Etihad Airways',
    url: 'https://www.etihad.com/en/abu-dhabi/stopover',
    rule: StopoverRule.freeHotel,
  ),
  StopoverProgram(
    hub: 'PTY',
    airline: 'CM',
    airlineName: 'Copa Airlines',
    url: 'https://shopping.copaair.com/booking-panel?roundtrip=false&advanced_air_search=true&stopover=true&origin=stopoverinpanama',
    maxNights: 7,
    rule: StopoverRule.sameFare,
    regions: <WorldRegion>{WorldRegion.northAmerica, WorldRegion.southAmerica},
  ),
  StopoverProgram(
    hub: 'HKG',
    airline: 'CX',
    airlineName: 'Cathay Pacific',
    url: 'https://flights.cathaypacific.com/en_HK/offers/stopover-in-hong-kong.html',
    maxNights: 7,
    rule: StopoverRule.checkFare,
  ),
];

/// Una escala posible para tu viaje.
class StopoverOption {
  const StopoverOption({
    required this.program,
    required this.hub,
    required this.extraKm,
  });

  final StopoverProgram program;
  final Airport hub;

  /// Cuántos km más vuelas por pasar por ahí (casi siempre pocos).
  final int extraKm;
}

/// Las escalas que pillan de camino entre [from] y [to]:
///   - la aerolínea vuela a las dos zonas (salida y llegada),
///   - cada tramo es más corto que el viaje entero (no se va "hacia atrás"),
///   - y como mucho un 30 % más de distancia que el vuelo directo.
/// Las mejores (menos rodeo) primero.
List<StopoverOption> stopoversFor(
  Airport from,
  Airport to,
  Airports airports, {
  double maxDetour = 1.3,
}) {
  final double direct = distanceKm(from.position, to.position);
  if (direct < 300) return const <StopoverOption>[];
  final List<StopoverOption> out = <StopoverOption>[];
  for (final StopoverProgram p in stopoverPrograms) {
    final Airport? hub = airports[p.hub];
    if (hub == null || hub.iata == from.iata || hub.iata == to.iata) continue;
    final Set<WorldRegion>? regions = p.regions;
    if (regions != null &&
        (!regions.contains(regionOf(from.position)) ||
            !regions.contains(regionOf(to.position)))) {
      continue;
    }
    final double first = distanceKm(from.position, hub.position);
    final double second = distanceKm(hub.position, to.position);
    if (first >= direct || second >= direct) continue;
    if (first + second > direct * maxDetour) continue;
    final double via = first + second;
    out.add(
      StopoverOption(program: p, hub: hub, extraKm: (via - direct).round()),
    );
  }
  out.sort((StopoverOption a, StopoverOption b) => a.extraKm - b.extraKm);
  return out;
}

/// Noches que se pueden elegir (0 = solo cambiar de avión), como en la
/// maqueta: hasta 3, o menos si la aerolínea no deja más (si su web no dice
/// el máximo, hasta 3 y la app pide comprobarlo allí).
List<int> nightChoices(StopoverProgram p) {
  final int max = p.maxNights ?? 3;
  return <int>[for (int n = 0; n <= (max < 3 ? max : 3); n++) n];
}
