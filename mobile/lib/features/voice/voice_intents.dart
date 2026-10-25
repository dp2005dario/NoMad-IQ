// "Habla con Flyra": qué quieres hacer, a partir de lo que dijiste.
//
// Se decide DENTRO del móvil con palabras clave por idioma (rápido, gratis y
// privado: tu vuelo o tu hotel nunca salen del teléfono). Si no encaja con
// nada, la pregunta va al chat de Flyra (el servidor, con su cupo diario).
//
// ¿Por qué palabras clave y no una IA para todo? Porque el 80 % de lo que se
// pregunta en un viaje es siempre lo mismo ("¿a qué hora sale mi avión?",
// "llévame al hotel"), y eso se responde al instante y sin gastar nada.

/// Lo que se puede hacer con la voz.
enum VoiceIntent {
  flight,
  hotel,
  money,
  visa,
  language,
  sos,
  nearby,
  translate,
  meetups,
  drive,
  trouble,
}

/// Quita tildes y mayúsculas: "Cuánto" y "cuanto" son lo mismo.
String normalizeSpeech(String text) {
  const String from = 'áàâäãåéèêëíìîïóòôöõúùûüñçœß';
  const String to = 'aaaaaaeeeeiiiiooooouuuuncos';
  final StringBuffer out = StringBuffer();
  for (final int rune in text.toLowerCase().runes) {
    final String ch = String.fromCharCode(rune);
    final int i = from.indexOf(ch);
    out.write(i >= 0 ? to[i] : ch);
  }
  return out.toString();
}

/// Palabras clave por idioma (ya sin tildes). El orden de los intentos
/// importa: el primero que encaje gana (SOS va primero, y los problemas
/// antes que el vuelo).
const Map<VoiceIntent, Map<String, List<String>>>
_keywords = <VoiceIntent, Map<String, List<String>>>{
  VoiceIntent.sos: <String, List<String>>{
    'es': <String>['emergencia', 'socorro', 'ambulancia', 'policia', 'sos'],
    'en': <String>['emergency', 'ambulance', 'police', 'sos'],
    'fr': <String>['urgence', 'au secours', 'ambulance', 'police', 'sos'],
    'de': <String>['notfall', 'notruf', 'krankenwagen', 'polizei', 'sos'],
    'it': <String>['emergenza', 'aiuto', 'ambulanza', 'polizia', 'sos'],
    'pt': <String>['emergencia', 'socorro', 'ambulancia', 'policia', 'sos'],
    'ar': <String>['طوارئ', 'النجدة', 'اسعاف', 'إسعاف', 'شرطة'],
    'zh': <String>['紧急', '救命', '救护车', '警察'],
    'ja': <String>['緊急', '助けて', '救急車', '警察'],
    'hi': <String>['आपातकाल', 'बचाओ', 'एम्बुलेंस', 'पुलिस'],
  },
  // Antes que "vuelo": "perdí el vuelo" es un problema, no la hora.
  VoiceIntent.trouble: <String, List<String>>{
    'es': <String>['maleta', 'equipaje', 'perdi el vuelo', 'escala'],
    'en': <String>[
      'suitcase',
      'luggage',
      'baggage',
      'missed my flight',
      'missed connection',
    ],
    'fr': <String>['valise', 'bagage', 'rate mon vol', 'correspondance'],
    'de': <String>['koffer', 'gepack', 'flug verpasst', 'anschluss'],
    'it': <String>['valigia', 'bagaglio', 'perso il volo', 'coincidenza'],
    'pt': <String>['mala', 'bagagem', 'perdi o voo', 'ligacao'],
    'ar': <String>['حقيبة', 'أمتعة'],
    'zh': <String>['行李', '转机'],
    'ja': <String>['荷物', 'スーツケース', '乗り継ぎ'],
    'hi': <String>['सामान', 'बैग'],
  },
  VoiceIntent.flight: <String, List<String>>{
    'es': <String>['vuelo', 'avion', 'embarque', 'puerta de embarque'],
    'en': <String>['flight', 'plane', 'boarding', 'gate'],
    'fr': <String>['vol', 'avion', 'embarquement'],
    'de': <String>['flug', 'flugzeug', 'boarding', 'gate'],
    'it': <String>['volo', 'aereo', 'imbarco', 'gate'],
    'pt': <String>['voo', 'aviao', 'embarque'],
    'ar': <String>['رحلتي', 'الطائرة', 'طائرتي', 'الصعود', 'البوابة'],
    'zh': <String>['航班', '飞机', '登机'],
    'ja': <String>['フライト', '飛行機', '搭乗', '便'],
    'hi': <String>['उड़ान', 'फ्लाइट', 'विमान', 'बोर्डिंग'],
  },
  VoiceIntent.hotel: <String, List<String>>{
    'es': <String>['hotel', 'alojamiento', 'apartamento'],
    'en': <String>['hotel', 'accommodation', 'apartment'],
    'fr': <String>['hotel', 'logement', 'appartement'],
    'de': <String>['hotel', 'unterkunft', 'wohnung'],
    'it': <String>['hotel', 'albergo', 'alloggio'],
    'pt': <String>['hotel', 'alojamento', 'hospedagem'],
    'ar': <String>['الفندق', 'فندق', 'السكن'],
    'zh': <String>['酒店', '宾馆', '住处'],
    'ja': <String>['ホテル', '宿'],
    'hi': <String>['होटल'],
  },
  VoiceIntent.money: <String, List<String>>{
    'es': <String>[
      'gastado',
      'gasto',
      'gastos',
      'dinero',
      'presupuesto',
      'debe',
    ],
    'en': <String>['spent', 'spend', 'expenses', 'money', 'budget', 'owe'],
    'fr': <String>['depense', 'argent', 'budget', 'doit'],
    'de': <String>['ausgegeben', 'ausgaben', 'geld', 'budget', 'schuldet'],
    'it': <String>['speso', 'spese', 'soldi', 'budget', 'deve'],
    'pt': <String>['gasto', 'gastamos', 'dinheiro', 'orcamento', 'deve'],
    'ar': <String>['أنفقنا', 'المصاريف', 'المال', 'الميزانية'],
    'zh': <String>['花了', '花费', '钱', '预算'],
    'ja': <String>['使った', '出費', 'お金', '予算'],
    'hi': <String>['खर्च', 'पैसे', 'बजट'],
  },
  VoiceIntent.visa: <String, List<String>>{
    'es': <String>['visado', 'visa', 'esta', 'pasaporte'],
    'en': <String>['visa', 'esta', 'passport', 'entry requirement'],
    'fr': <String>['visa', 'passeport'],
    'de': <String>['visum', 'reisepass', 'einreise'],
    'it': <String>['visto', 'passaporto'],
    'pt': <String>['visto', 'passaporte'],
    'ar': <String>['تأشيرة', 'جواز'],
    'zh': <String>['签证', '护照'],
    'ja': <String>['ビザ', '査証', 'パスポート'],
    'hi': <String>['वीज़ा', 'वीजा', 'पासपोर्ट'],
  },
  VoiceIntent.language: <String, List<String>>{
    'es': <String>['idioma', 'lengua'],
    'en': <String>['language'],
    'fr': <String>['langue'],
    'de': <String>['sprache'],
    'it': <String>['lingua'],
    'pt': <String>['idioma', 'lingua'],
    'ar': <String>['اللغة'],
    'zh': <String>['语言'],
    'ja': <String>['言語'],
    'hi': <String>['भाषा'],
  },
  VoiceIntent.translate: <String, List<String>>{
    'es': <String>['traduce', 'traducir', 'como se dice', 'interprete'],
    'en': <String>['translate', 'how do you say', 'interpreter'],
    'fr': <String>['traduis', 'traduire', 'comment dit-on', 'interprete'],
    'de': <String>['ubersetze', 'ubersetzen', 'wie sagt man', 'dolmetscher'],
    'it': <String>['traduci', 'tradurre', 'come si dice', 'interprete'],
    'pt': <String>['traduz', 'traduzir', 'como se diz', 'interprete'],
    'ar': <String>['ترجم', 'كيف أقول'],
    'zh': <String>['翻译', '怎么说'],
    'ja': <String>['翻訳', '通訳', 'なんて言う'],
    'hi': <String>['अनुवाद', 'कैसे कहते'],
  },
  VoiceIntent.nearby: <String, List<String>>{
    'es': <String>['agua', 'bano', 'aseo', 'wifi', 'cargar el movil'],
    'en': <String>[
      'water',
      'toilet',
      'restroom',
      'bathroom',
      'wifi',
      'charge my phone',
    ],
    'fr': <String>['eau', 'toilettes', 'wifi', 'recharger'],
    'de': <String>['wasser', 'toilette', 'wlan', 'wifi', 'aufladen'],
    'it': <String>['acqua', 'bagno', 'wifi', 'ricaricare'],
    'pt': <String>['agua', 'banheiro', 'casa de banho', 'wifi', 'carregar'],
    'ar': <String>['ماء', 'حمام', 'مرحاض', 'واي فاي'],
    'zh': <String>['水', '厕所', '洗手间', '无线网'],
    'ja': <String>['水', 'トイレ', 'ワイファイ', '充電'],
    'hi': <String>['पानी', 'शौचालय', 'वाईफाई', 'चार्ज'],
  },
  VoiceIntent.meetups: <String, List<String>>{
    'es': <String>['quedada', 'conocer gente', 'viajeros'],
    'en': <String>['meetup', 'meet people', 'travellers', 'travelers'],
    'fr': <String>['rencontre', 'voyageurs'],
    'de': <String>['treffen', 'leute kennenlernen', 'reisende'],
    'it': <String>['incontro', 'conoscere gente', 'viaggiatori'],
    'pt': <String>['encontro', 'conhecer pessoas', 'viajantes'],
    'ar': <String>['لقاء', 'مسافرين'],
    'zh': <String>['聚会', '旅友'],
    'ja': <String>['ミートアップ', '旅行者'],
    'hi': <String>['मुलाकात', 'यात्री'],
  },
  VoiceIntent.drive: <String, List<String>>{
    'es': <String>['gasolina', 'gasolinera', 'aparcar', 'parking', 'ztl'],
    'en': <String>['petrol', 'gas station', 'fuel', 'parking', 'park the car'],
    'fr': <String>['essence', 'station-service', 'se garer', 'parking'],
    'de': <String>['tanken', 'tankstelle', 'parken', 'parkplatz'],
    'it': <String>['benzina', 'distributore', 'parcheggio', 'ztl'],
    'pt': <String>['gasolina', 'combustivel', 'estacionar', 'estacionamento'],
    'ar': <String>['بنزين', 'وقود', 'موقف'],
    'zh': <String>['加油', '停车'],
    'ja': <String>['ガソリン', '駐車'],
    'hi': <String>['पेट्रोल', 'पार्किंग'],
  },
};

/// El intento de [text] (en el idioma [lang]), o null si no se sabe: entonces
/// se le pregunta a Flyra. También prueba el inglés (mucha gente lo mezcla).
VoiceIntent? matchIntent(String text, String lang) {
  final String said = ' ${normalizeSpeech(text)} ';
  for (final MapEntry<VoiceIntent, Map<String, List<String>>> e
      in _keywords.entries) {
    final List<String> words = <String>[
      ...?e.value[lang],
      if (lang != 'en') ...?e.value['en'],
    ];
    for (final String w in words) {
      // Palabras latinas: tiene que ser la palabra entera ("vol" no vale
      // dentro de "volver"). En chino, japonés, árabe o hindi, basta con
      // que aparezca.
      final bool latin = RegExp(r'^[a-z0-9 \-]+$').hasMatch(w);
      if (latin
          ? RegExp('(^|[^a-z])${RegExp.escape(w)}([^a-z]|\$)').hasMatch(said)
          : said.contains(w)) {
        return e.key;
      }
    }
  }
  return null;
}
