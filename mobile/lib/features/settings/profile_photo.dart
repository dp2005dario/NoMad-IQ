// La foto de perfil que eliges TÚ en el móvil (hacer foto, galería, tu
// inicial o uno de los 5 avatares de viajero de la maqueta "Ajustes"). Se guarda solo en este teléfono: no se sube a
// ningún servidor, así que no hace falta cuenta ni internet.
//
// Se guarda en SharedPreferences (la libretita de ajustes de la app):
//   profile_photo = "none" | "initial" | "preset:3" | "file:/ruta/a/la/foto.jpg"
// ("none" = la foto de tu cuenta de Google, si la hay; "initial" = tu
// inicial aunque tengas foto de Google).
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Un avatar de viajero: un dibujo oscuro sobre un color (los de la maqueta).
class PresetAvatar {
  const PresetAvatar(this.icon, this.color);
  final IconData icon;
  final Color color;
}

const List<PresetAvatar> presetAvatars = <PresetAvatar>[
  PresetAvatar(Icons.flight_rounded, Color(0xFF6CA8FF)), // avión
  PresetAvatar(Icons.landscape_rounded, Color(0xFF3DDC97)), // montaña
  PresetAvatar(Icons.wb_sunny_rounded, Color(0xFFFFB86B)), // sol
  PresetAvatar(Icons.explore_rounded, Color(0xFFFF8A65)), // brújula
  PresetAvatar(Icons.backpack_rounded, Color(0xFFF2C230)), // mochila
];

/// Lo que has elegido. Solo uno de los tres campos tiene valor.
class ProfilePhotoChoice {
  const ProfilePhotoChoice({this.preset, this.filePath, this.initial = false});
  final int? preset;
  final String? filePath;

  /// true = tu inicial (aunque tu cuenta de Google tenga foto).
  final bool initial;

  bool get isNone => preset == null && filePath == null && !initial;

  /// Convierte el texto guardado en una elección (datos rotos = ninguna).
  static ProfilePhotoChoice decode(String? raw) {
    if (raw == null) return const ProfilePhotoChoice();
    if (raw == 'initial') return const ProfilePhotoChoice(initial: true);
    if (raw.startsWith('preset:')) {
      final int? i = int.tryParse(raw.substring(7));
      if (i != null && i >= 0 && i < presetAvatars.length) {
        return ProfilePhotoChoice(preset: i);
      }
    } else if (raw.startsWith('file:') && raw.length > 5) {
      return ProfilePhotoChoice(filePath: raw.substring(5));
    }
    return const ProfilePhotoChoice();
  }

  String encode() => preset != null
      ? 'preset:$preset'
      : filePath != null
      ? 'file:$filePath'
      : initial
      ? 'initial'
      : 'none';
}

/// Guarda y avisa a las pantallas cuando cambia la foto.
class ProfilePhotoController extends ChangeNotifier {
  ProfilePhotoController._();

  /// Una sola para toda la app (solo hay un perfil por teléfono).
  static final ProfilePhotoController instance = ProfilePhotoController._();

  static const String _key = 'profile_photo';

  ProfilePhotoChoice _choice = const ProfilePhotoChoice();
  ProfilePhotoChoice get choice => _choice;

  /// Lee lo guardado. Si falla (modo privado, etc.) se queda sin foto.
  Future<void> load() async {
    try {
      final SharedPreferences p = await SharedPreferences.getInstance();
      _choice = ProfilePhotoChoice.decode(p.getString(_key));
      notifyListeners();
    } on Object {
      // sin foto: se verá la inicial de siempre
    }
  }

  Future<void> _set(ProfilePhotoChoice c) async {
    final ProfilePhotoChoice old = _choice;
    _choice = c;
    notifyListeners();
    try {
      final SharedPreferences p = await SharedPreferences.getInstance();
      await p.setString(_key, c.encode());
    } on Object {
      // no se pudo guardar: se ve ahora, pero no sobrevive a reiniciar
    }
    _deleteOldFile(old, c);
  }

  /// Borra la foto antigua del disco para no acumular archivos.
  void _deleteOldFile(ProfilePhotoChoice old, ProfilePhotoChoice now) {
    final String? p = old.filePath;
    if (p == null || p == now.filePath) return;
    try {
      File(p).deleteSync();
    } on Object {
      // da igual si ya no estaba
    }
  }

  Future<void> choosePreset(int index) =>
      _set(ProfilePhotoChoice(preset: index));

  /// La foto de tu cuenta de Google (si la hay; si no, tu inicial).
  Future<void> remove() => _set(const ProfilePhotoChoice());

  /// Tu inicial en su círculo de color.
  Future<void> chooseInitial() => _set(const ProfilePhotoChoice(initial: true));

  /// Hace una foto o abre la galería. Devuelve false si cancelaste o falló.
  Future<bool> pick(ImageSource source, {ImagePicker? picker}) async {
    try {
      final XFile? shot = await (picker ?? ImagePicker()).pickImage(
        source: source,
        maxWidth: 512, // un perfil no necesita más: pesa poco
        maxHeight: 512,
        imageQuality: 85,
      );
      if (shot == null) return false;
      final Directory dir = await getApplicationSupportDirectory();
      // Nombre nuevo cada vez: así Flutter no enseña la foto vieja en caché.
      final String dest =
          '${dir.path}/perfil_${DateTime.now().millisecondsSinceEpoch}.jpg';
      await File(shot.path).copy(dest);
      await _set(ProfilePhotoChoice(filePath: dest));
      return true;
    } on Object {
      return false;
    }
  }

  /// SOLO PARA TESTS.
  void debugSet(ProfilePhotoChoice c) {
    _choice = c;
    notifyListeners();
  }
}
