// La huella de carbono de un vuelo, calculada en el móvil.
//
// No hay ninguna API gratuita y fiable que diga lo que contamina TU vuelo
// exacto, así que se hace una estimación con factores públicos por
// kilómetro y pasajero (los que publica el Gobierno británico, DEFRA, y usa
// casi todo el mundo). Es una estimación honesta, no una medida: la app lo
// dice así en la pantalla.
import '../route/geo.dart';

/// Gramos de CO₂ equivalente por pasajero y kilómetro, según la distancia.
/// Un vuelo corto contamina más por kilómetro: despegar es lo que más gasta.
double gramsPerKm(double km) => switch (km) {
  < 1500 => 156, // corto radio
  < 3700 => 130, // medio radio
  _ => 110, // largo radio
};

/// Lo que contamina volar de más por ir por el aire (estelas y óxidos de
/// nitrógeno a 10 km de altura). El factor que usa DEFRA es 1,9.
const double radiativeForcing = 1.9;

/// Cada escala añade un despegue y un rodeo: ~15 % más por tramo.
const double stopoverExtra = 0.15;

/// Kilos de CO₂e por pasajero de un vuelo entre dos puntos.
/// [stops] son las escalas (0 = directo) y [roundTrip] duplica el viaje.
double flightKgCo2(
  LatLon from,
  LatLon to, {
  int stops = 0,
  bool roundTrip = true,
}) {
  final double km = distanceKm(from, to);
  if (km <= 0) return 0;
  final double legs = roundTrip ? 2 : 1;
  final double extra = 1 + stopoverExtra * stops.clamp(0, 4);
  return km * gramsPerKm(km) / 1000 * radiativeForcing * extra * legs;
}

/// Lo que emite un coche de gasolina normal en un año en España (12.000 km
/// a 170 g/km): sirve para comparar y entender el número.
const double carYearKgCo2 = 12000 * 0.170;

/// Cuántos árboles tendrían que crecer un año para absorberlo (~22 kg al
/// año cada uno). Es una comparación, no una compensación.
int treesForAYear(double kg) => (kg / 22).round();
