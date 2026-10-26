// De qué país es cada moneda, para enseñar su bandera y su nombre.
//
// Es la norma ISO 4217 (la lista oficial de monedas): "GBP" es del Reino
// Unido, "JPY" de Japón... El euro no es de un país sino de la zona euro:
// lleva la bandera de la UE.

/// La moneda → el país (código ISO de dos letras). Solo las que publica el
/// Banco Central Europeo (son las que tiene el conversor).
const Map<String, String> currencyCountry = <String, String>{
  'AUD': 'AU',
  'BGN': 'BG',
  'BRL': 'BR',
  'CAD': 'CA',
  'CHF': 'CH',
  'CNY': 'CN',
  'CZK': 'CZ',
  'DKK': 'DK',
  'GBP': 'GB',
  'HKD': 'HK',
  'HUF': 'HU',
  'IDR': 'ID',
  'ILS': 'IL',
  'INR': 'IN',
  'ISK': 'IS',
  'JPY': 'JP',
  'KRW': 'KR',
  'MXN': 'MX',
  'MYR': 'MY',
  'NOK': 'NO',
  'NZD': 'NZ',
  'PHP': 'PH',
  'PLN': 'PL',
  'RON': 'RO',
  'SEK': 'SE',
  'SGD': 'SG',
  'THB': 'TH',
  'TRY': 'TR',
  'USD': 'US',
  'ZAR': 'ZA',
};

/// La bandera como emoji: dos "letras regionales" seguidas ("GB" → 🇬🇧).
/// Así no hace falta ninguna imagen: el móvil ya sabe dibujarlas.
String flagOf(String isoCountry) {
  final String code = isoCountry.toUpperCase();
  if (!RegExp(r'^[A-Z]{2}$').hasMatch(code)) return '';
  return String.fromCharCodes(<int>[
    for (final int c in code.codeUnits) 0x1F1E6 + c - 0x41,
  ]);
}

/// La bandera de una moneda (🇪🇺 para el euro; vacío si no la sabemos).
String currencyFlag(String currency) => currency == 'EUR'
    ? flagOf('EU')
    : currencyCountry.containsKey(currency)
    ? flagOf(currencyCountry[currency]!)
    : '';
