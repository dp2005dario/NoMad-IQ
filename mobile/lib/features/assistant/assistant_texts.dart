// Los textos pequeños del intérprete que no dependen del idioma de la app:
// la bandera de cada idioma, su nombre en español y lo que lee la otra
// persona en SU mitad de la pantalla ("PARA LA OTRA PERSONA" y el saludo).
//
// Dart puro: se prueba sin pantalla.

/// Una bandera para cada idioma del intérprete (la del país donde más se
/// habla, como en la maqueta). Sin bandera: 🌐.
const Map<String, String> languageFlags = <String, String>{
  'en': '🇬🇧',
  'es': '🇪🇸',
  'fr': '🇫🇷',
  'de': '🇩🇪',
  'it': '🇮🇹',
  'pt': '🇵🇹',
  'ar': '🇲🇦',
  'zh': '🇨🇳',
  'ja': '🇯🇵',
  'hi': '🇮🇳',
  'ko': '🇰🇷',
  'th': '🇹🇭',
  'vi': '🇻🇳',
  'id': '🇮🇩',
  'ms': '🇲🇾',
  'tr': '🇹🇷',
  'ru': '🇷🇺',
  'uk': '🇺🇦',
  'pl': '🇵🇱',
  'nl': '🇳🇱',
  'el': '🇬🇷',
  'cs': '🇨🇿',
  'ro': '🇷🇴',
  'hu': '🇭🇺',
  'sv': '🇸🇪',
  'da': '🇩🇰',
  'fi': '🇫🇮',
  'no': '🇳🇴',
  'he': '🇮🇱',
  'tl': '🇵🇭',
  'sw': '🇰🇪',
  'bn': '🇧🇩',
  'ur': '🇵🇰',
  'fa': '🇮🇷',
};

/// El nombre de cada idioma en español ("Japonés"), como en la maqueta.
const Map<String, String> spanishLanguageNames = <String, String>{
  'en': 'Inglés',
  'es': 'Español',
  'fr': 'Francés',
  'de': 'Alemán',
  'it': 'Italiano',
  'pt': 'Portugués',
  'ar': 'Árabe',
  'zh': 'Chino',
  'ja': 'Japonés',
  'hi': 'Hindi',
  'ko': 'Coreano',
  'th': 'Tailandés',
  'vi': 'Vietnamita',
  'id': 'Indonesio',
  'ms': 'Malayo',
  'tr': 'Turco',
  'ru': 'Ruso',
  'uk': 'Ucraniano',
  'pl': 'Polaco',
  'nl': 'Neerlandés',
  'el': 'Griego',
  'cs': 'Checo',
  'ro': 'Rumano',
  'hu': 'Húngaro',
  'sv': 'Sueco',
  'da': 'Danés',
  'fi': 'Finés',
  'no': 'Noruego',
  'he': 'Hebreo',
  'tl': 'Tagalo',
  'sw': 'Suajili',
  'bn': 'Bengalí',
  'ur': 'Urdu',
  'fa': 'Persa',
};

/// Lo que lee la otra persona en su mitad: (cabecera, saludo). Los idiomas
/// que no están aquí lo leen en inglés (lo entiende casi todo el mundo).
const Map<String, (String, String)> otherSideTexts = <String, (String, String)>{
  'en': ('FOR THE OTHER PERSON', 'Hi! Just speak normally, I will translate.'),
  'es': ('PARA LA OTRA PERSONA', 'Hola. Habla con normalidad, yo traduzco.'),
  'fr': ('POUR L’AUTRE PERSONNE', 'Bonjour. Parlez normalement, je traduis.'),
  'de': (
    'FÜR DIE ANDERE PERSON',
    'Hallo! Sprechen Sie ganz normal, ich übersetze.',
  ),
  'it': ('PER L’ALTRA PERSONA', 'Ciao! Parla normalmente, traduco io.'),
  'pt': ('PARA A OUTRA PESSOA', 'Olá! Fale normalmente, eu traduzo.'),
  'ja': ('相手の方へ', 'こんにちは。普通に話してください。翻訳します。'),
  'ar': ('للشخص الآخر', 'مرحبا. تكلم بشكل عادي، سأترجم.'),
  'zh': ('给对方看', '你好。请正常说话，我来翻译。'),
  'ko': ('상대방에게', '안녕하세요. 평소처럼 말씀하세요. 제가 통역할게요.'),
};

/// La cabecera y el saludo para la otra persona, en su idioma.
(String, String) otherSide(String lang) =>
    otherSideTexts[lang] ?? otherSideTexts['en']!;

/// El nombre de un idioma para ti: en español si la app está en español;
/// si no, en su propio idioma ([native]).
String languageNameFor(
  String code,
  String appLang,
  Map<String, String> native,
) => appLang == 'es'
    ? spanishLanguageNames[code] ?? native[code] ?? code
    : native[code] ?? code;
