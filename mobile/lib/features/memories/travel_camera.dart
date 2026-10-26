// La cámara de viaje: fotos (con la pegatina del viaje encima) y vídeos
// cortos. Detrás de una interfaz, como la cámara de monumentos, para poder
// probar la pantalla sin hardware.
import 'dart:async';
import 'dart:ui' as ui;

import 'package:camera/camera.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../camera/camera_device.dart' show CameraStart;

abstract interface class TravelCamera {
  /// [video] = también el micrófono (solo se pide al pasar a VÍDEO).
  Future<CameraStart> start({required bool video});

  Widget preview();

  /// Una foto en JPEG.
  Future<Uint8List> takePhoto();

  Future<void> startVideo();

  /// Para el vídeo y devuelve dónde lo dejó la cámara (un archivo temporal).
  Future<String> stopVideo();

  /// Cambia entre la cámara de atrás y la de delante (selfie).
  Future<void> flip();

  Future<void> dispose();
}

typedef TravelCameraFactory = TravelCamera Function();

class DeviceTravelCamera implements TravelCamera {
  CameraController? _controller;
  bool _front = false;
  bool _video = false;

  @override
  Future<CameraStart> start({required bool video}) async {
    _video = video;
    try {
      final List<CameraDescription> cameras = await availableCameras();
      if (cameras.isEmpty) return CameraStart.missing;
      final CameraLensDirection want = _front
          ? CameraLensDirection.front
          : CameraLensDirection.back;
      final CameraDescription lens = cameras.firstWhere(
        (CameraDescription c) => c.lensDirection == want,
        orElse: () => cameras.first,
      );
      await _controller?.dispose();
      final CameraController controller = CameraController(
        lens,
        // 720p: se ve bien en una historia y no llena el móvil.
        ResolutionPreset.high,
        enableAudio: video,
        imageFormatGroup: ImageFormatGroup.jpeg,
      );
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
    return ClipRect(
      child: FittedBox(
        fit: BoxFit.cover,
        child: SizedBox(
          width: c.value.previewSize?.height ?? 720,
          height: c.value.previewSize?.width ?? 1280,
          child: CameraPreview(c),
        ),
      ),
    );
  }

  CameraController get _c {
    final CameraController? c = _controller;
    if (c == null) throw StateError('la cámara no está encendida');
    return c;
  }

  @override
  Future<Uint8List> takePhoto() async => (await _c.takePicture()).readAsBytes();

  @override
  Future<void> startVideo() => _c.startVideoRecording();

  @override
  Future<String> stopVideo() async => (await _c.stopVideoRecording()).path;

  @override
  Future<void> flip() async {
    _front = !_front;
    await start(video: _video);
  }

  @override
  Future<void> dispose() async {
    final CameraController? c = _controller;
    _controller = null;
    await c?.dispose();
  }
}

/// Pinta la pegatina del viaje encima de la foto y devuelve un PNG.
///
/// [lines]: la primera en pequeño ("NOMADIQ · DÍA 2"), la segunda grande
/// ("MADRID") y el resto debajo ("22 oct 2026 · atardecer").
Future<Uint8List> stickerPhoto(Uint8List jpeg, List<String> lines) async {
  final ui.Codec codec = await ui.instantiateImageCodec(jpeg);
  final ui.Image photo = (await codec.getNextFrame()).image;
  final double w = photo.width.toDouble();
  final double h = photo.height.toDouble();
  final ui.PictureRecorder rec = ui.PictureRecorder();
  final Canvas canvas = Canvas(rec);
  canvas.drawImage(photo, Offset.zero, Paint());

  // La pegatina mide un 6 % del lado corto por línea, abajo a la izquierda.
  final double unit = (w < h ? w : h) / 100;
  final List<TextPainter> painters = <TextPainter>[
    for (int i = 0; i < lines.length; i++)
      TextPainter(
        text: TextSpan(
          text: lines[i],
          style: TextStyle(
            color: i == 0 ? const Color(0xFF3DDC97) : const Color(0xFFFFFFFF),
            fontSize: unit * (i == 1 ? 7 : 3.4),
            fontWeight: i == 1 ? FontWeight.w900 : FontWeight.w700,
            letterSpacing: i == 0 ? unit * 0.4 : 0,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: w - unit * 16),
  ];
  final double boxW =
      painters.fold(
        0.0,
        (double m, TextPainter p) => p.width > m ? p.width : m,
      ) +
      unit * 8;
  final double boxH =
      painters.fold(0.0, (double s, TextPainter p) => s + p.height) + unit * 6;
  final Rect box = Rect.fromLTWH(unit * 4, h - boxH - unit * 4, boxW, boxH);
  canvas.drawRRect(
    RRect.fromRectAndRadius(box, Radius.circular(unit * 3)),
    Paint()..color = const Color(0xB30B1217),
  );
  double y = box.top + unit * 3;
  for (final TextPainter p in painters) {
    p.paint(canvas, Offset(box.left + unit * 4, y));
    y += p.height;
  }
  final ui.Image out = await rec.endRecording().toImage(
    photo.width,
    photo.height,
  );
  final ByteData? png = await out.toByteData(format: ui.ImageByteFormat.png);
  photo.dispose();
  out.dispose();
  if (png == null) throw StateError('no se pudo pintar la pegatina');
  return png.buffer.asUint8List();
}
