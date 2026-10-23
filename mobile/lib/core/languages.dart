// Nombre de cada idioma escrito EN ESE idioma ("Deutsch", "日本語"...): así
// cualquiera encuentra el suyo aunque la app esté en un idioma que no entiende.
//
// Esto no es una traducción de la interfaz: es un dato fijo, igual en todos
// los idiomas. Si falta un idioma aquí, se muestra su código (p. ej. "sw").
const Map<String, String> languageEndonyms = <String, String>{
  'ar': 'العربية',
  'de': 'Deutsch',
  'en': 'English',
  'es': 'Español',
  'fr': 'Français',
  'hi': 'हिन्दी',
  'it': 'Italiano',
  'ja': '日本語',
  'pt': 'Português',
  'zh': '中文',
};

String endonymFor(String languageCode) =>
    languageEndonyms[languageCode] ?? languageCode;
