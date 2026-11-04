// ¿Está abierto AHORA y cuánto le queda? A partir del horario que escribe
// OpenStreetMap ("Mo-Fr 09:00-20:00; Sa 10:00-14:00", "24/7"...).
//
// Solo se entiende la forma más común: días (Mo, Tu, We, Th, Fr, Sa, Su,
// sueltos o en rangos) y horas ("09:00-14:00,17:00-20:00", "off"). Si el
// horario trae algo más raro (meses, festivos sueltos, "sunrise"...), la
// respuesta es "no lo sé" y la app enseña el horario tal cual, sin adivinar.

enum OpenState {
  /// Abierto siempre (24/7).
  always,

  /// Abierto ahora: mira [OpenNow.left] y [OpenNow.total].
  open,

  /// Cerrado ahora.
  closed,

  /// No se puede saber (horario raro o sin horario).
  unknown,
}

class OpenNow {
  const OpenNow(this.state, {this.left = 0, this.total = 0});

  final OpenState state;

  /// Minutos que faltan para que cierre.
  final int left;

  /// Minutos que dura el tramo abierto de ahora (para la barra).
  final int total;
}

const List<String> _days = <String>['Mo', 'Tu', 'We', 'Th', 'Fr', 'Sa', 'Su'];
final RegExp _rule = RegExp(
  r'^(?:([A-Z][a-z](?:-[A-Z][a-z])?(?:,[A-Z][a-z](?:-[A-Z][a-z])?)*)\s+)?'
  r'(off|closed|\d{1,2}:\d{2}-\d{1,2}:\d{2}(?:,\d{1,2}:\d{2}-\d{1,2}:\d{2})*)$',
);

/// El estado de [raw] en el momento [now] (hora del móvil).
OpenNow openNow(String? raw, DateTime now) {
  final String text = (raw ?? '').trim();
  if (text.isEmpty) return const OpenNow(OpenState.unknown);
  if (text == '24/7') return const OpenNow(OpenState.always);
  // Para cada día de la semana (0 = lunes), sus tramos [inicio, fin) en
  // minutos. El fin puede pasar de 1440: abre por la noche y cierra mañana.
  final List<List<(int, int)>> week = List<List<(int, int)>>.generate(
    7,
    (_) => <(int, int)>[],
  );
  for (final String part in text.split(';')) {
    String rule = part.trim();
    if (rule.isEmpty) continue;
    // Los festivos ("PH") no se saben: se quitan de la lista de días.
    rule = rule.replaceAll(RegExp(r',PH\b|\bPH,'), '');
    if (rule.startsWith('PH')) continue;
    final RegExpMatch? m = _rule.firstMatch(rule);
    if (m == null) return const OpenNow(OpenState.unknown);
    final Set<int> days = <int>{};
    final String? dayList = m.group(1);
    if (dayList == null) {
      days.addAll(<int>[0, 1, 2, 3, 4, 5, 6]);
    } else {
      for (final String range in dayList.split(',')) {
        final List<String> ends = range.split('-');
        final int a = _days.indexOf(ends.first);
        final int b = _days.indexOf(ends.last);
        if (a < 0 || b < 0) return const OpenNow(OpenState.unknown);
        // "Sa-Mo" da la vuelta a la semana.
        for (int d = a; ; d = (d + 1) % 7) {
          days.add(d);
          if (d == b) break;
        }
      }
    }
    final List<(int, int)> spans = <(int, int)>[];
    final String times = m.group(2)!;
    if (times != 'off' && times != 'closed') {
      for (final String span in times.split(',')) {
        final List<int> at = span.split(RegExp('[-:]')).map(int.parse).toList();
        final int start = at[0] * 60 + at[1];
        int end = at[2] * 60 + at[3];
        if (start >= 1440 || end > 1440 || at[1] > 59 || at[3] > 59) {
          return const OpenNow(OpenState.unknown);
        }
        if (end <= start) end += 1440;
        spans.add((start, end));
      }
    }
    // Una regla que nombra un día manda sobre las de antes para ese día.
    for (final int d in days) {
      week[d] = spans;
    }
  }
  if (week.every(
    (List<(int, int)> d) => d.length == 1 && d.first == (0, 1440),
  )) {
    return const OpenNow(OpenState.always);
  }
  final int today = now.weekday - 1;
  final int minute = now.hour * 60 + now.minute;
  for (final (int start, int end) in week[today]) {
    if (start <= minute && minute < end) {
      return OpenNow(OpenState.open, left: end - minute, total: end - start);
    }
  }
  // Lo que abrió ayer y aún no ha cerrado (bares de noche).
  for (final (int start, int end) in week[(today + 6) % 7]) {
    if (end > 1440 && minute + 1440 < end) {
      return OpenNow(
        OpenState.open,
        left: end - 1440 - minute,
        total: end - start,
      );
    }
  }
  return const OpenNow(OpenState.closed);
}
