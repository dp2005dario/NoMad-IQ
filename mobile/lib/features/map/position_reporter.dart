// El "cartero" de posiciones: junta las posiciones del GPS y las manda al
// servidor por lotes, no de una en una.
//
// ¿Por qué por lotes? Encender la radio del móvil para enviar algo gasta
// mucha batería; enviar 10 posiciones de golpe cuesta casi lo mismo que
// enviar una. Con millones de usuarios, además, son 10 veces menos
// peticiones para el servidor.
import 'dart:async';
import 'dart:math' as math;

import '../../core/api_client.dart';
import 'geo.dart';
import 'geo_api.dart';

typedef SendPositions = Future<int> Function(List<PositionFix> fixes);

class PositionReporter {
  PositionReporter({
    required this._send,
    DateTime Function()? clock,
    this.batchSize = 10,
    this.maxWait = const Duration(seconds: 60),
    this.maxQueue = 200,
  }) : _now = clock ?? DateTime.now;

  final SendPositions _send;
  final DateTime Function() _now;

  /// Con estas posiciones en cola se envía ya, sin esperar.
  final int batchSize;

  /// Una posición nunca espera más que esto antes de salir.
  final Duration maxWait;

  /// Sin conexión durante horas, la cola no crece sin fin: se tiran las
  /// más viejas (la última posición es la que importa).
  final int maxQueue;

  /// El servidor rechaza posiciones de hace más de 24 h; dejamos margen.
  static const Duration maxAge = Duration(hours: 23);

  final List<PositionFix> _queue = <PositionFix>[];
  Timer? _timer;
  bool _sending = false;
  bool _stopped = false;
  int _failures = 0;

  int get pending => _queue.length;

  void add(PositionFix fix) {
    if (_stopped) return;
    _queue.add(fix);
    // Mientras se envía un lote no se recorta (se borraría el lote que va
    // de camino); ya se recortará en la próxima posición.
    if (_queue.length > maxQueue && !_sending) {
      _queue.removeRange(0, _queue.length - maxQueue);
    }
    if (_queue.length >= batchSize && _failures == 0) {
      unawaited(flush(all: false));
    } else {
      _timer ??= Timer(maxWait, () => unawaited(flush()));
    }
  }

  /// Envía ya lo que haya (por ejemplo, cuando la app pasa a segundo plano).
  /// Con [all] = false solo envía lotes completos; el resto espera su turno.
  Future<void> flush({bool all = true}) async {
    _timer?.cancel();
    _timer = null;
    if (_sending || _stopped) return;
    _sending = true;
    try {
      while (_queue.isNotEmpty && !_stopped) {
        final DateTime oldest = _now().subtract(maxAge);
        _queue.removeWhere((PositionFix f) => f.recordedAt.isBefore(oldest));
        if (_queue.isEmpty) break;
        final List<PositionFix> batch = _queue
            .take(GeoApi.maxBatch)
            .toList(growable: false);
        try {
          await _send(batch);
          _queue.removeRange(0, batch.length);
          _failures = 0;
          if (!all && _queue.length < batchSize) break;
        } on ApiException catch (e) {
          switch (e.error) {
            case ApiError.invalidInput:
              // El servidor nunca aceptará este lote: se tira y se sigue.
              _queue.removeRange(0, batch.length);
            case ApiError.signedOut:
              // Sin cuenta no hay a quién mandarlas: se olvidan.
              _queue.clear();
              _stopped = true;
            case ApiError.notFound ||
                ApiError.gone ||
                ApiError.conflict ||
                ApiError.rateLimited ||
                ApiError.unavailable ||
                ApiError.network:
              _retryLater(e.retryAfter);
              return;
          }
        }
      }
    } finally {
      _sending = false;
    }
    // Lo que quedó a medias sale como mucho dentro de [maxWait].
    if (_queue.isNotEmpty && !_stopped) {
      _timer ??= Timer(maxWait, () => unawaited(flush()));
    }
  }

  /// Deja de enviar (al cerrar la pantalla o la sesión).
  void dispose() {
    _stopped = true;
    _timer?.cancel();
    _timer = null;
    _queue.clear();
  }

  /// Reintento con espera creciente (15 s, 30 s, 1 min... hasta 5 min).
  /// Así, si el servidor está caído, millones de móviles no le golpean
  /// todos a la vez en cuanto vuelve.
  void _retryLater(Duration? retryAfter) {
    _failures++;
    final int seconds = math.min(300, 15 * (1 << math.min(_failures - 1, 5)));
    final Duration wait = retryAfter ?? Duration(seconds: seconds);
    _timer?.cancel();
    _timer = Timer(wait, () => unawaited(flush()));
  }
}
