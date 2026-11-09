// "Mi álbum de cromos" de Inicio (maqueta "ECLIPTA Inicio"): cómo se
// reparten tus cromos en las páginas del libro (el libro lo dibuja la página
// de Inicio, ver home_page.dart). Arriba de cada página, el país; debajo, 4
// huecos: tus cromos y "?" en los que aún faltan.
//
// Los cromos son de verdad: los sellos que consigues al hacer una foto a un
// monumento con la cámara (camera/stamps.dart). El país sale del aeropuerto
// más cercano, igual que en el Pasaporte (passport/passport.dart). La
// rareza (por la edad del monumento) decide el color del cromo.

import '../camera/stamps.dart';
import '../passport/passport.dart';

/// Huecos por página (como en la maqueta: 2 × 2).
const int albumSlots = 4;

/// Una página del álbum: título y 4 huecos (null = "?").
class AlbumPage {
  const AlbumPage({required this.title, required this.cards});

  final String title;
  final List<Stamp?> cards;
}

/// Reparte las páginas del Pasaporte (una por país) en páginas de 4 huecos.
/// Siempre hay un número PAR de páginas (el libro abierto enseña dos) y como
/// mínimo dos.
List<AlbumPage> albumPagesOf(
  List<PassportPage> pages, {
  required String Function(PassportPage) titleOf,
}) {
  final List<AlbumPage> out = <AlbumPage>[];
  for (final PassportPage p in pages) {
    final String title = titleOf(p);
    for (int i = 0; i < p.stamps.length; i += albumSlots) {
      final List<Stamp?> four = <Stamp?>[
        for (int j = i; j < i + albumSlots; j++)
          j < p.stamps.length ? p.stamps[j] : null,
      ];
      out.add(AlbumPage(title: title, cards: four));
    }
  }
  while (out.length < 2 || out.length.isOdd) {
    out.add(AlbumPage(title: '', cards: List<Stamp?>.filled(albumSlots, null)));
  }
  return out;
}
