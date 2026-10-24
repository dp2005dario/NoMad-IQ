// De dónde entran los documentos a la Bóveda y cómo se lee su texto.
//
// - Foto con la cámara (el papel delante) o de la galería: JPEG.
// - Un PDF del móvil (la póliza del seguro, la tarjeta de embarque).
// El texto se lee DENTRO del móvil con ML Kit (como el ticket de la cena):
// así luego se le puede preguntar a la póliza "¿cubre la maleta perdida?"
// sin mandarla a nadie. Los PDF se convierten página a página en imagen
// (con el lector de PDF de Android) y se leen igual.
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdfx/pdfx.dart';

enum DocOrigin { camera, gallery, pdf }

/// Lo que se ha elegido: los bytes y su tipo.
class PickedDoc {
  const PickedDoc({required this.bytes, required this.mime, this.name});

  final Uint8List bytes;

  /// "image/jpeg" o "application/pdf".
  final String mime;

  /// El nombre del fichero (para proponer un título).
  final String? name;
}

abstract interface class DocSource {
  /// null = el usuario canceló.
  Future<PickedDoc?> pick(DocOrigin origin);
}

abstract interface class DocTextReader {
  /// El texto de cada página (como mucho [maxPages]). Si no se puede leer,
  /// devuelve lo que pueda (o una lista vacía): leer es una ayuda, no un
  /// requisito para guardar el documento.
  Future<List<String>> read(PickedDoc doc);

  /// Cuántas páginas tiene (1 para una foto).
  Future<int> pages(PickedDoc doc);

  /// Las páginas de un PDF como imágenes, para verlo en pantalla.
  Future<List<Uint8List>> render(Uint8List pdf);
}

/// Páginas de un PDF que se leen como mucho (una póliza larga tiene 40).
const int maxReadPages = 60;

class NoDocSource implements DocSource {
  const NoDocSource();

  @override
  Future<PickedDoc?> pick(DocOrigin origin) async => null;
}

class NoDocTextReader implements DocTextReader {
  const NoDocTextReader();

  @override
  Future<List<String>> read(PickedDoc doc) async => const <String>[];

  @override
  Future<int> pages(PickedDoc doc) async => 1;

  @override
  Future<List<Uint8List>> render(Uint8List pdf) async => const <Uint8List>[];
}

class DeviceDocSource implements DocSource {
  DeviceDocSource({ImagePicker? picker}) : _picker = picker ?? ImagePicker();

  final ImagePicker _picker;

  @override
  Future<PickedDoc?> pick(DocOrigin origin) async {
    if (origin == DocOrigin.pdf) {
      final PlatformFile? f = await FilePicker.pickFile(
        type: FileType.custom,
        allowedExtensions: <String>['pdf'],
      );
      if (f == null) return null;
      try {
        final int? size = await f.length();
        // Muy grande: ni se lee (la Bóveda lo rechazaría igualmente).
        if (size != null && size > 15 * 1024 * 1024) {
          return PickedDoc(
            bytes: Uint8List(0),
            mime: 'application/pdf',
            name: f.name,
          );
        }
        return PickedDoc(
          bytes: await f.readAsBytes(),
          mime: 'application/pdf',
          name: f.name,
        );
      } finally {
        // Si el selector hizo una copia en la caché de la app, se borra.
        final String? path = f.path;
        if (path != null &&
            path.startsWith((await getTemporaryDirectory()).path)) {
          await _deleteQuietly(path);
        }
      }
    }
    final XFile? photo = await _picker.pickImage(
      source: origin == DocOrigin.camera
          ? ImageSource.camera
          : ImageSource.gallery,
      maxWidth: 2000,
      maxHeight: 2000,
      imageQuality: 88,
      requestFullMetadata: false,
    );
    if (photo == null) return null;
    try {
      return PickedDoc(
        bytes: await photo.readAsBytes(),
        mime: 'image/jpeg',
        name: photo.name,
      );
    } finally {
      // La foto de la cámara queda en una carpeta temporal: se borra ya,
      // así el único ejemplar es el cifrado de la Bóveda.
      if (origin == DocOrigin.camera) await _deleteQuietly(photo.path);
    }
  }
}

class DeviceDocTextReader implements DocTextReader {
  const DeviceDocTextReader();

  @override
  Future<List<Uint8List>> render(Uint8List pdf) => renderPdf(pdf);

  @override
  Future<int> pages(PickedDoc doc) async {
    if (doc.mime != 'application/pdf') return 1;
    final PdfDocument pdf = await PdfDocument.openData(doc.bytes);
    try {
      return pdf.pagesCount;
    } finally {
      await pdf.close();
      await wipePdfTemp();
    }
  }

  @override
  Future<List<String>> read(PickedDoc doc) async {
    final TextRecognizer reader = TextRecognizer();
    try {
      if (doc.mime != 'application/pdf') {
        return <String>[await _ocr(reader, doc.bytes)];
      }
      final PdfDocument pdf = await PdfDocument.openData(doc.bytes);
      try {
        final List<String> out = <String>[];
        for (int n = 1; n <= pdf.pagesCount && n <= maxReadPages; n++) {
          final PdfPage page = await pdf.getPage(n);
          try {
            // ~1.600 px de ancho: de sobra para leer la letra pequeña.
            final double scale = 1600 / page.width;
            final PdfPageImage? image = await page.render(
              width: page.width * scale,
              height: page.height * scale,
              format: PdfPageImageFormat.jpeg,
              quality: 85,
            );
            out.add(image == null ? '' : await _ocr(reader, image.bytes));
          } finally {
            await page.close();
          }
        }
        return out;
      } finally {
        await pdf.close();
        await wipePdfTemp();
      }
    } on Exception {
      return const <String>[];
    } finally {
      await reader.close();
    }
  }

  /// ML Kit solo lee ficheros: la imagen se escribe un momento en la carpeta
  /// privada de la app y se borra nada más leerla.
  static Future<String> _ocr(TextRecognizer reader, Uint8List jpeg) async {
    final Directory dir = await getTemporaryDirectory();
    final File tmp = File(
      '${dir.path}/vault_ocr_${DateTime.now().microsecondsSinceEpoch}.jpg',
    );
    try {
      await tmp.writeAsBytes(jpeg, flush: true);
      final RecognizedText text = await reader.processImage(
        InputImage.fromFilePath(tmp.path),
      );
      return text.text;
    } finally {
      await _deleteQuietly(tmp.path);
    }
  }
}

/// El lector de PDF de Android (paquete pdfx) necesita el PDF en un fichero:
/// deja una copia en la caché privada de la app (y las páginas en
/// "pdf_renderer_cache"). Esta función las borra en cuanto terminamos, para
/// que el único ejemplar del documento siga siendo el cifrado.
Future<void> wipePdfTemp() async {
  try {
    final Directory dir = await getTemporaryDirectory();
    await for (final FileSystemEntity e in dir.list()) {
      final String name = e.uri.pathSegments
          .where((String s) => s.isNotEmpty)
          .last;
      if ((e is File && name.endsWith('.pdf')) ||
          name == 'pdf_renderer_cache') {
        await e.delete(recursive: true);
      }
    }
  } on Exception {
    // Sin caché o sin permiso: nada que borrar.
  }
}

/// Renderiza las páginas de un PDF como imágenes (para verlo en pantalla).
Future<List<Uint8List>> renderPdf(
  Uint8List pdfBytes, {
  double width = 1400,
}) async {
  final PdfDocument pdf = await PdfDocument.openData(pdfBytes);
  try {
    final List<Uint8List> out = <Uint8List>[];
    for (int n = 1; n <= pdf.pagesCount && n <= maxReadPages; n++) {
      final PdfPage page = await pdf.getPage(n);
      try {
        final PdfPageImage? image = await page.render(
          width: width,
          height: width * page.height / page.width,
          format: PdfPageImageFormat.jpeg,
          quality: 85,
        );
        if (image != null) out.add(image.bytes);
      } finally {
        await page.close();
      }
    }
    return out;
  } finally {
    await pdf.close();
    await wipePdfTemp();
  }
}

Future<void> _deleteQuietly(String path) async {
  try {
    await File(path).delete();
  } on FileSystemException {
    // Ya no estaba: nada que hacer.
  }
}
