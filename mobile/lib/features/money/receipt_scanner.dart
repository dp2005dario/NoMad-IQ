// "Escanear ticket": hace la foto con la cámara del sistema y lee el texto
// DENTRO del móvil con ML Kit de Google (gratis, sin red y sin cuenta).
//
// Privacidad: la foto nunca sale del teléfono. Se lee, se convierte en filas
// de texto y se borra el archivo temporal. Al servidor solo llegan las
// líneas que tú confirmas (nombre del plato y precio).
//
// En los tests se usa un escáner falso que devuelve filas inventadas.
import 'dart:io';
import 'dart:ui' show Rect;

import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:image_picker/image_picker.dart';

/// De dónde sale la foto del ticket.
enum ReceiptSource { camera, gallery }

abstract interface class ReceiptScanner {
  /// Las filas del texto de la foto, de arriba abajo, o null si la persona
  /// canceló.
  ///
  /// El alfabeto del lector se elige con [language] si se sabe el idioma del
  /// sitio (la carta del restaurante: "ja") y, si no, con [currency] (la del
  /// bote: un ticket en yenes casi seguro está en japonés).
  Future<List<String>?> scan(
    ReceiptSource source, {
    String currency = 'EUR',
    String? language,
  });
}

/// Un escáner que nunca lee nada (aparatos sin cámara y tests).
class NoReceiptScanner implements ReceiptScanner {
  const NoReceiptScanner();

  @override
  Future<List<String>?> scan(
    ReceiptSource source, {
    String currency = 'EUR',
    String? language,
  }) async => null;
}

class DeviceReceiptScanner implements ReceiptScanner {
  DeviceReceiptScanner({ImagePicker? picker})
    : _picker = picker ?? ImagePicker();

  final ImagePicker _picker;

  @override
  Future<List<String>?> scan(
    ReceiptSource source, {
    String currency = 'EUR',
    String? language,
  }) async {
    final XFile? photo = await _picker.pickImage(
      source: source == ReceiptSource.camera
          ? ImageSource.camera
          : ImageSource.gallery,
      // Un ticket se lee bien a 1600 px; más grande solo gasta memoria.
      maxWidth: 1600,
      maxHeight: 2400,
      imageQuality: 90,
      requestFullMetadata: false,
    );
    if (photo == null) return null;
    final TextRecognizer reader = TextRecognizer(
      script: scriptForLanguage(language) ?? scriptFor(currency),
    );
    try {
      final RecognizedText text = await reader.processImage(
        InputImage.fromFilePath(photo.path),
      );
      return _rowsOf(<_Piece>[
        for (final TextBlock block in text.blocks)
          for (final TextLine line in block.lines)
            _Piece(line.text, line.boundingBox),
      ]);
    } finally {
      await reader.close();
      // Solo se borra la copia temporal de la cámara, nunca una foto de
      // tu galería.
      if (source == ReceiptSource.camera) {
        try {
          await File(photo.path).delete();
        } on FileSystemException {
          // Si ya no estaba, no pasa nada.
        }
      }
    }
  }
}

/// El alfabeto del lector según la moneda del bote. Los lectores de chino,
/// japonés, coreano y devanagari también leen letras latinas y números.
/// El alfabeto por el idioma del sitio ("ja", "zh-Hans", "ko", "hi"); null
/// si no se sabe o si ese idioma se escribe en letras latinas.
TextRecognitionScript? scriptForLanguage(String? language) =>
    switch (language?.split('-').first) {
      'ja' => TextRecognitionScript.japanese,
      'zh' || 'yue' => TextRecognitionScript.chinese,
      'ko' => TextRecognitionScript.korean,
      'hi' || 'mr' || 'ne' => TextRecognitionScript.devanagiri,
      _ => null,
    };

TextRecognitionScript scriptFor(String currency) => switch (currency) {
  'JPY' => TextRecognitionScript.japanese,
  'CNY' || 'HKD' || 'TWD' || 'MOP' => TextRecognitionScript.chinese,
  'KRW' => TextRecognitionScript.korean,
  'INR' || 'NPR' => TextRecognitionScript.devanagiri,
  _ => TextRecognitionScript.latin,
};

class _Piece {
  const _Piece(this.text, this.box);

  final String text;
  final Rect box;
}

/// ML Kit lee el ticket por "bloques" (la columna de nombres por un lado y la
/// de precios por otro). Aquí se juntan los trozos que están a la MISMA
/// ALTURA para rehacer cada fila: "2 Croquetas" + "12,00".
List<String> _rowsOf(List<_Piece> pieces) {
  final List<_Piece> sorted = List<_Piece>.of(pieces)
    ..sort((_Piece a, _Piece b) => a.box.center.dy.compareTo(b.box.center.dy));
  final List<List<_Piece>> rows = <List<_Piece>>[];
  for (final _Piece p in sorted) {
    final List<_Piece>? last = rows.isEmpty ? null : rows.last;
    // Misma fila si su centro cae dentro de la altura del primer trozo.
    if (last != null &&
        (p.box.center.dy - last.first.box.center.dy).abs() <
            last.first.box.height * 0.6) {
      last.add(p);
    } else {
      rows.add(<_Piece>[p]);
    }
  }
  return <String>[
    for (final List<_Piece> row in rows)
      (row..sort((_Piece a, _Piece b) => a.box.left.compareTo(b.box.left)))
          .map((_Piece p) => p.text)
          .join('  '),
  ];
}
