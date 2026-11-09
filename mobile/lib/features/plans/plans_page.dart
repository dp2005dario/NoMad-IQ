// Lo que la app le da a la página "Elegid planes" (la maqueta "Planes", en
// assets/plans/planes.html): las caras del grupo, las tarjetas que te
// quedan por votar, vuestros match y lo que has marcado en secreto.
//
// Los votos son SECRETOS: del resto del grupo solo llega si ya ha votado y,
// cuando coincidís, con quién. Dart puro: se prueba sin WebView.
import 'dart:convert';

import '../group/group_page.dart' show faceColors;
import 'plans_api.dart';

/// Dónde está la página y la marca donde la app mete sus datos.
const String plansPage = 'assets/plans/planes.html';
const String plansMarker = '/*ECLIPTA*/{}';

/// "Tú, Marta y Álex".
String joinNames(List<String> names) => names.length < 2
    ? names.join()
    : '${names.sublist(0, names.length - 1).join(', ')} y ${names.last}';

/// Un plan para la página. [n] elige el dibujo si no tiene foto.
Map<String, Object?> planJson(GroupPlan p, int n, {String? city}) =>
    <String, Object?>{
      'id': p.id,
      'n': n,
      'title': p.title,
      'meta': p.note ?? '',
      // Las ideas de la ciudad se añaden solas (a tu nombre), así que se
      // mira primero si vienen de la ficha.
      'why': p.wikidataId != null
          ? 'Idea de la ficha de ${city ?? 'la ciudad'}'
          : p.mine
          ? 'Lo propusiste tú'
          : 'Lo propuso alguien del grupo',
      'tags': <String>[if (p.wikidataId != null) 'Idea de la ciudad'],
      'img': p.photoUrl?.toString() ?? '',
      'who': p.matchWith,
      'planned': p.planned,
    };

/// Todo lo que necesita la página. [again] = "Volver a empezar" (vuelven
/// todas las tarjetas menos las que ya has vuelto a votar, [revoted]).
Map<String, Object?> plansPageData({
  required String? city,
  PlanBoard? board,
  bool failed = false,
  bool signedOut = false,
  bool again = false,
  Set<String> revoted = const <String>{},
}) {
  final List<GroupPlan> plans = board?.plans ?? const <GroupPlan>[];
  int n(GroupPlan p) => plans.indexOf(p);
  final List<GroupPlan> deck = again
      ? plans.where((GroupPlan p) => !revoted.contains(p.id)).toList()
      : (board?.pending ?? const <GroupPlan>[]);
  final List<PlanPerson> people = board?.people ?? const <PlanPerson>[];
  final List<String> missing = <String>[
    for (final PlanPerson p in people)
      if (!p.me && !p.voted) p.name,
  ];
  return <String, Object?>{
    'sub':
        '${city == null || city.isEmpty ? 'Vuestro viaje' : city} · '
        'derecha: me apetece · izquierda: paso',
    'total': plans.length,
    'people': <Map<String, Object?>>[
      for (int i = 0; i < people.length; i++)
        <String, Object?>{
          'i': people[i].me
              ? 'TÚ'
              : String.fromCharCodes(people[i].name.trim().runes.take(1))
                    .toUpperCase(),
          'name': people[i].me ? 'Tú' : people[i].name,
          'me': people[i].me,
          'on': people[i].voted,
          'c': faceColors[i % faceColors.length],
        },
    ],
    'cards': <Map<String, Object?>>[
      for (final GroupPlan p in deck) planJson(p, n(p), city: city),
    ],
    'matched': <Map<String, Object?>>[
      for (final GroupPlan p in plans)
        if (p.myMatch) planJson(p, n(p), city: city),
    ],
    'waiting': <Map<String, Object?>>[
      for (final GroupPlan p in plans)
        if (p.myVote == true && !p.myMatch) planJson(p, n(p), city: city),
    ],
    'loading': board == null && !failed && !signedOut ? 'Cargando…' : '',
    'note': signedOut
        ? 'Entra con tu cuenta para votar los planes del grupo.'
        : failed
        ? 'No he podido traer los planes. Comprueba la conexión y vuelve a entrar.'
        : board == null
        ? 'Buscando los planes del grupo…'
        : plans.isEmpty
        ? 'Aún no hay planes para votar. Cuando alguien del grupo añada uno, saldrá aquí.'
        : missing.isNotEmpty
        ? '${joinNames(missing)} aún no ${missing.length == 1 ? 'ha' : 'han'} '
              'entrado. Si al entrar ${missing.length == 1 ? 'marca' : 'marcan'} '
              'lo mismo que tú, saltará el match.'
        : 'Ya habéis votado todos. Cuando coincidáis en algo, saltará el match.',
  };
}

/// La página lista para enseñar.
String plansPageWith(String page, Map<String, Object?> data) =>
    // "<" como \u003c: ningún dato puede cerrar el script.
    page.replaceFirst(plansMarker, jsonEncode(data).replaceAll('<', r'\u003c'));

/// Lo que se le manda a la página sin recargarla.
String plansPushScript(Map<String, Object?> data) =>
    'window.ECLin&&window.ECLin(${jsonEncode(data).replaceAll('<', r'\u003c')})';
