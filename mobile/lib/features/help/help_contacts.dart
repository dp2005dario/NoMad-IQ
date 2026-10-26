// Con quién puede ponerte en contacto la pantalla "Ayuda". Cada dato es
// opcional: si no está (por ejemplo, aún no hay acuerdo con un gestor de
// visados), esa opción no se enseña en vez de llevar a un sitio vacío.
class HelpContacts {
  const HelpContacts({this.supportEmail, this.claimsUrl, this.visaUrl});

  /// El correo del equipo de ECLIPTA.
  final String? supportEmail;

  /// La web del socio que reclama retrasos y cancelaciones por ti.
  final Uri? claimsUrl;

  /// La web del socio que gestiona visados.
  final Uri? visaUrl;
}
