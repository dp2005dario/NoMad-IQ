// "¿Con qué tarjeta pago aquí?": tus tarjetas con sus comisiones y cuál te
// sale más barata en este viaje.
//
// Todo vive SOLO en el móvil (SharedPreferences): ni el número de la
// tarjeta ni sus comisiones salen nunca del teléfono. Y del número solo se
// guardan los 4 últimos dígitos, para que sepas cuál es cuál.
import 'dart:convert';
import 'dart:math' as math;

import '../../core/settings.dart';

/// Como mucho estas tarjetas (de sobra para cualquier cartera).
const int maxTravelCards = 8;

/// Cuánto se saca de una vez en el cajero (en unidades: 200 €, 200 $...).
/// Sirve para estimar cuántas comisiones fijas pagarás.
const int withdrawalUnits = 200;

/// Una tarjeta y lo que cobra fuera de su país.
class TravelCard {
  const TravelCard({
    required this.name,
    required this.payPct,
    required this.atmPct,
    required this.atmFixedMinor,
    this.last4,
    this.color = 0,
  });

  final String name;

  /// Los 4 últimos dígitos (null = no los quiso poner). Nunca el número.
  final String? last4;

  /// Qué color tiene el dibujo de la tarjeta (0..4).
  final int color;

  /// % que cobra al pagar en otra moneda (por ejemplo 3 = 3 %).
  final double payPct;

  /// % que cobra al sacar dinero del cajero.
  final double atmPct;

  /// Lo fijo por cada vez que sacas (en céntimos de tu moneda).
  final int atmFixedMinor;

  Map<String, Object?> toJson() => <String, Object?>{
    'name': name,
    if (last4 != null) 'last4': last4,
    'color': color,
    'pay_pct': payPct,
    'atm_pct': atmPct,
    'atm_fixed_minor': atmFixedMinor,
  };

  static TravelCard? parse(Object? json) {
    if (json is! Map<String, Object?>) return null;
    final Object? name = json['name'];
    final Object? last4 = json['last4'];
    final Object? color = json['color'];
    final Object? pay = json['pay_pct'];
    final Object? atm = json['atm_pct'];
    final Object? fixed = json['atm_fixed_minor'];
    if (name is! String ||
        name.trim().isEmpty ||
        (last4 != null && (last4 is! String || !isLast4(last4))) ||
        pay is! num ||
        atm is! num ||
        fixed is! int ||
        !validPct(pay.toDouble()) ||
        !validPct(atm.toDouble()) ||
        fixed < 0) {
      return null;
    }
    return TravelCard(
      name: name.trim(),
      last4: last4 as String?,
      color: color is int ? color % 5 : 0,
      payPct: pay.toDouble(),
      atmPct: atm.toDouble(),
      atmFixedMinor: fixed,
    );
  }
}

bool isLast4(String v) => RegExp(r'^[0-9]{4}$').hasMatch(v);

/// Una comisión con sentido: entre 0 % y 20 %.
bool validPct(double v) => v >= 0 && v <= 20 && v.isFinite;

/// Lo que piensas gastar en el viaje y cuánto será en efectivo.
class SpendPlan {
  const SpendPlan({
    required this.currency,
    required this.spendMinor,
    required this.cashPct,
  });

  /// Tu moneda (la de las tarjetas): EUR, USD...
  final String currency;
  final int spendMinor;

  /// Qué parte sacarás del cajero (0..100).
  final int cashPct;
}

/// Cuánto te cuesta una tarjeta en ese viaje (en céntimos de tu moneda).
///
/// Ejemplo: 1.400 € con el 20 % en efectivo y una tarjeta de "pagar 3 %,
/// sacar 2,5 % + 3 €": 1.120 € pagando (33,60 €) + 280 € sacando (7 € +
/// 2 veces 3 €) = 46,60 €.
int tripCost(TravelCard card, SpendPlan plan, int digits) {
  final double cash = plan.spendMinor * plan.cashPct / 100;
  final double paid = plan.spendMinor - cash;
  final int perWithdrawal = withdrawalUnits * math.pow(10, digits).toInt();
  final int withdrawals = cash <= 0 ? 0 : (cash / perWithdrawal).ceil();
  return (paid * card.payPct / 100 +
          cash * card.atmPct / 100 +
          withdrawals * card.atmFixedMinor)
      .round();
}

/// La cartera guardada en el móvil.
class Wallet {
  const Wallet({required this.cards, required this.plan});

  final List<TravelCard> cards;
  final SpendPlan plan;

  static const Wallet empty = Wallet(
    cards: <TravelCard>[],
    plan: SpendPlan(currency: 'EUR', spendMinor: 140000, cashPct: 20),
  );

  /// La posición de la más barata (null = no hay tarjetas).
  int? best(int digits) {
    int? at;
    int? low;
    for (int i = 0; i < cards.length; i++) {
      final int c = tripCost(cards[i], plan, digits);
      if (low == null || c < low) {
        low = c;
        at = i;
      }
    }
    return at;
  }

  Wallet copyWith({List<TravelCard>? cards, SpendPlan? plan}) =>
      Wallet(cards: cards ?? this.cards, plan: plan ?? this.plan);

  static Wallet load(SettingsStore prefs) {
    final String? raw = prefs.readData(LocalData.travelCards);
    if (raw == null) return empty;
    try {
      final Object? json = jsonDecode(raw);
      if (json is! Map<String, Object?>) return empty;
      final Object? cards = json['cards'];
      final Object? currency = json['currency'];
      final Object? spend = json['spend_minor'];
      final Object? cash = json['cash_pct'];
      return Wallet(
        cards: <TravelCard>[
          if (cards is List<Object?>)
            for (final Object? c in cards.take(maxTravelCards))
              if (TravelCard.parse(c) case final TravelCard card) card,
        ],
        plan: SpendPlan(
          currency:
              currency is String && RegExp(r'^[A-Z]{3}$').hasMatch(currency)
              ? currency
              : 'EUR',
          spendMinor: spend is int && spend >= 0 ? spend : 140000,
          cashPct: cash is int && cash >= 0 && cash <= 100 ? cash : 20,
        ),
      );
    } on FormatException {
      return empty;
    }
  }

  Future<void> save(SettingsStore prefs) => prefs.writeData(
    LocalData.travelCards,
    jsonEncode(<String, Object?>{
      'cards': <Object?>[for (final TravelCard c in cards) c.toJson()],
      'currency': plan.currency,
      'spend_minor': plan.spendMinor,
      'cash_pct': plan.cashPct,
    }),
  );
}
