// Maleta retrasada, perdida o rota: plazos y carta de reclamación.
//
// Lo manda el Convenio de Montreal (1999), que aplican casi todos los
// países del mundo en vuelos internacionales:
//   - Maleta ROTA o con cosas que faltan: reclamar por escrito en 7 días
//     desde que te la dan (artículo 31).
//   - Maleta RETRASADA: reclamar en 21 días desde que te la entregan
//     (artículo 31). Lo que compres mientras (cepillo, ropa...) se paga.
//   - Si a los 21 días no aparece, cuenta como PERDIDA (artículo 17.3) y se
//     reclama su valor.
//   - Tope: 1.519 DEG (derechos especiales de giro, una "moneda" del FMI),
//     unos 1.800 € (revisión de los límites de diciembre de 2024).
//
// Todo esto se guarda SOLO en el móvil (LocalData.bagClaim).
import 'dart:convert';

enum BagProblem { delayed, damaged }

/// Tope del Convenio de Montreal, en DEG (desde el 28-12-2024).
const int montrealLimitSdr = 1519;

class BagClaim {
  const BagClaim({
    this.problem = BagProblem.delayed,
    this.airline = '',
    this.reference = '',
    this.tag = '',
    this.flight = '',
    this.arrived,
    this.delivered,
    this.trackerLink = '',
    this.spent = '',
    this.done = const <int>{},
  });

  final BagProblem problem;
  final String airline;

  /// La referencia del parte (PIR) del mostrador: "MADIB12345".
  final String reference;

  /// El número de la etiqueta de la maleta ("IB 123456").
  final String tag;
  final String flight;

  /// Cuándo aterrizaste.
  final DateTime? arrived;

  /// Cuándo te la devolvieron (si ya apareció).
  final DateTime? delivered;

  /// El enlace para compartir la ubicación de tu AirTag / SmartTag / Tile.
  final String trackerLink;

  /// Lo que llevas gastado en cosas básicas ("85 €"), tal cual lo escribes.
  final String spent;

  /// Los pasos de la lista ya hechos.
  final Set<int> done;

  BagClaim copyWith({
    BagProblem? problem,
    String? airline,
    String? reference,
    String? tag,
    String? flight,
    DateTime? arrived,
    DateTime? delivered,
    bool clearDelivered = false,
    String? trackerLink,
    String? spent,
    Set<int>? done,
  }) => BagClaim(
    problem: problem ?? this.problem,
    airline: airline ?? this.airline,
    reference: reference ?? this.reference,
    tag: tag ?? this.tag,
    flight: flight ?? this.flight,
    arrived: arrived ?? this.arrived,
    delivered: clearDelivered ? null : delivered ?? this.delivered,
    trackerLink: trackerLink ?? this.trackerLink,
    spent: spent ?? this.spent,
    done: done ?? this.done,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'problem': problem.name,
    'airline': airline,
    'reference': reference,
    'tag': tag,
    'flight': flight,
    'arrived': ?arrived?.toIso8601String(),
    'delivered': ?delivered?.toIso8601String(),
    'trackerLink': trackerLink,
    'spent': spent,
    'done': done.toList()..sort(),
  };

  static BagClaim parse(String? raw) {
    if (raw == null) return const BagClaim();
    try {
      final Object? json = jsonDecode(raw);
      if (json is! Map<String, Object?>) return const BagClaim();
      String text(String k) => json[k] is String ? json[k]! as String : '';
      DateTime? day(String k) => DateTime.tryParse(text(k));
      final Object? done = json['done'];
      return BagClaim(
        problem: json['problem'] == 'damaged'
            ? BagProblem.damaged
            : BagProblem.delayed,
        airline: text('airline'),
        reference: text('reference'),
        tag: text('tag'),
        flight: text('flight'),
        arrived: day('arrived'),
        delivered: day('delivered'),
        trackerLink: text('trackerLink'),
        spent: text('spent'),
        done: <int>{
          if (done is List<Object?>)
            for (final Object? d in done)
              if (d is int) d,
        },
      );
    } on FormatException {
      return const BagClaim();
    }
  }
}

/// El plazo que importa ahora mismo.
enum DeadlineKind {
  /// Rota: 7 días desde que te la dieron.
  damaged,

  /// Ya apareció tarde: 21 días desde que te la dieron.
  delayed,

  /// Aún no aparece: a los 21 días cuenta como perdida.
  lostFrom,
}

class BagDeadline {
  const BagDeadline(this.kind, this.date);

  final DeadlineKind kind;
  final DateTime date;

  int daysLeft(DateTime now) => DateTime(
    date.year,
    date.month,
    date.day,
  ).difference(DateTime(now.year, now.month, now.day)).inDays;
}

/// null = falta la fecha para calcularlo.
BagDeadline? deadlineOf(BagClaim c) {
  final DateTime? arrived = c.arrived;
  final DateTime? delivered = c.delivered;
  return switch (c.problem) {
    BagProblem.damaged when (delivered ?? arrived) != null => BagDeadline(
      DeadlineKind.damaged,
      (delivered ?? arrived)!.add(const Duration(days: 7)),
    ),
    BagProblem.delayed when delivered != null => BagDeadline(
      DeadlineKind.delayed,
      delivered.add(const Duration(days: 21)),
    ),
    BagProblem.delayed when arrived != null => BagDeadline(
      DeadlineKind.lostFrom,
      arrived.add(const Duration(days: 21)),
    ),
    _ => null,
  };
}

String _day(DateTime d) =>
    '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

/// La carta para la aerolínea. En inglés a propósito: la entienden todas.
String bagLetter(BagClaim c, {required String name, required DateTime now}) {
  final BagDeadline? d = deadlineOf(c);
  final bool lost =
      c.problem == BagProblem.delayed &&
      c.delivered == null &&
      d != null &&
      d.daysLeft(now) <= 0;
  final String what = switch (c.problem) {
    BagProblem.damaged =>
      'My checked baggage was delivered damaged${c.delivered != null ? ' on ${_day(c.delivered!)}' : ''}.',
    BagProblem.delayed when lost => 'My checked baggage has not been delivered 21 days after arrival and must be considered lost (Article 17(3)).',
    BagProblem.delayed when c.delivered != null =>
      'My checked baggage was delayed and only delivered on ${_day(c.delivered!)}.',
    BagProblem.delayed => 'My checked baggage has not been delivered yet.',
  };
  final List<String> lines = <String>[
    'Passenger: $name',
    if (c.flight.isNotEmpty)
      'Flight: ${c.flight}${c.arrived != null ? ' on ${_day(c.arrived!)}' : ''}',
    if (c.reference.isNotEmpty) 'Property Irregularity Report: ${c.reference}',
    if (c.tag.isNotEmpty) 'Bag tag number: ${c.tag}',
    if (c.trackerLink.isNotEmpty)
      'Live location of my bag tracker: ${c.trackerLink}',
    if (c.spent.isNotEmpty)
      'Essential items bought so far: ${c.spent} (receipts attached)',
  ];
  return '''Dear Sir or Madam,

I am writing to make a written baggage claim under Articles 17, 19, 22 and 31 of the Montreal Convention (1999).

${lines.join('\n')}

$what

Please ${lost
      ? 'compensate me for the value of the bag and its contents'
      : c.problem == BagProblem.damaged
      ? 'repair or compensate the damage'
      : 'deliver the bag to my address and reimburse my essential purchases'} up to the limit of $montrealLimitSdr SDR, and confirm receipt of this claim.

Kind regards,
$name''';
}

/// "mailto:" con el asunto y la carta. La dirección de la aerolínea la
/// pones tú (en su web, "baggage claims").
Uri bagEmail(BagClaim c, {required String name, required DateTime now}) {
  String enc(String s) => Uri.encodeComponent(s);
  final String subject =
      'Baggage claim${c.reference.isNotEmpty ? ' – ${c.reference}' : ''}${c.flight.isNotEmpty ? ' – ${c.flight}' : ''}';
  return Uri.parse(
    'mailto:?subject=${enc(subject)}&body=${enc(bagLetter(c, name: name, now: now))}',
  );
}
