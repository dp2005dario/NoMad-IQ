// La cámara y la brújula del móvil, detrás de una "interfaz" (un enchufe):
// en la app se conecta la cámara de verdad (paquete camera) y en los tests
// una falsa que no necesita hardware.
import 'dart:async';

import 'package:camera/camera.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_compass/flutter_compass.dart';

/// Cómo fue encender la cámara.
enum CameraStart {
  ready, // ya se ve la imagen
  denied, // la persona no dio permiso
  missing, // el aparato no tiene cámara (o está ocupada por otra app)
}

abstract interface class CameraDevice {
  Future<CameraStart> start();

  /// Lo que ve la cámara, para ponerlo de fondo en la pantalla.
  Widget preview();

  /// Hace una foto y la devuelve en JPEG (ya pequeña: unos 100 KB).
  Future<Uint8List> takePhoto();

  /// Hacia dónde mira el móvil en grados (0 = norte, 90 = este), o null si
  /// el aparato no tiene brújula.
  Stream<double?> heading();

  Future<void> dispose();
}

typedef CameraFactory = CameraDevice Function();

/// La cámara de verdad: la trasera, a resolución media (480p). Es de sobra
/// para reconocer un edificio y la foto pesa poco (menos datos y batería).
class DeviceCamera implements CameraDevice {
  CameraController? _controller;

  @override
  Future<CameraStart> start() async {
    try {
      final List<CameraDescription> cameras = await availableCameras();
      if (cameras.isEmpty) return CameraStart.missing;
      final CameraDescription back = cameras.firstWhere(
        (CameraDescription c) => c.lensDirection == CameraLensDirection.back,
        orElse: () => cameras.first,
      );
      final CameraController controller = CameraController(
        back,
        ResolutionPreset.medium,
        enableAudio: false, // solo fotos: nunca pedimos el micrófono
        imageFormatGroup: ImageFormatGroup.jpeg,
      );
      // Aquí Android enseña "¿Permitir que NomadIQ haga fotos?".
      await controller.initialize();
      _controller = controller;
      return CameraStart.ready;
    } on CameraException catch (e) {
      return e.code.contains('Access') || e.code.contains('Permission')
          ? CameraStart.denied
          : CameraStart.missing;
    } on PlatformException {
      return CameraStart.missing;
    }
  }

  @override
  Widget preview() {
    final CameraController? c = _controller;
    if (c == null || !c.value.isInitialized) return const SizedBox.expand();
    // "cover": la imagen llena la pantalla (se recortan los bordes que
    // sobran), como en la app de cámara del móvil.
    return ClipRect(
      child: FittedBox(
        fit: BoxFit.cover,
        child: SizedBox(
          width: c.value.previewSize?.height ?? 480,
          height: c.value.previewSize?.width ?? 720,
          child: CameraPreview(c),
        ),
      ),
    );
  }

  @override
  Future<Uint8List> takePhoto() async {
    final CameraController? c = _controller;
    if (c == null) throw StateError('la cámara no está encendida');
    final XFile file = await c.takePicture();
    return file.readAsBytes();
  }

  @override
  Stream<double?> heading() {
    final Stream<CompassEvent>? events = FlutterCompass.events;
    if (events == null) return Stream<double?>.value(null);
    return events.map((CompassEvent e) => e.heading);
  }

  @override
  Future<void> dispose() async {
    final CameraController? c = _controller;
    _controller = null;
    await c?.dispose();
  }
}
