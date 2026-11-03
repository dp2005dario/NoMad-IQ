// Fotos de billetes y monedas (Divisas). Archivo generado a partir de
// assets/divisas/: si añades una foto allí, añádela también aquí.
//
// Las fotos las subió DARIO para la maqueta (ver assets/divisas/LEEME.md).
// Su licencia está SIN comprobar: antes de publicar en Google Play hay que
// confirmarla o cambiarlas por las "specimen" oficiales de cada banco.

/// Billetes con foto, por divisa (en unidades enteras: 5 = 5 €).
const Map<String, Set<int>> notePhotos = <String, Set<int>>{
  'AUD': <int>{5, 10, 20, 50, 100},
  'CAD': <int>{5, 10, 20, 50, 100},
  'CHF': <int>{10, 20, 50, 100, 200, 1000},
  'CNY': <int>{1, 5, 10, 20, 50, 100},
  'EUR': <int>{5, 10, 20, 50, 100, 200, 500},
  'GBP': <int>{5, 10, 20, 50},
  'JPY': <int>{1000, 2000, 5000, 10000},
  'MXN': <int>{20, 50, 100, 200, 500, 1000},
  'THB': <int>{20, 50, 100, 500, 1000},
  'TRY': <int>{5, 10, 20, 50, 100, 200},
  'USD': <int>{1, 2, 5, 10, 20, 50, 100},
};

/// Monedas con foto, por divisa (en la unidad pequeña: 50 = 50 céntimos).
const Map<String, Set<int>> coinPhotos = <String, Set<int>>{
  'AUD': <int>{5, 10, 20, 50, 100, 200},
  'CAD': <int>{5, 10, 25, 100, 200},
  'CHF': <int>{5, 10, 20, 50, 100, 200, 500},
  'CNY': <int>{10, 50, 100},
  'EUR': <int>{1, 2, 5, 10, 20, 50, 100, 200},
  'GBP': <int>{1, 2, 5, 10, 20, 50, 100, 200},
  'JPY': <int>{1, 5, 10, 50, 100, 500},
  'MXN': <int>{50, 100, 200, 500, 1000},
  'THB': <int>{25, 50, 100, 200, 500, 1000},
  'TRY': <int>{1, 5, 10, 25, 50, 100},
  'USD': <int>{1, 5, 10, 25, 50, 100},
};

/// La ruta de la foto de un billete, o null si no tenemos foto.
String? notePhoto(String currency, int value) =>
    notePhotos[currency]?.contains(value) ?? false
    ? 'assets/divisas/${currency.toLowerCase()}/b-$value.webp'
    : null;

/// La ruta de la foto de una moneda, o null si no tenemos foto.
String? coinPhoto(String currency, int minor) =>
    coinPhotos[currency]?.contains(minor) ?? false
    ? 'assets/divisas/${currency.toLowerCase()}/m-$minor.webp'
    : null;
