// "¿No ves tu vuelo? Míralo también en…": la misma búsqueda (origen,
// destino, fechas y pasajeros) ya puesta en otros buscadores grandes.
//
// Por qué: los precios de la app salen de la Data API de Travelpayouts, que
// solo tiene los vuelos que otros viajeros han buscado hace poco. Para una
// fecha poco buscada (p. ej. Varsovia el 26 de diciembre) puede no haber
// nada aunque el vuelo exista. Estos enlaces abren la búsqueda en vivo en
// cada web, sin claves ni cuentas.
import 'fares_api.dart';

/// Un buscador y el enlace con tu búsqueda ya puesta.
typedef OtherSearch = ({String name, Uri url});

String _iso(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

String _yymmdd(DateTime d) =>
    '${(d.year % 100).toString().padLeft(2, '0')}'
    '${d.month.toString().padLeft(2, '0')}'
    '${d.day.toString().padLeft(2, '0')}';

/// Los enlaces para [route] con [adults] adultos (1 a 9).
List<OtherSearch> otherSearches(FareRoute route, int adults) {
  final String o = route.origin.toUpperCase();
  final String d = route.destination.toUpperCase();
  final DateTime dep = route.departure;
  final DateTime? ret = route.returnDate;
  final int ad = adults.clamp(1, 9);
  final String google =
      'Flights from $o to $d on ${_iso(dep)}'
      '${ret == null ? ' one way' : ' returning ${_iso(ret)}'}'
      '${ad > 1 ? ' for $ad adults' : ''}';
  return <OtherSearch>[
    (
      name: 'Google Flights',
      url: Uri.https('www.google.com', '/travel/flights', <String, String>{
        'q': google,
      }),
    ),
    (
      name: 'Skyscanner',
      url: Uri.https(
        'www.skyscanner.net',
        '/transport/flights/${o.toLowerCase()}/${d.toLowerCase()}/'
            '${_yymmdd(dep)}/${ret == null ? '' : '${_yymmdd(ret)}/'}',
        <String, String>{'adultsv2': '$ad'},
      ),
    ),
    (
      name: 'Kayak',
      url: Uri.https(
        'www.kayak.com',
        '/flights/$o-$d/${_iso(dep)}'
            '${ret == null ? '' : '/${_iso(ret)}'}/${ad}adults',
      ),
    ),
    (
      name: 'Trip.com',
      url: Uri.https('www.trip.com', '/flights/showfarefirst', <String, String>{
        'dcity': o.toLowerCase(),
        'acity': d.toLowerCase(),
        'ddate': _iso(dep),
        if (ret != null) 'rdate': _iso(ret),
        'triptype': ret == null ? 'ow' : 'rt',
        'class': 'y',
        'quantity': '$ad',
      }),
    ),
  ];
}
