// Los números de emergencia de cada país y cómo se dice "¡Ayuda!" allí.
//
// Van dentro de la app: en un apuro puede no haber Internet. Fuentes: las
// webs oficiales de emergencias de cada país y la lista de la UE (112).
// Si un país no está en la tabla, se usa el 112: los móviles GSM lo
// desvían al número local en la mayor parte del mundo.

/// Los teléfonos de un país. [general] siempre existe; los demás solo si el
/// país tiene uno distinto para eso.
class EmergencyNumbers {
  const EmergencyNumbers(
    this.general, {
    this.police,
    this.ambulance,
    this.fire,
  });

  final String general;
  final String? police;
  final String? ambulance;
  final String? fire;
}

const EmergencyNumbers _eu = EmergencyNumbers('112');
const EmergencyNumbers fallbackNumbers = EmergencyNumbers('112');

const Map<String, EmergencyNumbers>
emergencyNumbers = <String, EmergencyNumbers>{
  // Unión Europea y vecinos: el 112 vale para todo.
  'AT': _eu, 'BE': _eu, 'BG': _eu, 'HR': _eu, 'CY': _eu, 'CZ': _eu,
  'DK': _eu, 'EE': _eu, 'FI': _eu, 'FR': _eu, 'DE': _eu, 'GR': _eu,
  'HU': _eu, 'IE': _eu, 'IT': _eu, 'LV': _eu, 'LT': _eu, 'LU': _eu,
  'MT': _eu, 'NL': _eu, 'PL': _eu, 'PT': _eu, 'RO': _eu, 'SK': _eu,
  'SI': _eu, 'ES': _eu, 'SE': _eu, 'IS': _eu, 'TR': _eu, 'RU': _eu,
  'UA': _eu, 'IN': _eu,
  'NO': EmergencyNumbers('112', police: '112', ambulance: '113', fire: '110'),
  'CH': EmergencyNumbers('112', police: '117', ambulance: '144', fire: '118'),
  'GB': EmergencyNumbers('999'),
  // América
  'US': EmergencyNumbers('911'), 'CA': EmergencyNumbers('911'),
  'MX': EmergencyNumbers('911'), 'CR': EmergencyNumbers('911'),
  'PA': EmergencyNumbers('911'), 'DO': EmergencyNumbers('911'),
  'EC': EmergencyNumbers('911'), 'UY': EmergencyNumbers('911'),
  'VE': EmergencyNumbers('911'), 'PY': EmergencyNumbers('911'),
  'AR': EmergencyNumbers('911', ambulance: '107', fire: '100'),
  'BR': EmergencyNumbers('190', police: '190', ambulance: '192', fire: '193'),
  'CL': EmergencyNumbers('133', police: '133', ambulance: '131', fire: '132'),
  'CO': EmergencyNumbers('123'),
  'PE': EmergencyNumbers('105', police: '105', ambulance: '106', fire: '116'),
  'BO': EmergencyNumbers('110', police: '110', ambulance: '118', fire: '119'),
  'CU': EmergencyNumbers('106', police: '106', ambulance: '104', fire: '105'),
  // Asia y Oceanía
  'JP': EmergencyNumbers('110', police: '110', ambulance: '119', fire: '119'),
  'CN': EmergencyNumbers('110', police: '110', ambulance: '120', fire: '119'),
  'HK': EmergencyNumbers('999'),
  'TW': EmergencyNumbers('110', police: '110', ambulance: '119', fire: '119'),
  'KR': EmergencyNumbers('112', police: '112', ambulance: '119', fire: '119'),
  'TH': EmergencyNumbers('191', police: '191', ambulance: '1669', fire: '199'),
  'VN': EmergencyNumbers('113', police: '113', ambulance: '115', fire: '114'),
  'ID': EmergencyNumbers('112'),
  'PH': EmergencyNumbers('911'),
  'MY': EmergencyNumbers('999'),
  'SG': EmergencyNumbers('999', police: '999', ambulance: '995', fire: '995'),
  'AU': EmergencyNumbers('000'),
  'NZ': EmergencyNumbers('111'),
  // Oriente Medio y África
  'AE': EmergencyNumbers('999', police: '999', ambulance: '998', fire: '997'),
  'SA': EmergencyNumbers('911'),
  'IL': EmergencyNumbers('100', police: '100', ambulance: '101', fire: '102'),
  'EG': EmergencyNumbers('122', police: '122', ambulance: '123', fire: '180'),
  'MA': EmergencyNumbers('19', police: '19', ambulance: '15', fire: '15'),
  'ZA': EmergencyNumbers('10111', police: '10111', ambulance: '10177'),
  'KE': EmergencyNumbers('999'),
};

EmergencyNumbers numbersFor(String? country) =>
    emergencyNumbers[country] ?? fallbackNumbers;

/// Cómo se pide ayuda: lo que se ve escrito y cómo se pronuncia (si se
/// escribe con otro alfabeto).
class HelpPhrase {
  const HelpPhrase(this.text, [this.sounds]);

  final String text;
  final String? sounds;
}

const Map<String, HelpPhrase> helpPhrases = <String, HelpPhrase>{
  'es': HelpPhrase('¡Ayuda!'),
  'en': HelpPhrase('Help!'),
  'fr': HelpPhrase('Au secours !'),
  'de': HelpPhrase('Hilfe!'),
  'it': HelpPhrase('Aiuto!'),
  'pt': HelpPhrase('Socorro!'),
  'nl': HelpPhrase('Help!'),
  'ja': HelpPhrase('助けて！', 'Tasukete!'),
  'zh': HelpPhrase('救命！', 'Jiùmìng!'),
  'ko': HelpPhrase('도와주세요!', 'Dowajuseyo!'),
  'ar': HelpPhrase('النجدة!', 'An-najda!'),
  'hi': HelpPhrase('बचाओ!', 'Bachao!'),
  'ru': HelpPhrase('Помогите!', 'Pomogite!'),
  'uk': HelpPhrase('Допоможіть!', 'Dopomozhit!'),
  'tr': HelpPhrase('İmdat!'),
  'el': HelpPhrase('Βοήθεια!', 'Voítheia!'),
  'th': HelpPhrase('ช่วยด้วย!', 'Chuay duay!'),
  'vi': HelpPhrase('Cứu tôi với!'),
  'id': HelpPhrase('Tolong!'),
  'ms': HelpPhrase('Tolong!'),
  'pl': HelpPhrase('Pomocy!'),
  'cs': HelpPhrase('Pomoc!'),
  'sv': HelpPhrase('Hjälp!'),
  'da': HelpPhrase('Hjælp!'),
  'no': HelpPhrase('Hjelp!'),
  'fi': HelpPhrase('Apua!'),
  'he': HelpPhrase('!הצילו', 'Hatsilu!'),
  'sw': HelpPhrase('Msaada!'),
  'ro': HelpPhrase('Ajutor!'),
  'hu': HelpPhrase('Segítség!'),
};

/// El idioma principal de cada país (para la frase).
const Map<String, String> countryLanguage = <String, String>{
  'ES': 'es',
  'MX': 'es',
  'AR': 'es',
  'CO': 'es',
  'CL': 'es',
  'PE': 'es',
  'VE': 'es',
  'EC': 'es',
  'BO': 'es',
  'UY': 'es',
  'PY': 'es',
  'CU': 'es',
  'DO': 'es',
  'CR': 'es',
  'PA': 'es',
  'GT': 'es',
  'HN': 'es',
  'SV': 'es',
  'NI': 'es',
  'US': 'en',
  'GB': 'en',
  'IE': 'en',
  'CA': 'en',
  'AU': 'en',
  'NZ': 'en',
  'SG': 'en',
  'ZA': 'en',
  'PH': 'en',
  'FR': 'fr',
  'BE': 'fr',
  'LU': 'fr',
  'MC': 'fr',
  'SN': 'fr',
  'CI': 'fr',
  'DE': 'de',
  'AT': 'de',
  'CH': 'de',
  'IT': 'it',
  'SM': 'it',
  'PT': 'pt',
  'BR': 'pt',
  'AO': 'pt',
  'MZ': 'pt',
  'NL': 'nl',
  'JP': 'ja',
  'CN': 'zh',
  'TW': 'zh',
  'HK': 'zh',
  'KR': 'ko',
  'SA': 'ar',
  'AE': 'ar',
  'EG': 'ar',
  'MA': 'ar',
  'JO': 'ar',
  'QA': 'ar',
  'KW': 'ar',
  'OM': 'ar',
  'BH': 'ar',
  'TN': 'ar',
  'DZ': 'ar',
  'LB': 'ar',
  'IN': 'hi',
  'RU': 'ru',
  'UA': 'uk',
  'TR': 'tr',
  'GR': 'el',
  'CY': 'el',
  'TH': 'th',
  'VN': 'vi',
  'ID': 'id',
  'MY': 'ms',
  'PL': 'pl',
  'CZ': 'cs',
  'SE': 'sv',
  'DK': 'da',
  'NO': 'no',
  'FI': 'fi',
  'IL': 'he',
  'KE': 'sw',
  'TZ': 'sw',
  'RO': 'ro',
  'HU': 'hu',
};

HelpPhrase? phraseFor(String? country) => helpPhrases[countryLanguage[country]];
