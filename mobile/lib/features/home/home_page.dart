// Lo que la app le da a la página de Inicio (la maqueta "ECLIPTA Inicio", en
// assets/inicio/inicio.html): dónde estás, tu pasaporte y tu DNI, tus
// cromos, tus contactos de emergencia y lo que lleva el aviso del SOS.
//
// Dart puro: se prueba sin WebView.
import 'dart:convert';

import '../camera/stamps.dart';
import '../map/geo.dart';
import '../passport/passport.dart';
import '../sos/sos_store.dart';
import 'home_album.dart';

/// Dónde está la página y la marca donde la app mete sus datos.
const String homePage = 'assets/inicio/inicio.html';
const String homeMarker = '/*ECLIPTA*/{}';

/// El color del cromo en la maqueta: verde (común), azul (raro), naranja
/// (épico) o violeta (legendario), según la edad del monumento.
String rarityClass(int? year) => switch (rarityOf(year)) {
  Rarity.common => 'm',
  Rarity.rare => 'b',
  Rarity.epic => 'c',
  Rarity.legendary => 'v',
};

/// Las páginas del libro para la página: título y 4 huecos (null = "?").
List<Map<String, Object?>> albumJson(List<AlbumPage> pages) =>
    <Map<String, Object?>>[
      for (final AlbumPage p in pages)
        <String, Object?>{
          't': p.title,
          'c': <Map<String, Object?>?>[
            for (final Stamp? s in p.cards)
              s == null
                  ? null
                  : <String, Object?>{'n': s.name, 'cl': rarityClass(s.year)},
          ],
        },
    ];

/// Las 2 líneas de abajo del pasaporte ("P<ESPGARCIA<<ANA<<<...").
List<String> mrzLines(
  String nationality,
  String surname,
  String given,
) => <String>[
  'P<${nationality.padRight(3, '<')}${surname.replaceAll(' ', '<')}<<'
      '${given.replaceAll(' ', '<')}<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<',
];

/// "41.14961 N, 8.61099 O", como en la maqueta.
String coordsText(GeoPoint p) =>
    '${p.lat.abs().toStringAsFixed(5)} ${p.lat >= 0 ? 'N' : 'S'}, '
    '${p.lon.abs().toStringAsFixed(5)} ${p.lon >= 0 ? 'E' : 'O'}';

/// WhatsApp con el mensaje ya escrito para [c] (tú solo pulsas Enviar).
Uri whatsappUri(SosContact c, String body) => Uri.https(
  'wa.me',
  '/${c.dial.replaceAll('+', '')}',
  <String, String>{'text': body},
);

/// Tus contactos para la página (nombre y teléfono).
List<Map<String, Object?>> contactsJson(List<SosContact> contacts) =>
    <Map<String, Object?>>[
      for (final SosContact c in contacts)
        <String, Object?>{'n': c.name, 'p': c.phone},
    ];

/// La página lista para enseñar.
String homePageWith(String page, Map<String, Object?> data) =>
    // "<" como \u003c: ningún dato puede cerrar el script.
    page.replaceFirst(homeMarker, jsonEncode(data).replaceAll('<', r'\u003c'));

/// Lo que se le manda a la página sin recargarla.
String homePushScript(Map<String, Object?> data) =>
    'window.ECLin&&window.ECLin(${jsonEncode(data).replaceAll('<', r'\u003c')})';
