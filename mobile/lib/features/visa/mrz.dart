// La zona MRZ del pasaporte: las dos líneas de letras y <<<< que hay debajo
// de la foto. Están hechas para que las lea una máquina (norma OACI 9303) y
// llevan "dígitos de control": unas cuentas que dicen si la lectura salió
// bien. Así rellenamos el ESTA con tus datos sin escribirlos a mano.
//
// El texto sale de la foto del pasaporte que ya guardaste en la Bóveda (el
// móvil la leyó al guardarla, sin Internet). Nada de esto se guarda ni sale
// del teléfono: vive en la memoria mientras la pantalla está abierta.

class MrzData {
  const MrzData({
    required this.surname,
    required this.givenNames,
    required this.number,
    required this.nationality,
    required this.issuer,
    required this.birth,
    required this.expiry,
    this.sex,
  });

  final String surname;
  final String givenNames;

  /// Número de pasaporte.
  final String number;

  /// Código de tres letras ("ESP"); en Alemania, "D".
  final String nationality;

  /// País que lo expidió (normalmente el mismo).
  final String issuer;
  final DateTime birth;
  final DateTime expiry;

  /// "M", "F" o null (sin indicar).
  final String? sex;
}

/// El valor de cada carácter para los dígitos de control: 0-9 valen lo que
/// son, A=10 ... Z=35 y "<" vale 0.
int _value(int c) {
  if (c >= 0x30 && c <= 0x39) return c - 0x30;
  if (c >= 0x41 && c <= 0x5A) return c - 0x41 + 10;
  return 0;
}

/// El dígito de control de OACI: pesos 7, 3, 1, 7, 3, 1... y módulo 10.
int mrzCheckDigit(String s) {
  const List<int> weights = <int>[7, 3, 1];
  int sum = 0;
  for (int i = 0; i < s.length; i++) {
    sum += _value(s.codeUnitAt(i)) * weights[i % 3];
  }
  return sum % 10;
}

bool _checks(String field, String digit) =>
    digit.length == 1 &&
    int.tryParse(digit.replaceAll('<', '0')) == mrzCheckDigit(field);

/// "AAMMDD" → fecha. [future]: la caducidad siempre es del siglo XXI; para el
/// nacimiento, un año mayor que el actual es del siglo pasado.
DateTime? _date(String s, {required bool future, required DateTime now}) {
  final RegExpMatch? m = RegExp(r'^(\d\d)(\d\d)(\d\d)$').firstMatch(s);
  if (m == null) return null;
  final int yy = int.parse(m[1]!);
  final int month = int.parse(m[2]!);
  final int day = int.parse(m[3]!);
  if (month < 1 || month > 12 || day < 1 || day > 31) return null;
  final int year = future || yy <= now.year % 100 ? 2000 + yy : 1900 + yy;
  return DateTime(year, month, day);
}

/// Limpia lo que leyó el OCR: mayúsculas, sin espacios y con "<" donde el
/// móvil a veces ve "«" o "‹".
String _clean(String line) => line
    .toUpperCase()
    .replaceAll(RegExp(r'\s'), '')
    .replaceAll(RegExp('[«‹]'), '<');

/// En los números el OCR confunde la O con el 0 (y la I con el 1).
String _digits(String s) => s.replaceAll('O', '0').replaceAll('I', '1');

/// Busca la MRZ de un pasaporte (formato TD3: 2 líneas de 44) en el texto de
/// una o varias páginas. null si no aparece o si los dígitos de control no
/// cuadran (mejor no rellenar nada que rellenar mal).
MrzData? parseMrz(Iterable<String> pages, {DateTime? now}) {
  final DateTime today = now ?? DateTime.now();
  final List<String> lines = <String>[
    for (final String page in pages)
      for (final String l in page.split('\n'))
        if (_clean(l).length >= 30) _clean(l),
  ];
  for (int i = 0; i + 1 < lines.length; i++) {
    final MrzData? d = _pair(lines[i], lines[i + 1], today);
    if (d != null) return d;
  }
  return null;
}

MrzData? _pair(String l1, String l2, DateTime now) {
  if (!l1.startsWith('P') || l2.length < 44) return null;
  final String top = l1.padRight(44, '<').substring(0, 44);
  final String low = l2.substring(0, 44);

  // Línea 2: número(9) control nacionalidad(3) nacimiento(6) control
  // sexo(1) caducidad(6) control ...
  String number = low.substring(0, 9);
  if (!_checks(number, low[9])) {
    number = _digits(number);
    if (!_checks(number, low[9])) return null;
  }
  final String birthRaw = _digits(low.substring(13, 19));
  final String expiryRaw = _digits(low.substring(21, 27));
  if (!_checks(birthRaw, _digits(low[19])) ||
      !_checks(expiryRaw, _digits(low[27]))) {
    return null;
  }
  final DateTime? birth = _date(birthRaw, future: false, now: now);
  final DateTime? expiry = _date(expiryRaw, future: true, now: now);
  if (birth == null || expiry == null) return null;

  String code(String s) => s.replaceAll('<', '').replaceAll('0', 'O');
  final String nationality = code(low.substring(10, 13));
  final String issuer = code(top.substring(2, 5));
  if (!RegExp(r'^[A-Z]{1,3}$').hasMatch(nationality)) return null;

  // Línea 1: P<ESPAPELLIDO<<NOMBRE<COMPUESTO<<<<<<
  // A veces el OCR lee el relleno "<<<<" como "KKKK": se quita al final
  // (solo si son 3 K seguidas o más: ningún nombre acaba así).
  final String names = top
      .substring(5)
      .replaceFirst(RegExp(r'<+$'), '')
      .replaceFirst(RegExp(r'K{3,}[<K]*$'), '')
      .replaceFirst(RegExp(r'<+$'), '');
  final List<String> parts = names.split('<<');
  String words(String s) =>
      s.split('<').where((String w) => w.isNotEmpty).join(' ');
  final String surname = words(parts.first);
  final String given = parts.length > 1
      ? words(parts.sublist(1).join('<'))
      : '';
  if (surname.isEmpty || RegExp(r'\d').hasMatch(surname + given)) return null;

  final String sex = low[20];
  return MrzData(
    surname: surname,
    givenNames: given,
    number: number.replaceAll('<', ''),
    nationality: nationality,
    issuer: issuer,
    birth: birth,
    expiry: expiry,
    sex: sex == 'M' || sex == 'F' ? sex : null,
  );
}
