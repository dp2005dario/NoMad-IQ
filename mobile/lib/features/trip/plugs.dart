// Qué enchufe y qué corriente hay en cada país, para la lista de la maleta.
//
// Es un dato fijo (no cambia de un día para otro) y así funciona sin
// Internet. Si un país no está en la tabla, la app dice que lo compruebes
// en vez de inventarlo.
class Power {
  const Power(this.plugs, this.volts);

  /// Letras del tipo de enchufe ("A/B", "C/F", "G"...).
  final String plugs;

  /// Tensión de la red: 110-127 V o 220-240 V.
  final int volts;

  /// ¿Hace falta adaptador viniendo de un país con [other]?
  bool needsAdapterFrom(Power other) =>
      plugs.split('/').every((String p) => !other.plugs.split('/').contains(p));

  /// ¿Hace falta transformador? (un aparato de 110 V en un país de 230 V).
  bool needsTransformerFrom(Power other) => (volts - other.volts).abs() > 60;
}

/// De dónde salen los datos: la tabla "Mains electricity by country" de
/// Wikipedia, basada en la guía oficial IEC World Plugs (de la Comisión
/// Electrotécnica Internacional). Comprobada el 25-10-2026. La app enseña
/// este enlace junto al enchufe para que cualquiera lo pueda verificar.
const String powerSource =
    'https://en.wikipedia.org/wiki/Mains_electricity_by_country';

/// Enchufe y tensión por país (código ISO de dos letras).
const Map<String, Power> powerByCountry = <String, Power>{
  'AE': Power('G', 230),
  'AR': Power('C/I', 220),
  'AT': Power('C/F', 230),
  'AU': Power('I', 230),
  'BE': Power('C/E', 230),
  'BG': Power('C/F', 230),
  'BR': Power('C/N', 127),
  'CA': Power('A/B', 120),
  'CH': Power('C/J', 230),
  'CL': Power('C/F/L', 220),
  'CN': Power('A/I', 220),
  'CO': Power('A/B', 120),
  'CZ': Power('C/E', 230),
  'DE': Power('C/F', 230),
  'DK': Power('C/E/F/K', 230),
  'EE': Power('C/F', 230),
  'EG': Power('C/F', 220),
  'ES': Power('C/F', 230),
  'FI': Power('C/F', 230),
  'FR': Power('C/E', 230),
  'GB': Power('G', 230),
  'GR': Power('C/F', 230),
  'HK': Power('G', 220),
  'HR': Power('C/F', 230),
  'HU': Power('C/F', 230),
  'ID': Power('C/F', 230),
  'IE': Power('G', 230),
  'IL': Power('C/H', 230),
  'IN': Power('C/D/M', 230),
  'IS': Power('C/F', 230),
  'IT': Power('C/F/L', 230),
  'JP': Power('A/B', 100),
  'KR': Power('C/F', 220),
  'LT': Power('C/F', 230),
  'LU': Power('C/F', 230),
  'LV': Power('C/F', 230),
  'MA': Power('C/E', 220),
  'MX': Power('A/B', 127),
  'MY': Power('C/G/M', 230),
  'NL': Power('C/F', 230),
  'NO': Power('C/F', 230),
  'NZ': Power('I', 230),
  'PE': Power('A/B/C', 220),
  'PH': Power('A/B/C', 230),
  'PL': Power('C/E', 230),
  'PT': Power('C/E/F', 230),
  'QA': Power('D/F/G/L', 240),
  'RO': Power('C/F', 230),
  'RS': Power('C/F', 230),
  'SA': Power('G', 230),
  'SE': Power('C/F', 230),
  'SG': Power('C/G/M', 230),
  'SI': Power('C/F', 230),
  'SK': Power('C/E/F', 230),
  'TH': Power('A/B/C/O', 230),
  'TR': Power('C/F', 230),
  'TW': Power('A/B', 110),
  'US': Power('A/B', 120),
  'VN': Power('A/B/C/F', 220),
  'ZA': Power('C/M/N', 230),
};

Power? powerOf(String? isoCountry) =>
    isoCountry == null ? null : powerByCountry[isoCountry.toUpperCase()];

/// Países donde tu tarifa móvil europea funciona sin coste extra ("roam like
/// at home"): la UE más Islandia, Liechtenstein y Noruega.
const Set<String> freeRoamingEea = <String>{
  'AT',
  'BE',
  'BG',
  'HR',
  'CY',
  'CZ',
  'DK',
  'EE',
  'FI',
  'FR',
  'DE',
  'GR',
  'HU',
  'IE',
  'IT',
  'LV',
  'LT',
  'LU',
  'MT',
  'NL',
  'PL',
  'PT',
  'RO',
  'SK',
  'SI',
  'ES',
  'SE',
  'IS',
  'LI',
  'NO',
};
