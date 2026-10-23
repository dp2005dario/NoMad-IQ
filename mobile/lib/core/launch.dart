// Abrir algo FUERA de la app: una web, el marcador para llamar o un SMS.
// Solo se permiten estos tres tipos: nada de abrir esquemas raros que otra
// app podría usar para engañarnos.
import 'package:url_launcher/url_launcher.dart';

typedef OpenExternal = Future<bool> Function(Uri url);

const Set<String> allowedSchemes = <String>{'https', 'tel', 'sms'};

Future<bool> openExternal(Uri url) async {
  if (!allowedSchemes.contains(url.scheme)) return false;
  try {
    return await launchUrl(url, mode: LaunchMode.externalApplication);
  } on Exception {
    return false;
  }
}
