// Moverte: los bonos de transporte de las ciudades más visitadas.
//
// REGLA: aquí NO hay precios. No existe ninguna fuente gratis y comprobada
// con los precios de los bonos de cada ciudad, y un precio escrito a mano se
// queda viejo (o está mal) y engaña al viajero. Por eso la tabla solo dice
// QUÉ bonos existen y su web OFICIAL; el precio lo mira la persona allí y,
// si quiere, lo apunta en la calculadora de la app ([passPaysOff]).
// Todos los enlaces se abrieron y comprobaron el 25-10-2026.
//
// ¿Por qué una tabla dentro de la app y no un servidor? Son pocos datos, se
// ven sin internet y no cuestan nada.
import 'dart:math' as math;

enum PassKind {
  /// Viajes ilimitados durante unas horas.
  unlimited,

  /// Tarjeta turística: transporte + museos (solo compensa si vas a museos).
  cityCard,
}

class TransitPass {
  const TransitPass({
    required this.name,
    required this.kind,
    required this.url,
  });

  final String name;
  final PassKind kind;
  final String url;
}

/// La tarjeta recargable de la ciudad (Suica, Oyster, Navigo Easy...).
class TransitCard {
  const TransitCard({required this.name, required this.url});

  final String name;
  final String url;
}

class CityTransit {
  const CityTransit({
    required this.id,
    required this.city,
    required this.airports,
    required this.currency,
    required this.url,
    this.card,
    this.capping = false,
    this.passes = const <TransitPass>[],
  });

  final String id;
  final String city;

  /// Los aeropuertos de la ciudad (así se sabe la ciudad por tu vuelo).
  final List<String> airports;
  final String currency;

  /// La web oficial del transporte de la ciudad.
  final String url;
  final TransitCard? card;

  /// Pagando con tarjeta o móvil hay tope diario o semanal (Londres, Nueva
  /// York): a partir de cierto gasto, el resto es gratis.
  final bool capping;
  final List<TransitPass> passes;
}

const List<CityTransit> cityTransit = <CityTransit>[
  CityTransit(
    id: 'tokyo',
    city: 'Tokyo',
    airports: <String>['HND', 'NRT'],
    currency: 'JPY',
    url: 'https://www.tokyometro.jp/en/ticket/',
    card: TransitCard(
      name: 'Suica / PASMO',
      url: 'https://www.jreast.co.jp/multi/en/welcomesuica/purchase.html',
    ),
    passes: <TransitPass>[
      TransitPass(
        name: 'Tokyo Subway Ticket',
        kind: PassKind.unlimited,
        url: 'https://www.tokyometro.jp/en/ticket/travel/index.html',
      ),
    ],
  ),
  CityTransit(
    id: 'london',
    city: 'London',
    airports: <String>['LHR', 'LGW', 'STN', 'LTN', 'LCY'],
    currency: 'GBP',
    url: 'https://tfl.gov.uk/fares/',
    card: TransitCard(
      name: 'Contactless / Oyster',
      url: 'https://tfl.gov.uk/fares/how-to-pay-and-where-to-buy-tickets-and-oyster/pay-as-you-go/',
    ),
    capping: true,
  ),
  CityTransit(
    id: 'nyc',
    city: 'New York',
    airports: <String>['JFK', 'LGA', 'EWR'],
    currency: 'USD',
    url: 'https://www.mta.info/fares-tolls',
    card: TransitCard(name: 'OMNY', url: 'https://omny.info/'),
    capping: true,
  ),
  CityTransit(
    id: 'paris',
    city: 'Paris',
    airports: <String>['CDG', 'ORY', 'BVA'],
    currency: 'EUR',
    url: 'https://www.iledefrance-mobilites.fr/en/tarifs-titre-de-transport-en-commun-2026',
    card: TransitCard(
      name: 'Navigo Easy',
      url: 'https://www.iledefrance-mobilites.fr/en/tarifs-titre-de-transport-en-commun-2026',
    ),
    passes: <TransitPass>[
      TransitPass(
        name: 'Paris Visite',
        kind: PassKind.unlimited,
        url: 'https://www.iledefrance-mobilites.fr/en/tarifs-titre-de-transport-en-commun-2026',
      ),
    ],
  ),
  CityTransit(
    id: 'rome',
    city: 'Rome',
    airports: <String>['FCO', 'CIA'],
    currency: 'EUR',
    url: 'https://www.atac.roma.it/en/tickets-and-passes',
    passes: <TransitPass>[
      TransitPass(
        name: 'Roma 24/48/72h',
        kind: PassKind.unlimited,
        url: 'https://www.atac.roma.it/en/tickets-and-passes',
      ),
      TransitPass(
        name: 'Roma Pass',
        kind: PassKind.cityCard,
        url: 'https://www.romapass.it/',
      ),
    ],
  ),
  CityTransit(
    id: 'madrid',
    city: 'Madrid',
    airports: <String>['MAD'],
    currency: 'EUR',
    url: 'https://www.crtm.es/',
    card: TransitCard(
      name: 'Tarjeta Multi',
      url: 'https://www.crtm.es/billetes-y-tarifas/',
    ),
    passes: <TransitPass>[
      TransitPass(
        name: 'Abono Turístico',
        kind: PassKind.unlimited,
        url: 'https://www.crtm.es/billetes-y-tarifas/',
      ),
    ],
  ),
  CityTransit(
    id: 'barcelona',
    city: 'Barcelona',
    airports: <String>['BCN'],
    currency: 'EUR',
    url: 'https://www.tmb.cat/en/barcelona-fares-metro-bus',
    card: TransitCard(
      name: 'T-casual',
      url: 'https://www.tmb.cat/en/barcelona-fares-metro-bus',
    ),
    passes: <TransitPass>[
      TransitPass(
        name: 'Hola Barcelona',
        kind: PassKind.unlimited,
        url: 'https://www.holabarcelona.com/',
      ),
    ],
  ),
  CityTransit(
    id: 'lisbon',
    city: 'Lisbon',
    airports: <String>['LIS'],
    currency: 'EUR',
    url: 'https://www.metrolisboa.pt/en/buy/',
    card: TransitCard(
      name: 'Navegante / Viva Viagem',
      url: 'https://www.metrolisboa.pt/en/buy/',
    ),
    passes: <TransitPass>[
      TransitPass(
        name: 'Carris/Metro 24h',
        kind: PassKind.unlimited,
        url: 'https://www.metrolisboa.pt/en/buy/',
      ),
      TransitPass(
        name: 'Lisboa Card',
        kind: PassKind.cityCard,
        url: 'https://shop.visitlisboa.com/products/lisboa-card',
      ),
    ],
  ),
  CityTransit(
    id: 'berlin',
    city: 'Berlin',
    airports: <String>['BER'],
    currency: 'EUR',
    url: 'https://www.bvg.de/en/tickets/fares',
    passes: <TransitPass>[
      TransitPass(
        name: 'BVG 24-hour ticket',
        kind: PassKind.unlimited,
        url: 'https://www.bvg.de/en/tickets/fares',
      ),
    ],
  ),
];

/// La ciudad de un aeropuerto (o null si no está en la tabla).
CityTransit? cityForAirport(String? iata) {
  if (iata == null) return null;
  final String code = iata.toUpperCase();
  for (final CityTransit c in cityTransit) {
    if (c.airports.contains(code)) return c;
  }
  return null;
}

/// La cuenta con los precios que APUNTA la persona (los de la web oficial).
class PassMath {
  const PassMath({required this.singles, required this.passes});

  /// Todos los viajes sueltos de la estancia.
  final double singles;

  /// Los bonos que hacen falta para cubrir la estancia (5 días con uno de
  /// 72 h = dos bonos).
  final double passes;

  bool get passPaysOff => passes < singles;
}

PassMath passPaysOff({
  required int days,
  required int ridesPerDay,
  required double single,
  required double passPrice,
  required int passHours,
}) {
  final int d = math.max(1, days);
  final int count = (d * 24 / math.max(1, passHours)).ceil();
  return PassMath(
    singles: d * math.max(0, ridesPerDay) * single,
    passes: count * passPrice,
  );
}
