// Abrir algo FUERA de la app: una web, el marcador para llamar, un SMS o un
// correo ya escrito.
// Solo se permiten estos cuatro tipos: nada de abrir esquemas raros que otra
// app podría usar para engañarnos.
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

typedef OpenExternal = Future<bool> Function(Uri url);

const Set<String> allowedSchemes = <String>{'https', 'tel', 'sms', 'mailto'};

Future<bool> openExternal(Uri url) async {
  if (!allowedSchemes.contains(url.scheme)) return false;
  try {
    return await launchUrl(url, mode: LaunchMode.externalApplication);
  } on Exception {
    return false;
  }
}

/// "Compartir": abre el menú del móvil con estos archivos (Instagram,
/// WhatsApp, Guardar en Fotos...). La persona elige a dónde van.
typedef ShareFiles = Future<void> Function(List<String> paths, {String? text});

Future<void> shareFiles(List<String> paths, {String? text}) async {
  await SharePlus.instance.share(
    ShareParams(
      files: <XFile>[for (final String p in paths) XFile(p)],
      text: text,
    ),
  );
}
