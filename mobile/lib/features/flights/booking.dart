// Abrir la web de reserva de un vuelo.
//
// La reserva NO se hace dentro de NomadIQ: se abre la web del buscador
// (Aviasales) en el navegador, con nuestro identificador de afiliado en el
// enlace. Si el viajero compra, nos llevamos una comisión (sin pagar él más).
import 'package:url_launcher/url_launcher.dart';

/// Abre [url] fuera de la app. true = se abrió.
typedef OpenBooking = Future<bool> Function(Uri url);

/// La versión real: el navegador del móvil. Solo https (lo comprueba también
/// FaresApi al leer el enlace, pero dos cerraduras mejor que una).
Future<bool> openInBrowser(Uri url) async {
  if (url.scheme != 'https') return false;
  try {
    return await launchUrl(url, mode: LaunchMode.externalApplication);
  } on Exception {
    return false;
  }
}
