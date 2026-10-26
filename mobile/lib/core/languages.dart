// Nombre de cada idioma escrito EN ESE idioma ("Deutsch", "日本語"...): así
// cualquiera encuentra el suyo aunque la app esté en un idioma que no entiende.
//
// Esto no es una traducción de la interfaz: es un dato fijo, igual en todos
// los idiomas. Si falta un idioma aquí, se muestra su código (p. ej. "sw").
const Map<String, String> languageEndonyms = <String, String>{
  'ar': 'العربية',
  'bn': 'বাংলা',
  'de': 'Deutsch',
  'en': 'English',
  'es': 'Español',
  'fa': 'فارسی',
  'fil': 'Filipino',
  'fr': 'Français',
  'hi': 'हिन्दी',
  'id': 'Bahasa Indonesia',
  'it': 'Italiano',
  'ja': '日本語',
  'ko': '한국어',
  'ms': 'Bahasa Melayu',
  'nl': 'Nederlands',
  'pl': 'Polski',
  'pt': 'Português',
  'ro': 'Română',
  'ru': 'Русский',
  'th': 'ไทย',
  'tr': 'Türkçe',
  'uk': 'Українська',
  'ur': 'اردو',
  'vi': 'Tiếng Việt',
  'zh': '中文',
};

String endonymFor(String languageCode) =>
    languageEndonyms[languageCode] ?? languageCode;
