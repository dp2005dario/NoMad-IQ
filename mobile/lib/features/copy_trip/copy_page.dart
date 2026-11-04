// Lo que la app le da a la página de "Copia este viaje" (la maqueta, en
// assets/copy_trip/copiar.html): los textos en tu idioma y los viajes que la
// gente ha PUBLICADO en el muro, con su autor, su texto, lo que pagó por cada
// cosa y sus estrellas de verdad. Dart puro: se prueba sin WebView.
import 'dart:convert';

import '../../core/money.dart';
import '../../l10n/generated/app_localizations.dart';
import 'shared_trip_api.dart';

/// Dónde está la página y la marca donde la app mete sus datos.
const String copyPage = 'assets/copy_trip/copiar.html';
const String copyMarker =
    '/*ECLIPTA*/{"lang":"es","t":{},"trips":[],"msg":"","retry":false,'
    '"toast":""}';

/// Los textos de la página (las claves que usa la página).
Map<String, String> copyTexts(AppLocalizations t) => <String, String>{
  'title': t.copyTitle,
  'sub': t.cpSub,
  'map1': t.cpMap1,
  'mapN': t.cpMapN('{n}'),
  'duration': t.cpDuration,
  'stops': t.cpStops,
  'cost': t.cpCost,
  'perDay': t.cpPerDay,
  'vote1': t.cpVote1,
  'votesN': t.cpVotesN('{n}'),
  'noVotes': t.cpNoVotes,
  'yourVote': t.cpYourVote('{n}'),
  'tapRate': t.cpTapRate,
  'yours': t.cpYours,
  'copy': t.cpCopy,
  'copied': t.cpCopied,
  'thanks1': t.cpThanks1,
  'thanksN': t.cpThanksN('{n}'),
  'copiedToast': t.cpCopiedToast,
  'routeTitle': t.cpRouteTitle,
  'routeBody': t.cpRouteBody('{list}'),
  'stop': t.cpStop('{n}'),
  'empty': t.cpEmpty,
  'ownRate': t.cpOwnRate,
  'retry': t.guideRetry,
  'close': t.exwClose,
};

/// El dibujo de la tarjeta según el destino: las seis ciudades que tienen
/// dibujo propio en la maqueta, y para las demás una ciudad genérica.
String illustrationFor(String destination) {
  final String d = destination.toLowerCase();
  bool has(String pattern) => RegExp(pattern).hasMatch(d);
  if (has('disney')) return 'disney';
  if (has(r'\bpar[ií]s\b|\bparigi\b|\bparijs\b')) return 'eiffel';
  if (has(r'\bbarcelon')) return 'sagrada';
  if (has(r'\brom[ae]?\b')) return 'coliseo';
  if (has(r'\blondr|\blondon\b|\blondyn')) return 'bigben';
  if (has(r'\bberl[ií]n')) return 'brandeburgo';
  return 'generic';
}

/// Un número fijo para cada nombre (el mismo siempre): elige los colores
/// del dibujo de su cara. No hay fotos de perfil: es solo un dibujo. El 7
/// es el logo de ECLIPTA en la maqueta, así que se salta.
int authorSeed(String author) {
  int h = 0;
  for (final int c in author.codeUnits) {
    h = (h * 31 + c) & 0x7fffffff;
  }
  final int seed = h % 40;
  return seed == 7 ? 8 : seed;
}

/// "hace 5 min", "hace 2 h", "hace 3 días".
String agoText(AppLocalizations t, DateTime? created, DateTime now) {
  if (created == null) return '';
  final Duration d = now.difference(created);
  if (d.inHours < 1) return t.cardsAgoMinutes(d.inMinutes.clamp(1, 59));
  if (d.inDays < 1) return t.cardsAgoHours(d.inHours);
  return t.cardsAgoDays(d.inDays);
}

/// Dinero redondeado a unidades enteras ("430 €", no "429,60 €").
String wholeMoney(int minor, String currency, String locale) {
  final int unit = wholeToMinor(1, currency);
  return formatMoney(
    (minor + unit ~/ 2) ~/ unit * unit,
    currency,
    locale,
    compact: true,
  );
}

/// Las paradas del mapa: cada cosa del viaje menos los vuelos (que no son un
/// sitio de la ciudad). Si solo hay vuelos, todas.
List<TripLine> tripStops(SharedTrip trip) {
  final List<TripLine> places = <TripLine>[
    for (final TripLine l in trip.lines)
      if (l.kind != TripKind.flight) l,
  ];
  return places.isEmpty ? trip.lines : places;
}

/// Un viaje tal y como lo pinta la página.
Map<String, Object?> copyTripJson(
  AppLocalizations t,
  SharedTrip trip, {
  required String locale,
  required DateTime now,
  required bool copied,
}) {
  String money(int minor) => wholeMoney(minor, trip.currency, locale);
  return <String, Object?>{
    'a': trip.author,
    'u': authorSeed(trip.author),
    'ago': agoText(t, trip.createdAt, now),
    'city': trip.destination,
    'ill': illustrationFor(trip.destination),
    'title': trip.title,
    'note': trip.note,
    'seed': authorSeed(trip.code) * 7 + 11,
    'days': trip.days,
    'daysT': t.exploreDaysValue(trip.days),
    'cost': money(trip.totalMinor),
    'perDay': money(trip.totalMinor ~/ trip.days),
    'stops': <Object?>[
      for (final TripLine l in tripStops(trip))
        <String, Object?>{'n': l.title, 'p': money(l.priceMinor)},
    ],
    'avg': trip.ratingAvg,
    'votes': trip.ratingCount,
    'mine': trip.myRating ?? 0,
    'own': trip.mine,
    'copied': copied,
  };
}

/// Todo lo que necesita la página.
Map<String, Object?> copyPageData({
  required AppLocalizations t,
  required String language,
  required String locale,
  required DateTime now,
  List<SharedTrip> trips = const <SharedTrip>[],
  Set<String> copied = const <String>{},
  String? message,
  bool retry = false,
  String? toast,
}) => <String, Object?>{
  'lang': language,
  't': copyTexts(t),
  'trips': <Object?>[
    for (final SharedTrip trip in trips)
      copyTripJson(
        t,
        trip,
        locale: locale,
        now: now,
        copied: copied.contains(trip.code),
      ),
  ],
  'msg': message ?? '',
  'retry': retry,
  'toast': toast ?? '',
};

/// La página lista para enseñar.
String copyPageWith(String page, Map<String, Object?> data) {
  // "<" como \u003c: ningún texto de la gente puede cerrar el script.
  final String json = jsonEncode(data).replaceAll('<', r'\u003c');
  return page.replaceFirst(copyMarker, json);
}
