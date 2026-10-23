// Tus derechos si tu vuelo llega tarde, se cancela o te dejan en tierra:
// el Reglamento (CE) 261/2004 de la Unión Europea ("EU261").
//
// Las reglas, en sencillo:
// - Cubre los vuelos que SALEN de la UE (con cualquier aerolínea) y los que
//   LLEGAN a la UE con una aerolínea europea. Islandia, Noruega y Suiza
//   también lo aplican.
// - Hay compensación si llegas 3 horas tarde o más (sentencia Sturgeon del
//   Tribunal de Justicia de la UE, 2009), si te cancelan con menos de 14
//   días de aviso o si no te dejan embarcar por overbooking.
// - Cuánto: 250 € (hasta 1.500 km), 400 € (1.500–3.500 km, o cualquier
//   vuelo dentro de la UE de más de 1.500 km) y 600 € (más de 3.500 km). En
//   los de más de 3.500 km, con un retraso de 3 a 4 horas es la mitad: 300 €.
// - No se paga si fue por "circunstancias extraordinarias" (tormenta, huelga
//   de controladores...). Eso lo tiene que demostrar la aerolínea.

import '../route/geo.dart';
import '../route/world_data.dart';

/// Países donde se aplica (UE + Islandia, Noruega, Liechtenstein y Suiza).
const Set<String> eu261Countries = <String>{
  'AT',
  'BE',
  'BG',
  'HR',
  'CY',
  'CZ',
  'DK',
  'EE',
  'FI',
  'FR',
  'DE',
  'GR',
  'HU',
  'IE',
  'IT',
  'LV',
  'LT',
  'LU',
  'MT',
  'NL',
  'PL',
  'PT',
  'RO',
  'SK',
  'SI',
  'ES',
  'SE',
  'IS',
  'NO',
  'LI',
  'CH',
};

enum Disruption { delay, cancelled, deniedBoarding }

/// Por qué sí o por qué no.
enum Eu261Reason {
  covered,
  notEuRoute, // ni sale de la UE ni llega con aerolínea europea
  shortDelay, // menos de 3 horas
}

class Eu261Result {
  const Eu261Result(this.reason, {this.euros = 0, this.km = 0});

  final Eu261Reason reason;
  final int euros;
  final int km;

  bool get covered => reason == Eu261Reason.covered;
}

Eu261Result eu261({
  required String? fromCountry,
  required String? toCountry,
  required LatLon from,
  required LatLon to,
  required bool euAirline,
  required Disruption what,
  int delayMinutes = 0,
}) {
  final int km = distanceKm(from, to).round();
  final bool departsEu = eu261Countries.contains(fromCountry);
  final bool arrivesEu = eu261Countries.contains(toCountry);
  if (!departsEu && !(arrivesEu && euAirline)) {
    return Eu261Result(Eu261Reason.notEuRoute, km: km);
  }
  if (what == Disruption.delay && delayMinutes < 180) {
    return Eu261Result(Eu261Reason.shortDelay, km: km);
  }
  final bool intraEu = departsEu && arrivesEu;
  int euros;
  if (km <= 1500) {
    euros = 250;
  } else if (km <= 3500 || intraEu) {
    euros = 400;
  } else {
    euros = 600;
  }
  if (euros == 600 && what == Disruption.delay && delayMinutes < 240) {
    euros = 300;
  }
  return Eu261Result(Eu261Reason.covered, euros: euros, km: km);
}

/// Los datos de la carta.
class ClaimDetails {
  const ClaimDetails({
    required this.name,
    required this.booking,
    required this.flight,
    required this.date,
    required this.from,
    required this.to,
    required this.what,
    required this.delayMinutes,
    required this.euros,
  });

  final String name;
  final String booking;
  final String flight;
  final DateTime date;
  final Airport from;
  final Airport to;
  final Disruption what;
  final int delayMinutes;
  final int euros;
}

/// La carta para la aerolínea. Va en inglés a propósito: todas las
/// aerolíneas europeas la aceptan y la entienden sin traducir.
String claimLetter(ClaimDetails d) {
  final String day =
      '${d.date.year}-${d.date.month.toString().padLeft(2, '0')}-${d.date.day.toString().padLeft(2, '0')}';
  final String happened = switch (d.what) {
    Disruption.delay =>
      'arrived at its final destination ${d.delayMinutes ~/ 60} h ${d.delayMinutes % 60} min late',
    Disruption.cancelled => 'was cancelled less than 14 days before departure',
    Disruption.deniedBoarding => 'was denied to me at boarding against my will',
  };
  return '''Dear Sir or Madam,

I am writing to claim compensation under Regulation (EC) No 261/2004.

Passenger: ${d.name}
Booking reference: ${d.booking}
Flight: ${d.flight} on $day
Route: ${d.from.city} (${d.from.iata}) – ${d.to.city} (${d.to.iata})

The flight $happened. Under Articles 5, 6 and 7 of the Regulation, as
interpreted by the Court of Justice of the European Union (Sturgeon,
C-402/07 and C-432/07), I am entitled to compensation of EUR ${d.euros}.

Please pay this amount within 30 days to the bank account I will provide on
request, or by the payment method used for the booking. If you believe
extraordinary circumstances apply, please send me evidence of them.

Should I not receive a reply within 30 days, I will refer the matter to the
competent national enforcement body.

Kind regards,
${d.name}''';
}

/// "mailto:" con el asunto y la carta ya puestos: tú eliges la dirección
/// de la aerolínea (está en su web, en "reclamaciones" o "claims").
Uri claimEmail(ClaimDetails d) => Uri(
  scheme: 'mailto',
  query: _encodeQuery(<String, String>{
    'subject': 'EU261 compensation claim – ${d.flight} – ${d.booking}',
    'body': claimLetter(d),
  }),
);

// mailto necesita %20 (no "+") para los espacios: Uri.queryParameters
// pondría "+" y algunos programas de correo lo dejarían tal cual.
String _encodeQuery(Map<String, String> q) => q.entries
    .map(
      (MapEntry<String, String> e) =>
          '${e.key}=${Uri.encodeComponent(e.value)}',
    )
    .join('&');
