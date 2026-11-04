// Los tres datos de cada tarjeta de la Bóveda, sacados del texto que el
// móvil leyó del documento (OCR de la foto o texto del PDF).
//
// Es una ayuda: lo encontrado se enseña en el formulario y la persona lo
// corrige antes de guardar. Si no se encuentra algo, se deja vacío (nunca
// se inventa). Todo pasa dentro del móvil.
//
// Qué tres datos lleva cada tarjeta (el orden del formulario de la maqueta):
//   1 Pasaporte: nombre, número, caduca
//   2 Tarjeta de embarque: vuelo, trayecto, asiento
//   3 Seguro: póliza, válido hasta, teléfono 24 h
//   4 DNI: nombre, número, caduca
//   5 Visado: país, válido hasta, número
//   6 Hotel: hotel, fechas, confirmación
//   7 Entradas: evento, fecha, sitio
//   8 Contactos SOS: contacto 1, 2 y 3
//   9 Carnet de conducir: nombre, clase, caduca
//   10 Tarjeta sanitaria: número, caduca, país
//   11 Coche de alquiler: empresa, recogida, reserva
//   12 Tren o bus: trayecto, fecha, coche · plaza
//   13 eSIM: datos, país, activación

/// Las fechas que se reconocen: 12/03/2030, 12.03.30, 2030-03-12,
/// "12 MAR 2030" y "12 de marzo de 2030".
final RegExp _date = RegExp(
  r'\b(\d{1,2}[./-]\d{1,2}[./-]\d{2,4}|\d{4}-\d{2}-\d{2}|'
  r'\d{1,2}\s+(?:de\s+)?[A-Za-zÁÉÍÓÚáéíóú]{3,10}\.?\s+(?:de\s+)?\d{4})\b',
);

/// Todas las fechas del texto, en orden.
List<String> datesIn(String text) => <String>[
  for (final RegExpMatch m in _date.allMatches(text)) m.group(1)!,
];

/// El valor que va después de una etiqueta ("Póliza: 4471-22" → "4471-22"),
/// en la misma línea o, si no hay nada, en la siguiente.
String afterLabel(String text, List<String> labels, {RegExp? shape}) {
  final List<String> lines = text.split(RegExp(r'\r?\n'));
  for (int i = 0; i < lines.length; i++) {
    final String line = lines[i];
    for (final String label in labels) {
      final RegExpMatch? m = RegExp(
        '${RegExp.escape(label)}\\b[^:\\n]{0,20}?[:#.]?\\s*(.*)\$',
        caseSensitive: false,
        unicode: true,
      ).firstMatch(line);
      if (m == null) continue;
      String value = m.group(1)!.trim();
      if (value.isEmpty && i + 1 < lines.length) value = lines[i + 1].trim();
      if (shape != null) {
        final RegExpMatch? s = shape.firstMatch(value);
        if (s == null) continue;
        value = s.group(0)!;
      }
      if (value.isNotEmpty) return _cut(value);
    }
  }
  return '';
}

String _cut(String s) => s.length > 60 ? s.substring(0, 60).trim() : s;

String _first(RegExp r, String text, [int group = 0]) =>
    r.firstMatch(text)?.group(group)?.trim() ?? '';

/// Lo que dice la zona de lectura automática (las líneas con "<<") de un
/// pasaporte o un DNI: nombre, número y caducidad.
(String, String, String)? readMrz(String text) {
  final List<String> rows = <String>[
    for (final String l in text.split(RegExp(r'\r?\n')))
      if (l.replaceAll(' ', '').contains('<<'))
        l.replaceAll(' ', '').toUpperCase(),
  ];
  if (rows.length < 2) return null;
  String date(String yymmdd) {
    if (!RegExp(r'^\d{6}$').hasMatch(yymmdd)) return '';
    return '${yymmdd.substring(4, 6)}/${yymmdd.substring(2, 4)}/'
        '20${yymmdd.substring(0, 2)}';
  }

  String name(String row) {
    final List<String> parts = row.split('<<');
    final String surname = parts.first.replaceAll('<', ' ').trim();
    final String given = parts.length > 1
        ? parts[1].replaceAll('<', ' ').trim()
        : '';
    return _cut('$given $surname'.trim());
  }

  // Pasaporte (2 líneas de 44): P<ESPAPELLIDO<<NOMBRE / número...caducidad.
  final int p = rows.indexWhere((String r) => r.startsWith('P'));
  if (p >= 0 && p + 1 < rows.length && rows[p + 1].length >= 28) {
    final String l2 = rows[p + 1];
    return (
      name(rows[p].substring(rows[p].length > 5 ? 5 : 0)),
      l2.substring(0, 9).replaceAll('<', ''),
      date(l2.substring(21, 27)),
    );
  }
  // DNI (3 líneas de 30): ID ESP número / fechas / APELLIDO<<NOMBRE.
  final int d = rows.indexWhere((String r) => r.startsWith('I'));
  if (d >= 0 && d + 2 < rows.length && rows[d + 1].length >= 14) {
    final String l1 = rows[d];
    final String l2 = rows[d + 1];
    return (
      name(rows[d + 2]),
      l1.length >= 14 ? l1.substring(5, 14).replaceAll('<', '') : '',
      date(l2.substring(8, 14)),
    );
  }
  return null;
}

final RegExp _flight = RegExp(r'\b([A-Z]{2}|[A-Z]\d|\d[A-Z])\s?(\d{2,4})\b');
final RegExp _route = RegExp(
  r'\b([A-Z]{3})\s*(?:→|->|>|-|–|/|to|a)\s*([A-Z]{3})\b',
);
final RegExp _seat = RegExp(r'\b(\d{1,2}[A-K])\b');

/// Un teléfono: "+34 910 000 000", "(91) 000 00 00" o 9-14 cifras seguidas
/// (no "4471-2026-88", que es un número de póliza).
final RegExp _phone = RegExp(
  r'\+?\(?\d{1,4}\)?(?:[ ]{1,2}\d{2,4}){2,5}|\+\d{8,14}|\b\d{9,14}\b',
);
final RegExp _code = RegExp(r'\b[A-Z0-9][A-Z0-9-]{4,15}\b');

/// Los tres datos de la tarjeta [slot] leídos del [pages] del documento.
List<String> readFields(int slot, List<String> pages) {
  final String text = pages.join('\n');
  final List<String> dates = datesIn(text);
  String date([int k = 0]) => k < dates.length ? dates[k] : '';
  String last() => dates.isEmpty ? '' : dates.last;
  final (String, String, String)? mrz = readMrz(text);
  final List<String> out = switch (slot) {
    1 || 4 => <String>[
      mrz?.$1 ?? afterLabel(text, <String>['Nombre', 'Name', 'Nom']),
      mrz?.$2 ??
          afterLabel(text, <String>[
            'Número',
            'Numero',
            'No.',
            'Number',
            'DNI',
          ], shape: _code),
      mrz?.$3 ??
          (afterLabel(text, <String>[
            'Caduca',
            'Caducidad',
            'Expiry',
            'Validez',
            'Valid',
          ], shape: _date).ifEmpty(last())),
    ],
    2 => <String>[
      afterLabel(text, <String>[
        'Vuelo',
        'Flight',
      ], shape: _flight).ifEmpty(_first(_flight, text).replaceAll(' ', '')),
      () {
        final RegExpMatch? m = _route.firstMatch(text);
        return m == null ? '' : '${m.group(1)} → ${m.group(2)}';
      }(),
      afterLabel(text, <String>['Asiento', 'Seat'], shape: _seat),
    ],
    3 => <String>[
      afterLabel(text, <String>[
        'Póliza',
        'Poliza',
        'Policy',
        'Nº de póliza',
      ], shape: _code),
      afterLabel(text, <String>[
        'Válido hasta',
        'Valido hasta',
        'Vigencia',
        'Valid until',
      ], shape: _date).ifEmpty(last()),
      afterLabel(text, <String>[
        'Teléfono',
        'Telefono',
        'Phone',
        'Asistencia',
      ], shape: _phone).ifEmpty(_first(_phone, text)),
    ],
    5 => <String>[
      afterLabel(text, <String>['País', 'Pais', 'Country']),
      afterLabel(text, <String>[
        'Válido hasta',
        'Valid until',
        'Until',
        'Expiry',
      ], shape: _date).ifEmpty(last()),
      afterLabel(text, <String>[
        'Número',
        'Number',
        'No.',
        'Visa',
      ], shape: _code),
    ],
    6 => <String>[
      afterLabel(text, <String>['Hotel', 'Alojamiento', 'Property']),
      dates.length >= 2 ? '${date()} – ${date(1)}' : date(),
      afterLabel(text, <String>[
        'Confirmación',
        'Confirmacion',
        'Confirmation',
        'Reserva',
      ], shape: _code),
    ],
    7 => <String>[
      afterLabel(text, <String>['Evento', 'Event', 'Entrada', 'Ticket']),
      date(),
      afterLabel(text, <String>['Lugar', 'Sitio', 'Venue', 'Recinto']),
    ],
    8 => <String>[
      for (final RegExpMatch m in _phone.allMatches(text).take(3))
        m.group(0)!.trim(),
    ],
    9 => <String>[
      mrz?.$1 ?? afterLabel(text, <String>['Nombre', 'Name']),
      afterLabel(text, <String>[
        'Clase',
        'Class',
        'Categoría',
        'Categoria',
      ], shape: RegExp(r'\b(AM|A1|A2|A|B|BE|C1|C|D|E)\b')),
      afterLabel(text, <String>[
        'Caduca',
        'Expiry',
        'Validez',
      ], shape: _date).ifEmpty(last()),
    ],
    10 => <String>[
      afterLabel(text, <String>[
        'Número',
        'Numero',
        'Number',
        'Nº',
      ], shape: _code),
      afterLabel(text, <String>[
        'Caduca',
        'Expiry',
        'Validez',
      ], shape: _date).ifEmpty(last()),
      afterLabel(text, <String>['País', 'Country']),
    ],
    11 => <String>[
      afterLabel(text, <String>['Empresa', 'Company', 'Proveedor']),
      afterLabel(text, <String>[
        'Recogida',
        'Pick-up',
        'Pickup',
      ], shape: _date).ifEmpty(date()),
      afterLabel(text, <String>[
        'Reserva',
        'Booking',
        'Confirmación',
        'Confirmation',
      ], shape: _code),
    ],
    12 => <String>[
      afterLabel(text, <String>['Trayecto', 'Origen', 'Route']),
      date(),
      () {
        final String car = afterLabel(text, <String>[
          'Coche',
          'Coach',
          'Car',
        ], shape: RegExp(r'\d{1,2}'));
        final String seat = afterLabel(text, <String>[
          'Plaza',
          'Asiento',
          'Seat',
        ], shape: RegExp(r'\d{1,3}[A-Z]?'));
        return <String>[
          car,
          seat,
        ].where((String s) => s.isNotEmpty).join(' · ');
      }(),
    ],
    13 => <String>[
      _first(RegExp(r'\b\d{1,3}\s?GB\b', caseSensitive: false), text),
      afterLabel(text, <String>['País', 'Country', 'Destino']),
      afterLabel(text, <String>[
        'Activación',
        'Activacion',
        'Activation',
      ]).ifEmpty(date()),
    ],
    _ => const <String>[],
  };
  return <String>[
    for (int i = 0; i < 3; i++) i < out.length ? _cut(out[i]) : '',
  ];
}

extension on String {
  String ifEmpty(String other) => isEmpty ? other : this;
}
