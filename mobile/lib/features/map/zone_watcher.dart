// Detecta en el propio móvil cuándo ENTRAS en una zona con audioguía, para
// avisarte al instante mientras miras el mapa ("Has entrado en Puerta del Sol").
//
// El servidor hace lo mismo con las posiciones que le mandamos (y es quien
// envía el aviso push si la app está cerrada); esto solo es la versión
// rápida para la pantalla abierta.
//
// Usa "histéresis", como el geo-engine: hay que llevar 15 s dentro para
// "entrar" y 15 s fuera para "salir". Sin ella, el GPS que tiembla en el
// borde de una zona haría entrar y salir diez veces en un minuto.
import 'geo.dart';

class ZoneWatcher {
  ZoneWatcher({this.dwell = const Duration(seconds: 15)});

  final Duration dwell;

  /// Un GPS con más error que esto no sirve para decidir si estás dentro.
  static const double maxAccuracyM = 100;

  Zone? _current;
  Zone? _candidate;
  DateTime? _candidateSince;
  DateTime? _outsideSince;

  /// La zona en la que estás ahora (ya confirmada), si hay alguna.
  Zone? get current => _current;

  /// Procesa una posición. Devuelve la zona solo en el momento de ENTRAR
  /// (una vez); el resto del tiempo, null.
  Zone? update(PositionFix fix, Iterable<Zone> zones) {
    if (fix.accuracyM > maxAccuracyM || !fix.point.isValid) return null;
    final DateTime t = fix.recordedAt;
    final Zone? here = _bestZoneAt(fix.point, zones);

    if (here != null && here.id == _current?.id) {
      _candidate = null;
      _outsideSince = null;
      return null;
    }
    if (here == null) {
      _candidate = null;
      if (_current != null) {
        final DateTime since = _outsideSince ??= t;
        if (t.difference(since) >= dwell) {
          _current = null;
          _outsideSince = null;
        }
      }
      return null;
    }
    // Estás en una zona distinta de la actual: ¿llevas ya 15 s en ella?
    if (_candidate?.id != here.id) {
      _candidate = here;
      _candidateSince = t;
      if (dwell > Duration.zero) return null;
    }
    if (t.difference(_candidateSince!) >= dwell) {
      _current = here;
      _candidate = null;
      _outsideSince = null;
      return here;
    }
    return null;
  }

  void reset() {
    _current = null;
    _candidate = null;
    _candidateSince = null;
    _outsideSince = null;
  }

  /// Si estás dentro de varias (una zona turística DENTRO del centro de la
  /// ciudad), gana la más concreta: la zona turística.
  static Zone? _bestZoneAt(GeoPoint p, Iterable<Zone> zones) {
    Zone? best;
    for (final Zone zone in zones) {
      if (!zone.kind.hasAudioguide || !zone.contains(p)) continue;
      if (best == null ||
          (zone.kind == ZoneKind.touristArea &&
              best.kind != ZoneKind.touristArea)) {
        best = zone;
      }
    }
    return best;
  }
}
