// Lo que la app le da a la página de la Bóveda (la maqueta, en
// assets/vault/boveda.html): si está cerrada o abierta, qué tarjetas tienen
// documento (con su miniatura o sus datos), lo leído de un PDF y los avisos.
// Dart puro: se prueba sin WebView.
import 'dart:convert';

import 'vault.dart';

/// Dónde está la página y la marca donde la app mete sus datos.
const String vaultPage = 'assets/vault/boveda.html';
const String vaultMarker =
    '/*ECLIPTA*/{"phase":"locked","slots":{},"found":[],"file":"","msg":""}';

/// En qué punto está la página.
enum VaultPhase { locked, opening, open }

/// El documento de cada tarjeta (el último que guardaste en ella).
Map<int, VaultDoc> docsBySlot(List<VaultDoc> docs) => <int, VaultDoc>{
  for (final VaultDoc d in docs)
    if (slotOf(d) case final int slot) slot: d,
};

/// Lo que se cuenta de una tarjeta: "g" si tiene foto (con su miniatura),
/// "f" si se pinta con sus datos (PDF o escrito a mano) y los tres datos.
Map<String, Object?> slotJson(VaultDoc d, {String? thumb}) {
  final bool photo = !d.isPdf && !d.isData && thumb != null;
  return <String, Object?>{
    'g': photo,
    'f': !photo,
    'pdf': d.isPdf,
    'v': <String>[
      for (int i = 0; i < 3; i++) i < d.fields.length ? d.fields[i] : '',
    ],
    if (photo) 'thumb': thumb,
  };
}

/// Todo lo que necesita la página.
Map<String, Object?> vaultPageData({
  required VaultPhase phase,
  List<VaultDoc> docs = const <VaultDoc>[],
  Map<String, String> thumbs = const <String, String>{},
  String scan = '',
  int slot = 1,
  List<String> found = const <String>[],
  String file = '',
  String? message,
  bool denied = false,
}) => <String, Object?>{
  'phase': phase.name,
  'scan': scan,
  'sd': slot,
  'slots': <String, Object?>{
    if (phase != VaultPhase.locked)
      for (final MapEntry<int, VaultDoc> e in docsBySlot(docs).entries)
        '${e.key}': slotJson(e.value, thumb: thumbs[e.value.id]),
  },
  'found': found,
  'file': file,
  'msg': message ?? '',
  // La huella no valió: la página la pinta en rojo y la hace temblar.
  if (denied) 'deny': true,
};

/// La página lista para enseñar.
String vaultPageWith(String page, Map<String, Object?> data) {
  // "<" como \u003c: ningún dato leído puede cerrar el script.
  final String json = jsonEncode(data).replaceAll('<', r'\u003c');
  return page.replaceFirst(vaultMarker, json);
}

/// "save:5:WyJ..." → los tres datos (null si no se entiende).
List<String>? unpackFields(String packed) {
  try {
    final String padded = packed.padRight((packed.length + 3) ~/ 4 * 4, '=');
    final Object? v = jsonDecode(utf8.decode(base64Url.decode(padded)));
    if (v is! List<Object?>) return null;
    return <String>[
      for (int i = 0; i < 3; i++)
        i < v.length && v[i] is String
            ? (v[i]! as String).trim().characters80()
            : '',
    ];
  } on FormatException {
    return null;
  }
}

extension on String {
  String characters80() => length > 80 ? substring(0, 80) : this;
}
