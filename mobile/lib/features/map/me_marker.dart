// Tu marca en el mapa: tu foto de perfil (o tu avatar de viajero, o tu
// inicial) en un círculo con borde menta, en vez del punto verde de antes.
//
// MapLibre solo sabe pintar imágenes PNG, así que aquí se DIBUJA esa imagen
// con Flutter (un "lienzo" en memoria) y luego el mapa la usa como icono.
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../../core/theme.dart';
import '../../widgets/user_avatar.dart' show isTrustedPhotoUrl;
import '../settings/profile_photo.dart';

/// El nombre de la imagen en el estilo del mapa.
const String meImageId = 'nomad-me-photo';

/// Lado de la imagen en píxeles (se pinta al doble y el mapa la reduce:
/// así se ve nítida en pantallas con mucha densidad).
const int meImageSize = 112;

/// Qué foto toca: la del móvil, la de Google, un avatar o la inicial.
sealed class MeLook {
  const MeLook();
}

class MePhotoBytes extends MeLook {
  const MePhotoBytes(this.bytes);
  final Uint8List bytes;
}

class MePreset extends MeLook {
  const MePreset(this.icon, this.color);
  final IconData icon;
  final Color color;
}

class MeInitial extends MeLook {
  const MeInitial(this.letter);
  final String letter;
}

/// Decide qué enseñar, igual que el avatar de arriba del mapa.
Future<MeLook> meLookFor(
  ProfilePhotoChoice choice, {
  required String? name,
  required String? googlePhoto,
  Future<Uint8List?> Function(Uri url)? download,
}) async {
  final String letter = (name ?? '').trim().isEmpty
      ? ''
      : String.fromCharCodes(name!.trim().runes.take(1)).toUpperCase();
  if (choice.initial) return MeInitial(letter);
  final int? preset = choice.preset;
  if (preset != null) {
    return MePreset(presetAvatars[preset].icon, presetAvatars[preset].color);
  }
  final String? path = choice.filePath;
  if (path != null) {
    try {
      return MePhotoBytes(await File(path).readAsBytes());
    } on Object {
      return MeInitial(letter);
    }
  }
  if (isTrustedPhotoUrl(googlePhoto)) {
    final Uint8List? bytes = await (download ?? _download)(
      Uri.parse(googlePhoto!),
    );
    if (bytes != null) return MePhotoBytes(bytes);
  }
  return MeInitial(letter);
}

Future<Uint8List?> _download(Uri url) async {
  try {
    final http.Response r = await http
        .get(url)
        .timeout(const Duration(seconds: 8));
    // Una foto de perfil no pesa más de 2 MB: lo demás no es de fiar.
    if (r.statusCode != 200 || r.bodyBytes.length > 2 * 1024 * 1024) {
      return null;
    }
    return r.bodyBytes;
  } on Object {
    return null;
  }
}

/// Dibuja la marca y la devuelve en PNG. null si algo falla (el mapa
/// enseña entonces el punto de siempre).
Future<Uint8List?> drawMeMarker(MeLook look) async {
  try {
    const double s = meImageSize + 0.0;
    const double ring = 7;
    final ui.PictureRecorder rec = ui.PictureRecorder();
    final Canvas canvas = Canvas(rec);
    const Offset c = Offset(s / 2, s / 2);
    const double r = s / 2 - 4;
    // Sombra suave y borde menta (el color de "tú" en toda la app).
    canvas.drawCircle(
      c.translate(0, 2),
      r,
      Paint()
        ..color = const Color(0x66000000)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3),
    );
    canvas.drawCircle(c, r, Paint()..color = NomadColors.mint);
    canvas.drawCircle(c, r - ring + 2, Paint()..color = Colors.white);
    final double inner = r - ring;
    final Rect box = Rect.fromCircle(center: c, radius: inner);
    canvas.save();
    canvas.clipPath(Path()..addOval(box));
    switch (look) {
      case MePhotoBytes(:final Uint8List bytes):
        final ui.Codec codec = await ui.instantiateImageCodec(
          bytes,
          targetWidth: meImageSize,
        );
        final ui.Image img = (await codec.getNextFrame()).image;
        // "cover": la foto llena el círculo sin deformarse.
        final double scale = (box.width / img.width) > (box.height / img.height)
            ? box.width / img.width
            : box.height / img.height;
        final Size drawn = Size(img.width * scale, img.height * scale);
        paintImage(
          canvas: canvas,
          rect: Rect.fromCenter(
            center: c,
            width: drawn.width,
            height: drawn.height,
          ),
          image: img,
          filterQuality: FilterQuality.medium,
        );
      case MePreset(:final IconData icon, :final Color color):
        canvas.drawRect(box, Paint()..color = color);
        _text(
          canvas,
          String.fromCharCode(icon.codePoint),
          c,
          TextStyle(
            fontFamily: icon.fontFamily,
            package: icon.fontPackage,
            fontSize: inner * 1.15,
            color: Colors.white,
          ),
        );
      case MeInitial(:final String letter):
        canvas.drawRect(box, Paint()..color = NomadColors.group);
        if (letter.isEmpty) {
          _text(
            canvas,
            String.fromCharCode(Icons.person_rounded.codePoint),
            c,
            TextStyle(
              fontFamily: Icons.person_rounded.fontFamily,
              fontSize: inner * 1.2,
              color: Colors.white,
            ),
          );
        } else {
          _text(
            canvas,
            letter,
            c,
            TextStyle(
              fontSize: inner * 1.05,
              fontWeight: FontWeight.w800,
              color: NomadColors.background,
            ),
          );
        }
    }
    canvas.restore();
    final ui.Image out = await rec.endRecording().toImage(
      meImageSize,
      meImageSize,
    );
    final ByteData? png = await out.toByteData(format: ui.ImageByteFormat.png);
    return png?.buffer.asUint8List();
  } on Object {
    return null;
  }
}

void _text(Canvas canvas, String text, Offset center, TextStyle style) {
  final TextPainter p = TextPainter(
    text: TextSpan(text: text, style: style),
    textDirection: TextDirection.ltr,
  )..layout();
  p.paint(canvas, center - Offset(p.width / 2, p.height / 2));
}
