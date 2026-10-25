// "Sin colas": la app pregunta al ai-orchestrator
//   GET  /v1/queues/Q243?hour=11   cuánta cola hay ahora y por horas
//   POST /v1/queues/Q243           "ahora mismo hay X de cola"
//
// Los datos son SOLO lo que avisan los viajeros que están allí (nada
// inventado): "ahora" con 2 personas o más en la última hora y media, y
// "por horas" con 3 o más en esa hora (últimos 60 días). El sitio va por su
// Wikidata (Q...), nunca tu posición.
import '../../core/api_client.dart';

/// Cuánta cola: lo que eliges al avisar (y lo que se enseña).
enum WaitLevel {
  none, // sin cola
  short, // menos de 15 min
  medium, // de 15 a 30 min
  long, // de 30 a 60 min
  veryLong; // más de una hora

  static WaitLevel? of(Object? raw) =>
      raw is int && raw >= 0 && raw < values.length ? values[raw] : null;
}

class WaitNow {
  const WaitNow(this.wait, this.reporters, this.minutesAgo);

  final WaitLevel wait;
  final int reporters;
  final int minutesAgo;
}

class WaitHour {
  const WaitHour(this.hour, this.wait, this.reporters);

  final int hour;
  final WaitLevel wait;
  final int reporters;
}

class PlaceQueue {
  const PlaceQueue({
    required this.now,
    required this.hours,
    required this.reportedThisHour,
  });

  final WaitNow? now;
  final List<WaitHour> hours;
  final bool reportedThisHour;

  /// La hora con menos cola desde [from] (solo entre las que tienen avisos).
  WaitHour? bestFrom(int from) {
    WaitHour? best;
    for (final WaitHour h in hours) {
      if (h.hour < from) continue;
      if (best == null || h.wait.index < best.wait.index) best = h;
    }
    return best;
  }

  static PlaceQueue parse(Object? json) {
    if (json is! Map<String, Object?>) {
      throw const ApiException(ApiError.unavailable);
    }
    WaitNow? now;
    final Object? n = json['now'];
    if (n is Map<String, Object?>) {
      final WaitLevel? w = WaitLevel.of(n['wait']);
      final Object? r = n['reporters'], ago = n['minutes_ago'];
      if (w != null && r is int && ago is int) now = WaitNow(w, r, ago);
    }
    final List<WaitHour> hours = <WaitHour>[];
    final Object? raw = json['hours'];
    if (raw is List<Object?>) {
      for (final Object? h in raw) {
        if (h is! Map<String, Object?>) continue;
        final Object? hour = h['hour'], r = h['reporters'];
        final WaitLevel? w = WaitLevel.of(h['wait']);
        if (hour is int && hour >= 0 && hour < 24 && w != null && r is int) {
          hours.add(WaitHour(hour, w, r));
        }
      }
    }
    return PlaceQueue(
      now: now,
      hours: hours,
      reportedThisHour: json['reported_this_hour'] == true,
    );
  }
}

class QueuesApi {
  QueuesApi(this._api);

  final ApiClient _api;

  static bool validPlace(String qid) =>
      RegExp(r'^Q[1-9][0-9]{0,11}$').hasMatch(qid);

  /// [hour] = la hora de tu reloj (para saber si ya avisaste esta hora).
  Future<PlaceQueue> place(String qid, int hour) async => PlaceQueue.parse(
    await _api.getJson(
      '/v1/queues/$qid',
      query: <String, String>{'hour': '$hour'},
    ),
  );

  Future<void> report(String qid, int hour, WaitLevel wait) async {
    await _api.postJson('/v1/queues/$qid', <String, Object?>{
      'wait': wait.index,
      'local_hour': hour,
    });
  }
}
