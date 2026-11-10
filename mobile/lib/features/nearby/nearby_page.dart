// Lo que la app le da a la página de "Cerca de ti" (la maqueta, en
// assets/nearby/cerca.html): los textos en tu idioma y los sitios REALES de
// OpenStreetMap ya colocados alrededor de ti (metros y dirección).
//
// Todo es Dart puro: así se prueba sin WebView.
//   - Tiendas y sitios (la primera pestaña, antes "Ofertas ya"): lo que hay
//     a tu alrededor como en un mapa normal (súper, cafeterías, farmacias,
//     cajeros, cines...), del más cercano al más lejano, con si está abierto.
//   - Gratis: agua, baños, wifi, enchufes y sitios que ver gratis (los que
//     OSM marca sin entrada, y miradores, parques, templos y monumentos).
//   - Tengo 2 horas: planes de 1 a 3 sitios que ver que caben en 2 horas.
import 'dart:convert';
import 'dart:math' as math;

import '../../l10n/generated/app_localizations.dart';
import '../map/geo.dart';
import 'nearby_api.dart';
import 'opening_hours.dart';
import 'walk.dart';

/// Dónde está la página y la marca donde la app mete sus datos.
const String nearbyPage = 'assets/nearby/cerca.html';
const String nearbyMarker =
    '/*ECLIPTA*/{"lang":"es","t":{},"offers":[],"free":[],"plans":[],'
    '"tab":1,"place":"","attr":"","msg":"","retry":false}';

/// Un plan de "Tengo 2 horas" dura como mucho esto (con el camino al primer
/// sitio incluido).
const int planMinutes = 120;

/// Hasta dónde se buscan sitios gratis (metros).
const double freeRadius = 2000;

/// Cuántas tiendas y sitios salen como mucho (la página numera las tarjetas
/// de cada pestaña de 100 en 100).
const int maxShops = 60;

/// Los textos de la página (las claves que usa la página).
Map<String, String> nearbyTexts(AppLocalizations t) {
  // nearbyMeters y nearbyHours piden un número: se pone uno que no sale
  // nunca y se cambia por la marca que entiende la página.
  const int mark = 7919;
  return <String, String>{
    'title': t.nearbyTitle,
    'now': t.nbNow('{time}'),
    'tabOffers': t.nbOffers,
    'tabFree': t.nearbyFree,
    'tabPlans': t.nbTwoHours,
    'credit': t.nbCredit,
    'back': t.nbBack,
    'zoomIn': t.exwZoomIn,
    'zoomOut': t.exwZoomOut,
    'tilt': t.nbTilt,
    'center': t.nbCenter,
    'expand': t.nbExpand,
    'min': t.nbMin('{n}'),
    'minWalk': t.nbMinWalk('{n}'),
    'h': t.nearbyHours(mark).replaceFirst('$mark', '{h}'),
    'm': t.nearbyMeters(mark).replaceFirst('$mark', '{m}'),
    'walkMin': t.nbWalkMin('{n}'),
    'toFirst': t.nbToFirst,
    'go': t.nearbyGo,
    'infoOffers': t.nbInfoOffers,
    'infoFree': t.nbInfoFree,
    'infoPlans': t.nbInfoPlans,
    'closesIn': t.nbClosesIn('{time}'),
    'endsIn': t.nbEndsIn('{time}'),
    'free': t.nearbyFree,
    'noData': t.exwNoData,
    'plan': t.nbPlan,
    'endsAt': t.nbEndsAt('{time}'),
    'fit': t.nbFit,
    'sortDur': t.nbSortTime,
    'sortWalk': t.nbSortWalk,
    'sortPrice': t.nbSortPrice,
    'you': t.nbYou,
    'noOffers': t.nbNoOffers,
    'noFree': t.nearbyNone,
    'noPlans': t.nbNoPlans,
    'retry': t.guideRetry,
    'pause': t.nbPause,
    'resume': t.nbResume,
    'route': t.nbRoute,
    'exit': t.nbExit,
    'left': t.nbLeft('{min}', '{m}'),
    'straight': t.nbStraight,
    'inM': t.nbInMeters('{m}'),
    'right': t.nbTurnRight,
    'leftTurn': t.nbTurnLeft,
    'arrived': t.nbArrived,
    'here': t.nbHere,
  };
}

/// Lo que se manda a la página y, aparte, adónde lleva el botón "Ruta" de
/// cada tarjeta (Google Maps andando: es un enlace, gratis).
class NearbyPageData {
  const NearbyPageData({
    required this.json,
    required this.routes,
    this.shops = const <int, NearbySpot>{},
  });

  final Map<String, Object?> json;

  /// Las tiendas por el número de su tarjeta (0 + i): para buscar su foto
  /// de Google Maps cuando la página la pide ("photo:3").
  final Map<int, NearbySpot> shops;

  /// Por el número de la tarjeta (100 + i en Gratis, 200 + i en planes).
  final Map<int, Uri> routes;
}

/// El dibujo de la página y el nombre de cada clase de sitio que ver.
(String, String Function(AppLocalizations)) _sightLook(String? sub) =>
    switch (sub) {
      'museum' => ('museum', (AppLocalizations t) => t.nbMuseum),
      'gallery' => ('museum', (AppLocalizations t) => t.nbGallery),
      'viewpoint' => ('view', (AppLocalizations t) => t.nbViewpoint),
      'park' => ('park', (AppLocalizations t) => t.nbPark),
      'worship' => ('church', (AppLocalizations t) => t.nbWorship),
      'castle' => ('castle', (AppLocalizations t) => t.nbCastle),
      'ruins' => ('castle', (AppLocalizations t) => t.nbRuins),
      'archaeological_site' => ('castle', (AppLocalizations t) => t.nbSite),
      'monument' => ('monument', (AppLocalizations t) => t.nbMonument),
      'memorial' => ('monument', (AppLocalizations t) => t.nbMemorial),
      'artwork' => ('monument', (AppLocalizations t) => t.nbArtwork),
      'attraction' => ('monument', (AppLocalizations t) => t.nbAttraction),
      _ => ('monument', (AppLocalizations t) => t.nbSight),
    };

/// Dibujo de la página y nombre de cada tienda o sitio según lo que es
/// exactamente ("supermarket", "cafe"...).
(String, String) shopLook(AppLocalizations t, String? sub) => switch (sub) {
  'supermarket' ||
  'convenience' ||
  'greengrocer' ||
  'butcher' ||
  'general' => ('market', t.nbSupermarket),
  'cafe' => ('cafe', t.nbCafe),
  'ice_cream' => ('cafe', t.nbIceCream),
  'restaurant' || 'food_court' => ('menu', t.nbRestaurant),
  'fast_food' => ('menu', t.nbFastFood),
  'bar' || 'pub' || 'biergarten' => ('beer', t.nbBar),
  'bakery' || 'pastry' || 'confectionery' || 'deli' => ('bakery', t.nbBakery),
  'pharmacy' || 'chemist' => ('pharmacy', t.nbPharmacy),
  'atm' => ('money', t.nbAtm),
  'bank' => ('money', t.nbBank),
  'bureau_de_change' => ('money', t.nbExchange),
  'cinema' => ('fun', t.nbCinema),
  'theatre' => ('fun', t.nbTheatre),
  'library' => ('fun', t.nbLibrary),
  'marketplace' => ('market', t.nbMarket),
  'post_office' => ('fun', t.nbPostOffice),
  'clothes' || 'shoes' || 'fashion' => ('shop', t.nbClothes),
  _ => ('shop', t.nbShop),
};

/// Qué es un sitio de Cerca de ti, en tu idioma ("Supermercado", "Museo"...)
/// y su dibujo de la página. null si no es ni tienda ni sitio que ver.
(String, String)? spotLook(AppLocalizations t, NearbySpot s) =>
    switch (s.kind) {
      NearbyKind.shop => shopLook(t, s.sub),
      NearbyKind.sight => (_sightLook(s.sub).$1, _sightLook(s.sub).$2(t)),
      _ => null,
    };

/// "23:00": la hora a la que cierra, contando desde [now].
String _clock(DateTime now, int minutesLeft) {
  final DateTime at = now.add(Duration(minutes: minutesLeft));
  return '${at.hour.toString().padLeft(2, '0')}:'
      '${at.minute.toString().padLeft(2, '0')}';
}

/// Sitios que ver que se visitan gratis aunque OSM no lo diga.
const Set<String> _freeByNature = <String>{
  'viewpoint',
  'park',
  'worship',
  'monument',
  'memorial',
  'artwork',
  'ruins',
  'archaeological_site',
};

/// El color de la chapa de cada dibujo (los de la maqueta).
const Map<String, String> _chapa = <String, String>{
  'museum': '#b7a8ff',
  'view': '#8ff0e4',
  'park': '#9ff08a',
  'church': '#ffe28a',
  'monument': '#ffc9a8',
  'castle': '#e0d0b8',
  'water': '#9fd8ff',
  'wc': '#c9f0ff',
  'wifi': '#d6c8ff',
  'plug': '#ffe9a0',
};

/// El color de la chapa de cada tienda (el claro de su dibujo en la página).
const Map<String, String> _chapaShop = <String, String>{
  'market': '#8ec3ff',
  'cafe': '#e8c7a3',
  'menu': '#6df0b6',
  'beer': '#ffd37a',
  'bakery': '#ffd9a0',
  'pharmacy': '#9ff0b0',
  'money': '#c8f5a0',
  'fun': '#b9c4ff',
  'shop': '#ffb3d9',
};

/// Dibujo y nombre de un sitio de "Gratis".
(String, String) _look(AppLocalizations t, NearbySpot s) => switch (s.kind) {
  NearbyKind.water => ('water', t.nearbyWater),
  NearbyKind.toilets => ('wc', t.nearbyToilets),
  NearbyKind.wifi => ('wifi', t.nearbyWifi),
  NearbyKind.charging => ('plug', t.nearbyCharging),
  _ => (_sightLook(s.sub).$1, _sightLook(s.sub).$2(t)),
};

/// Las dos iniciales del letrero de la fachada: primera y última palabra
/// ("Museo del Prado" -> "MP", "San Isidro" -> "SI").
String initials(String name) {
  final List<String> words = name
      .split(RegExp(r'[\s\-–·,]+'))
      .where((String w) => w.runes.length >= 2)
      .toList();
  if (words.isEmpty) {
    return String.fromCharCodes(name.trim().runes.take(2)).toUpperCase();
  }
  if (words.length == 1) {
    return String.fromCharCodes(words.first.runes.take(2)).toUpperCase();
  }
  return (String.fromCharCode(words.first.runes.first) +
          String.fromCharCode(words.last.runes.first))
      .toUpperCase();
}

/// Metros y ángulo de [p] visto desde [me], como los pinta el mapa de la
/// página (ángulo 0 = este y hacia abajo = sur).
(int, double) placeOnMap(GeoPoint me, GeoPoint p) {
  final double east =
      (p.lon - me.lon) * 111320 * math.cos(me.lat * math.pi / 180);
  final double north = (p.lat - me.lat) * 110540;
  final int d = (me.distanceTo(p) / 10).round() * 10;
  return (math.max(10, d), math.atan2(-north, east));
}

/// Minutos andando de [a] a [b] (lo mismo que cuenta el paseo).
int walkMinutesBetween(GeoPoint a, GeoPoint b) =>
    (a.distanceTo(b) * streetDetour / walkMetersPerMinute).ceil();

Uri _mapsTo(GeoPoint me, List<GeoPoint> stops) {
  String at(GeoPoint p) =>
      '${p.lat.toStringAsFixed(5)},${p.lon.toStringAsFixed(5)}';
  return Uri.https('www.google.com', '/maps/dir/', <String, String>{
    'api': '1',
    'origin': at(me),
    'destination': at(stops.last),
    if (stops.length > 1)
      'waypoints': stops.take(stops.length - 1).map(at).join('|'),
    'travelmode': 'walking',
  });
}

/// "Madrid · Embajadores": la ciudad y el barrio (o distrito) de la zona.
String placeName(NearbyList found) {
  String? level(String l) {
    for (final NearbySpot s in found.spots) {
      if (s.kind == NearbyKind.place && s.sub == l) return s.name;
    }
    return null;
  }

  final String? city = level('8');
  final String? local = level('10') ?? level('9');
  return <String>{?city, ?local}.join(' · ');
}

/// Todo lo que necesita la página. Sin [me] o sin [found] las listas van
/// vacías y la página enseña [message] (cargando, sin GPS, sin red...).
NearbyPageData nearbyPageData({
  required AppLocalizations t,
  required String language,
  required DateTime now,
  GeoPoint? me,
  NearbyList? found,
  String? message,
  bool retry = false,
}) {
  final Map<int, Uri> routes = <int, Uri>{};
  final Map<int, NearbySpot> shopSpots = <int, NearbySpot>{};
  final List<Map<String, Object?>> shops = <Map<String, Object?>>[];
  final List<Map<String, Object?>> free = <Map<String, Object?>>[];
  final List<Map<String, Object?>> plans = <Map<String, Object?>>[];
  if (me != null && found != null) {
    // --- Tiendas y sitios: los más cercanos. Primero los abiertos ahora (o
    // sin horario conocido); los cerrados, al final.
    final List<(NearbySpot, OpenNow)> near = <(NearbySpot, OpenNow)>[
      for (final NearbySpot s in found.of(NearbyKind.shop, me))
        (s, openNow(s.openingHours, now)),
    ];
    near.sort(
      ((NearbySpot, OpenNow) a, (NearbySpot, OpenNow) b) =>
          (a.$2.state == OpenState.closed ? 1 : 0).compareTo(
            b.$2.state == OpenState.closed ? 1 : 0,
          ),
    );
    for (final (NearbySpot s, OpenNow open) in near.take(maxShops)) {
      final (String k, String label) = shopLook(t, s.sub);
      final (int d, double a) = placeOnMap(me, s.point);
      final String name = s.name ?? label;
      final String raw = s.openingHours ?? '';
      routes[shops.length] = _mapsTo(me, <GeoPoint>[s.point]);
      if (s.name != null) shopSpots[shops.length] = s;
      final String color = switch (open.state) {
        OpenState.closed => '#ff8a8a',
        _ => _chapaShop[k] ?? '#ffffff',
      };
      shops.add(<String, Object?>{
        'k': k,
        'ini': initials(name),
        't': name,
        'v': label,
        'dest': name,
        'd': d,
        'a': a,
        // La chapa: "ABIERTO hasta 23:00", "24 H", "CERRADO" o qué es.
        'cp': <String>[
          switch (open.state) {
            OpenState.open => t.nbOpenNow,
            OpenState.always => '24 H',
            OpenState.closed => t.nbClosedNow,
            OpenState.unknown => label,
          },
          switch (open.state) {
            OpenState.open => '→ ${_clock(now, open.left)}',
            OpenState.always => t.nbOpen24,
            _ => label,
          }.toUpperCase(),
          color,
        ],
        'end': open.state == OpenState.open ? open.left : null,
        'tot': open.state == OpenState.open ? open.total : null,
        'hrs': switch (open.state) {
          OpenState.always => t.nbOpen24,
          OpenState.open => '',
          _ => raw.length > 48 ? '${raw.substring(0, 47)}…' : raw,
        },
      });
    }
    // --- Gratis: los más cercanos, como mucho 6 de cada clase y 24 en total.
    final List<NearbySpot> spots =
        found.spots.where((NearbySpot s) {
          if (me.distanceTo(s.point) > freeRadius) return false;
          return switch (s.kind) {
            NearbyKind.water ||
            NearbyKind.toilets ||
            NearbyKind.wifi ||
            NearbyKind.charging => s.fee != true,
            NearbyKind.sight =>
              s.fee == false ||
                  (s.fee == null && _freeByNature.contains(s.sub)),
            _ => false,
          };
        }).toList()..sort(
          (NearbySpot a, NearbySpot b) =>
              me.distanceTo(a.point).compareTo(me.distanceTo(b.point)),
        );
    final Map<String, int> perKind = <String, int>{};
    for (final NearbySpot s in spots) {
      if (free.length >= 24) break;
      final (String k, String label) = _look(t, s);
      final int n = perKind[k] = (perKind[k] ?? 0) + 1;
      if (n > 6) continue;
      final (int d, double a) = placeOnMap(me, s.point);
      final String name = s.name ?? label;
      final OpenNow open = openNow(s.openingHours, now);
      final String raw = s.openingHours ?? '';
      routes[100 + free.length] = _mapsTo(me, <GeoPoint>[s.point]);
      free.add(<String, Object?>{
        'k': k,
        'ini': initials(name),
        't': name,
        'v': label,
        'dest': name,
        'd': d,
        'a': a,
        'cp': <String>[
          t.nearbyFree,
          label.toUpperCase(),
          _chapa[k] ?? '#ffffff',
        ],
        'end': open.state == OpenState.open ? open.left : null,
        'tot': open.state == OpenState.open ? open.total : null,
        'hrs': switch (open.state) {
          OpenState.always => t.nbOpen24,
          OpenState.open => '',
          _ => raw.length > 48 ? '${raw.substring(0, 47)}…' : raw,
        },
      });
    }
    // --- Tengo 2 horas: empezando por cada uno de los 8 sitios que ver más
    // cercanos, se añaden los más cercanos mientras quepa en 2 horas.
    final List<NearbySpot> sights = found
        .of(NearbyKind.sight, me)
        .where((NearbySpot s) => s.name != null)
        .take(12)
        .toList();
    final Set<String> seen = <String>{};
    for (final NearbySpot first in sights.take(8)) {
      if (plans.length >= 6) break;
      final int walk = walkMinutesBetween(me, first.point);
      if (walk + minutesPerStop > planMinutes) continue;
      final List<NearbySpot> stops = <NearbySpot>[first];
      int dur = minutesPerStop;
      while (stops.length < 3) {
        final List<NearbySpot> left =
            sights.where((NearbySpot s) => !stops.contains(s)).toList()..sort(
              (NearbySpot a, NearbySpot b) => stops.last.point
                  .distanceTo(a.point)
                  .compareTo(stops.last.point.distanceTo(b.point)),
            );
        if (left.isEmpty) break;
        final int go = walkMinutesBetween(stops.last.point, left.first.point);
        if (walk + dur + go + minutesPerStop > planMinutes) break;
        stops.add(left.first);
        dur += go + minutesPerStop;
      }
      final String key = (stops.map((NearbySpot s) => s.id).toList()..sort())
          .join();
      if (!seen.add(key)) continue;
      final List<String> names = stops.map((NearbySpot s) => s.name!).toList();
      final String title = names.length == 1
          ? names.first
          : t.nbJoin(names.take(names.length - 1).join(', '), names.last);
      final (int d, double a) = placeOnMap(me, first.point);
      routes[200 + plans.length] = _mapsTo(
        me,
        stops.map((NearbySpot s) => s.point).toList(),
      );
      plans.add(<String, Object?>{
        'k': _sightLook(first.sub).$1,
        'ini': initials(first.name!),
        't': title,
        'v': stops.length == 1 ? t.nbOneStop : t.nbStops('${stops.length}'),
        'dest': first.name,
        'd': d,
        'a': a,
        'dur': dur,
        'walk': walk,
        // Precio: gratis solo si OSM dice que todos son gratis; si no, la
        // tarjeta no pone precio (no sabemos lo que cuesta la entrada).
        'pr': stops.every((NearbySpot s) => s.fee == false) ? 0 : null,
      });
    }
  }
  return NearbyPageData(
    json: <String, Object?>{
      'lang': language,
      't': nearbyTexts(t),
      'offers': shops,
      'free': free,
      'plans': plans,
      'tab': 0,
      'place': found == null ? '' : placeName(found),
      'attr': found?.attribution ?? '',
      'msg': message ?? '',
      'retry': retry,
    },
    routes: routes,
    shops: shopSpots,
  );
}

/// La página lista para enseñar.
String nearbyPageWith(String page, NearbyPageData data) {
  // Se escribe "<" como \u003c: así ningún nombre de OpenStreetMap puede
  // cerrar el <script> de la página.
  final String json = jsonEncode(data.json).replaceAll('<', r'\u003c');
  return page.replaceFirst(nearbyMarker, json);
}
