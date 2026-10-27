// UserAvatar: el círculo con la cara de una persona. Si hay foto (y viene de
// un sitio de confianza) la enseña; si no, o mientras carga, o si falla,
// enseña la inicial en el círculo de color, como siempre.
import 'package:flutter/material.dart';

import 'dart:io';

import '../core/theme.dart';
import '../features/settings/profile_photo.dart';

/// Crea la imagen a partir de una dirección. Es una variable para que los
/// tests puedan poner una imagen falsa y no tocar internet.
typedef AvatarImageFactory = ImageProvider Function(String url);

/// Quién puede servir fotos de perfil. Solo https y estos dominios:
/// así nunca pedimos imágenes a un sitio desconocido.
const List<String> trustedPhotoHosts = <String>[
  'googleusercontent.com', // fotos de cuentas de Google
];

/// true si la dirección es https y de un dominio de confianza.
bool isTrustedPhotoUrl(String? url) {
  if (url == null || url.isEmpty) return false;
  final Uri? uri = Uri.tryParse(url);
  if (uri == null || uri.scheme != 'https') return false;
  final String host = uri.host.toLowerCase();
  return trustedPhotoHosts.any((String d) => host == d || host.endsWith('.$d'));
}

class UserAvatar extends StatelessWidget {
  const UserAvatar({
    super.key,
    required this.name,
    this.photoUrl,
    this.size = 40,
    this.color = NomadColors.group,
    this.textColor = NomadColors.background,
    this.isMe = false,
  });

  /// true en TU avatar: ahí manda la foto que elegiste en el móvil
  /// (hacer foto, galería o avatar de viajero), antes que la de Google.
  final bool isMe;

  /// Nombre para sacar la inicial. Vacío o null = icono de persona.
  final String? name;

  /// Dirección de la foto (opcional).
  final String? photoUrl;

  /// Diámetro del círculo.
  final double size;
  final Color color;
  final Color textColor;

  /// SOLO PARA TESTS: si no es null, se usa en vez de bajar la foto de red.
  static AvatarImageFactory? debugImageFactory;

  @override
  Widget build(BuildContext context) {
    if (!isMe) return _build(null);
    return ListenableBuilder(
      listenable: ProfilePhotoController.instance,
      builder: (BuildContext context, Widget? _) =>
          _build(ProfilePhotoController.instance.choice),
    );
  }

  Widget _build(ProfilePhotoChoice? mine) {
    final String? n = name;
    if (mine != null && !mine.isNone) {
      final int? preset = mine.preset;
      final String? path = mine.filePath;
      final Widget inner = preset != null
          ? Container(
              color: presetAvatars[preset].color,
              alignment: Alignment.center,
              child: Icon(
                presetAvatars[preset].icon,
                color: Colors.white,
                size: size * 0.55,
              ),
            )
          : Image.file(
              File(path!),
              width: size,
              height: size,
              fit: BoxFit.cover,
              // Si el archivo ya no existe, se ve la inicial de siempre.
              errorBuilder: (_, Object e, StackTrace? s) => _build(null),
            );
      return ClipOval(
        child: SizedBox.square(dimension: size, child: inner),
      );
    }
    // La inicial (o un icono si no hay nombre) es lo que se ve sin foto.
    final Widget fallback = Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      color: color,
      child: (n == null || n.isEmpty)
          ? Icon(Icons.person_rounded, color: textColor, size: size * 0.55)
          : Text(
              n.characters.first.toUpperCase(),
              style: TextStyle(
                color: textColor,
                fontWeight: FontWeight.w800,
                fontSize: size * 0.4,
              ),
            ),
    );
    final String? url = photoUrl;
    final bool useFake =
        debugImageFactory != null && url != null && url.isNotEmpty;
    Widget content = fallback;
    if (useFake || isTrustedPhotoUrl(url)) {
      final ImageProvider provider = useFake
          ? debugImageFactory!(url)
          : NetworkImage(url!);
      content = Image(
        image: provider,
        width: size,
        height: size,
        fit: BoxFit.cover,
        // Mientras carga: la inicial. Si falla: también la inicial.
        frameBuilder: (_, Widget child, int? frame, bool sync) =>
            (frame == null && !sync) ? fallback : child,
        errorBuilder: (_, Object e, StackTrace? s) => fallback,
      );
    }
    return ClipOval(
      child: SizedBox.square(dimension: size, child: content),
    );
  }
}
