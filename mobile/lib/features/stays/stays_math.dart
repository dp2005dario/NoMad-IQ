// Las cuentas de "Dormir barato" (sin pantalla: fáciles de probar).
//
// El "total real" de dormir en una zona = noches × precio por noche + los
// billetes de tren para ir y volver al sitio cada día. Los precios los pone
// la persona (los ve en Booking con el botón "Ver precios"): la app no se
// inventa ninguno.
import '../map/geo.dart';

/// Lo que cuesta dormir en una zona, con los precios que la persona ha visto.
class StayCost {
  const StayCost({
    required this.nights,
    required this.people,
    required this.nightPrice,
    required this.fare,
  });

  final int nights;
  final int people;

  /// Precio por noche de la habitación (para todos).
  final double nightPrice;

  /// Billete de tren por persona y trayecto (0 si se va andando).
  final double fare;

  /// Días que vas al sitio: uno por noche (y el de salida).
  int get days => nights + 1;

  /// Ida y vuelta cada día, para cada persona.
  int get trips => days * 2 * people;
  double get hotel => nights * nightPrice;
  double get transport => trips * fare;
  double get total => hotel + transport;
}

/// "Ver precios": Booking.com en esa zona, con tus fechas y personas,
/// ordenado de más barato a más caro. [affiliateId] (opcional) es el código
/// de afiliado de ECLIPTA: si lo hay, Booking nos paga una comisión cuando
/// alguien reserva, sin que a ti te cueste más.
Uri bookingSearch({
  required GeoPoint at,
  required DateTime checkIn,
  required DateTime checkOut,
  required int adults,
  required String language,
  String? affiliateId,
}) {
  String day(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
  return Uri.https('www.booking.com', '/searchresults.html', <String, String>{
    'latitude': at.lat.toStringAsFixed(5),
    'longitude': at.lon.toStringAsFixed(5),
    'dest_type': 'latlong',
    'checkin': day(checkIn),
    'checkout': day(checkOut),
    'group_adults': '$adults',
    'no_rooms': '1',
    'order': 'price',
    'lang': language,
    if (affiliateId != null && affiliateId.isNotEmpty) 'aid': affiliateId,
  });
}

/// Alternativa sin afiliado: "hoteles" en Google Maps alrededor del punto
/// (Google también enseña precios).
Uri mapsHotels(GeoPoint at) => Uri.https(
  'www.google.com',
  '/maps/search/hotels/@${at.lat.toStringAsFixed(5)},${at.lon.toStringAsFixed(5)},15z',
);
