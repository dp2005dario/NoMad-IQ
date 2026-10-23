// "¿Me llega el dinero?": tu presupuesto del viaje y hacia dónde vas.
//
// Lo gastado sale de TU parte de los gastos de un bote (si en la cena de
// 86 € te tocan 43 €, cuentan 43 €). El presupuesto (límite y fechas) se
// guarda solo en el móvil.
import 'dart:convert';

import '../../core/settings.dart';
import 'expenses_api.dart';

/// El presupuesto guardado: qué bote, cuánto como mucho y qué días.
class TripBudget {
  const TripBudget({
    required this.potId,
    required this.limitMinor,
    required this.start,
    required this.end,
  });

  final String potId;
  final int limitMinor;
  final DateTime start;
  final DateTime end;

  /// Cuántos días dura (el primero y el último cuentan).
  int get days => end.difference(start).inDays + 1;

  static TripBudget? load(SettingsStore prefs) {
    final String? raw = prefs.readData(LocalData.tripBudget);
    if (raw == null) return null;
    try {
      final Object? json = jsonDecode(raw);
      if (json is! Map<String, Object?>) return null;
      final Object? pot = json['pot_id'];
      final Object? limit = json['limit_minor'];
      final DateTime? start = DateTime.tryParse('${json['start']}');
      final DateTime? end = DateTime.tryParse('${json['end']}');
      if (pot is! String ||
          limit is! int ||
          limit <= 0 ||
          start == null ||
          end == null ||
          end.isBefore(start)) {
        return null;
      }
      return TripBudget(potId: pot, limitMinor: limit, start: start, end: end);
    } on FormatException {
      return null;
    }
  }

  Future<void> save(SettingsStore prefs) => prefs.writeData(
    LocalData.tripBudget,
    jsonEncode(<String, Object?>{
      'pot_id': potId,
      'limit_minor': limitMinor,
      'start': _day(start),
      'end': _day(end),
    }),
  );
}

String _day(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

DateTime _date(DateTime d) => DateTime(d.year, d.month, d.day);

/// Las tres maneras de seguir (las de la maqueta: igual, apretarse un poco o
/// mucho), como multiplicador de lo que llevas gastado al día.
const List<double> budgetPaces = <double>[1, 0.75, 0.5];

/// Hacia dónde vas.
class BudgetForecast {
  const BudgetForecast({
    required this.day,
    required this.days,
    required this.spentMinor,
    required this.cumulative,
    required this.perDayMinor,
    required this.endings,
  });

  /// Qué día del viaje es hoy (1..days).
  final int day;
  final int days;
  final int spentMinor;

  /// Lo gastado acumulado al final de cada día, del 1 a hoy.
  final List<int> cumulative;

  /// Lo que llevas de media al día.
  final int perDayMinor;

  /// Cómo acabarías con cada ritmo de [budgetPaces].
  final List<int> endings;
}

/// Calcula la previsión con TU parte de cada gasto del bote.
BudgetForecast forecast(TripBudget budget, ExpenseGroup pot, DateTime now) {
  final DateTime start = _date(budget.start);
  final int days = budget.days;
  final int today = (_date(now).difference(start).inDays + 1).clamp(1, days);
  final List<int> perDay = List<int>.filled(days, 0);
  for (final Expense e in pot.expenses) {
    final int mine = e.shares[pot.mySeat] ?? 0;
    if (mine == 0) continue;
    final int i = _date(e.spentOn).difference(start).inDays;
    // Lo de antes del viaje (billetes, hotel pagado) cuenta como día 1.
    perDay[i.clamp(0, days - 1)] += mine;
  }
  final List<int> cumulative = <int>[];
  int sum = 0;
  for (int i = 0; i < today; i++) {
    sum += perDay[i];
    cumulative.add(sum);
  }
  // Lo apuntado para días que aún no han llegado (una reserva) también cuenta.
  for (int i = today; i < days; i++) {
    sum += perDay[i];
  }
  final int avg = (cumulative.last / today).round();
  final int left = days - today;
  return BudgetForecast(
    day: today,
    days: days,
    spentMinor: sum,
    cumulative: cumulative,
    perDayMinor: avg,
    endings: <int>[
      for (final double p in budgetPaces) sum + (avg * p).round() * left,
    ],
  );
}
