// "¿Cubre la maleta perdida?": buscar en el texto de la póliza del seguro.
//
// No hay ninguna IA aquí (para que la póliza no salga del móvil): se buscan
// las frases de la póliza que hablan del tema, con palabras clave en los
// idiomas en los que suelen venir las pólizas (español, inglés, francés,
// alemán, italiano y portugués). Se enseñan las mejores frases con su
// página, y se marcan las que parecen una EXCLUSIÓN ("queda excluido...").
// Lo que vale es la póliza: la app lo dice siempre.

/// Los temas que se pueden preguntar con un toque.
enum PolicyTopic { luggage, medical, cancellation, delay, theft, sports }

/// Raíces de palabras (sin tildes y en minúsculas) por tema.
const Map<PolicyTopic, List<String>> topicWords = <PolicyTopic, List<String>>{
  PolicyTopic.luggage: <String>[
    'equipaje',
    'maleta',
    'luggage',
    'baggage',
    'bagage',
    'valise',
    'gepack',
    'koffer',
    'bagagli',
    'valigi',
    'bagagem',
    'mala ',
  ],
  PolicyTopic.medical: <String>[
    'medic',
    'hospital',
    'sanitari',
    'enfermedad',
    'illness',
    'sickness',
    'maladie',
    'krank',
    'arzt',
    'malattia',
    'doenca',
    'urgenc',
    'emergency',
  ],
  PolicyTopic.cancellation: <String>[
    'anulacion',
    'cancelacion',
    'cancel',
    'annulation',
    'storno',
    'rucktritt',
    'annullamento',
    'disdetta',
  ],
  PolicyTopic.delay: <String>[
    'retraso',
    'demora',
    'delay',
    'retard',
    'verspatung',
    'ritardo',
    'atraso',
    'conexion perdida',
    'missed connection',
  ],
  PolicyTopic.theft: <String>[
    'robo',
    'hurto',
    'theft',
    'stolen',
    'vol ',
    'diebstahl',
    'furto',
    'roubo',
  ],
  PolicyTopic.sports: <String>[
    'deporte',
    'esqui',
    'nieve',
    'sport',
    'ski',
    'snowboard',
    'buceo',
    'diving',
    'plongee',
    'tauchen',
    'immersion',
    'mergulho',
    'escalada',
    'climbing',
  ],
};

/// Palabras que suelen anunciar una exclusión.
const List<String> exclusionWords = <String>[
  'exclu',
  'no cubre',
  'no cubiert',
  'no estan cubiert',
  'not covered',
  'except',
  'ausgeschlossen',
  'nicht versichert',
  'esclus',
  'non copert',
  'nao cobre',
  'non couvert',
];

/// Palabras vacías que no sirven para buscar ("el", "the", "pour"...).
const Set<String> _stop = <String>{
  'para',
  'pero',
  'como',
  'esta',
  'este',
  'esto',
  'tengo',
  'puedo',
  'cubre',
  'seguro',
  'poliza',
  'what',
  'does',
  'with',
  'from',
  'that',
  'this',
  'have',
  'cover',
  'covered',
  'pour',
  'avec',
  'dans',
  'est-ce',
  'wird',
  'nicht',
  'sind',
  'eine',
  'della',
  'sono',
  'cosa',
  'quando',
  'cuando',
  'donde',
};

class PolicyHit {
  const PolicyHit({
    required this.page,
    required this.text,
    required this.exclusion,
    required this.score,
  });

  /// Página (empezando en 1).
  final int page;

  /// La frase tal cual está en la póliza (recortada si es muy larga).
  final String text;

  /// ¿Parece que dice que NO está cubierto?
  final bool exclusion;
  final int score;
}

/// Quita tildes y pasa a minúsculas: "Equipaje Facturado" = "equipaje facturado".
String fold(String s) {
  const String from = 'áàäâãåéèëêíìïîóòöôõúùüûñçß';
  const String to = 'aaaaaaeeeeiiiiooooouuuuncs';
  final StringBuffer out = StringBuffer();
  for (final int r in s.toLowerCase().runes) {
    final String c = String.fromCharCode(r);
    final int i = from.indexOf(c);
    out.write(i < 0 ? c : to[i]);
  }
  return out.toString();
}

/// Las palabras útiles de una pregunta escrita por la persona.
List<String> questionWords(String question) => <String>[
  for (final String w in fold(question).split(RegExp(r'[^a-z0-9]+')))
    if (w.length >= 4 && !_stop.contains(w))
      // Se queda la raíz (las 6 primeras letras) para que "maletas" encuentre
      // "maleta" y "cancelling" encuentre "cancelación".
      w.length > 6 ? w.substring(0, 6) : w,
];

/// Las mejores frases de la póliza para un tema o unas palabras.
List<PolicyHit> searchPolicy(
  List<String> pages,
  List<String> words, {
  int limit = 3,
}) {
  if (words.isEmpty) return const <PolicyHit>[];
  final List<PolicyHit> hits = <PolicyHit>[];
  for (int p = 0; p < pages.length; p++) {
    // Frases: se corta por punto, punto y coma o línea en blanco.
    for (final String raw in pages[p].split(RegExp(r'(?<=[.;:])\s+|\n\s*\n'))) {
      final String sentence = raw.replaceAll(RegExp(r'\s+'), ' ').trim();
      if (sentence.length < 25) continue;
      final String f = fold(sentence);
      int score = 0;
      for (final String w in words) {
        if (f.contains(w)) score += 3;
      }
      if (score == 0) continue;
      // Las frases con un importe ("1.200 €", "EUR 3,000") suelen ser la respuesta.
      if (RegExp(r'\d[\d.,]*\s?(€|eur|usd|\$|£|chf)|(€|eur|\$|£)\s?\d')
          .hasMatch(f)) {
        score += 2;
      }
      hits.add(
        PolicyHit(
          page: p + 1,
          text: sentence.length > 320
              ? '${sentence.substring(0, 317)}…'
              : sentence,
          exclusion: exclusionWords.any(f.contains),
          score: score,
        ),
      );
    }
  }
  hits.sort((PolicyHit a, PolicyHit b) => b.score.compareTo(a.score));
  return hits.take(limit).toList();
}
