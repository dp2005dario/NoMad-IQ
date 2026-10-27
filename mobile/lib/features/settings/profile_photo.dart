// La foto de perfil que eliges TÚ en el móvil (hacer foto, galería o uno de
// 6 avatares de viajero). Se guarda solo en este teléfono: no se sube a
// ningún servidor, así que no hace falta cuenta ni internet.
//
// Se guarda en SharedPreferences (la libretita de ajustes de la app):
//   profile_photo = "none" | "preset:3" | "file:/ruta/a/la/foto.jpg"
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Un avatar de viajero: un icono sobre un color.
class PresetAvatar {
  const PresetAvatar(this.icon, this.color);
  final IconData icon;
  final Color color;
}

const List<PresetAvatar> presetAvatars = <PresetAvatar>[
  PresetAvatar(Icons.flight_takeoff_rounded, Color(0xFF3B82F6)),
  PresetAvatar(Icons.beach_access_rounded, Color(0xFFF59E0B)),
  PresetAvatar(Icons.hiking_rounded, Color(0xFF22C55E)),
  PresetAvatar(Icons.photo_camera_rounded, Color(0xFFEC4899)),
  PresetAvatar(Icons.restaurant_rounded, Color(0xFFEF4444)),
  PresetAvatar(Icons.sailing_rounded, Color(0xFF14B8A6)),
];

/// Lo que has elegido. Solo uno de los tres campos tiene valor.
class ProfilePhotoChoice {
  const ProfilePhotoChoice({this.preset, this.filePath});
  final int? preset;
  final String? filePath;

  bool get isNone => preset == null && filePath == null;

  /// Convierte el texto guardado en una elección (datos rotos = ninguna).
  static ProfilePhotoChoice decode(String? raw) {
    if (raw == null) return const ProfilePhotoChoice();
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

  Future<void> remove() => _set(const ProfilePhotoChoice());

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
