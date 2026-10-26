// "Mis billetes": los bonos y tarjetas de transporte que ya tienes.
//
// Se guardan SOLO en el móvil (LocalData.transitTickets). La app no compra
// ni valida billetes (eso lo hace cada operador): te recuerda cuánto le
// queda a tu bono y cuánto saldo apuntaste en la tarjeta.
import 'dart:convert';

class TransitTicket {
  const TransitTicket({
    required this.id,
    required this.name,
    this.hours,
    this.activatedAt,
    this.balance,
    this.currency,
    this.url,
  });

  final String id;
  final String name;

  /// Bono de X horas (null = tarjeta recargable).
  final int? hours;
  final DateTime? activatedAt;

  /// El saldo que apuntaste de la tarjeta.
  final double? balance;
  final String? currency;

  /// Dónde recargar o comprobar (la web oficial).
  final String? url;

  bool get isPass => hours != null;

  DateTime? get endsAt {
    final DateTime? a = activatedAt;
    final int? h = hours;
    return a == null || h == null ? null : a.add(Duration(hours: h));
  }

  /// Lo que le queda al bono (cero si ya caducó; null si es una tarjeta).
  Duration? leftAt(DateTime now) {
    final DateTime? end = endsAt;
    if (end == null) return null;
    final Duration left = end.difference(now);
    return left.isNegative ? Duration.zero : left;
  }

  /// La parte que le queda (1 = recién activado, 0 = caducado).
  double? leftFraction(DateTime now) {
    final Duration? left = leftAt(now);
    final int? h = hours;
    if (left == null || h == null) return null;
    return (left.inMinutes / (h * 60)).clamp(0, 1).toDouble();
  }

  TransitTicket withBalance(double? value) => TransitTicket(
    id: id,
    name: name,
    hours: hours,
    activatedAt: activatedAt,
    balance: value,
    currency: currency,
    url: url,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'name': name,
    'hours': ?hours,
    'activated': ?activatedAt?.toUtc().toIso8601String(),
    'balance': ?balance,
    'currency': ?currency,
    'url': ?url,
  };

  static TransitTicket? fromJson(Object? json) {
    if (json is! Map<String, Object?>) return null;
    final Object? id = json['id'];
    final Object? name = json['name'];
    if (id is! String || name is! String || name.isEmpty) return null;
    final Object? hours = json['hours'];
    final Object? activated = json['activated'];
    final Object? balance = json['balance'];
    final Object? currency = json['currency'];
    final Object? url = json['url'];
    return TransitTicket(
      id: id,
      name: name.length > 60 ? name.substring(0, 60) : name,
      hours: hours is int && hours > 0 && hours <= 24 * 31 ? hours : null,
      activatedAt: activated is String
          ? DateTime.tryParse(activated)?.toLocal()
          : null,
      balance: balance is num ? balance.toDouble() : null,
      currency: currency is String ? currency : null,
      url: url is String && url.startsWith('https://') ? url : null,
    );
  }
}

List<TransitTicket> decodeTickets(String? raw) {
  if (raw == null) return <TransitTicket>[];
  try {
    final Object? list = jsonDecode(raw);
    if (list is! List<Object?>) return <TransitTicket>[];
    return <TransitTicket>[
      for (final Object? t in list.take(30)) ?TransitTicket.fromJson(t),
    ];
  } on FormatException {
    return <TransitTicket>[];
  }
}

String encodeTickets(List<TransitTicket> tickets) =>
    jsonEncode(<Object?>[for (final TransitTicket t in tickets) t.toJson()]);
