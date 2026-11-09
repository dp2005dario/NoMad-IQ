// Elegir un contacto de emergencia de la AGENDA del móvil.
//
// Se abre la pantalla de contactos del propio móvil (la del sistema): la
// persona toca un contacto y un número, y solo ese nombre y ese número
// llegan a la app. Por eso no hace falta pedir permiso para leer toda la
// agenda: la app nunca ve los demás contactos.
import 'package:flutter_native_contact_picker/flutter_native_contact_picker.dart';
import 'package:flutter_native_contact_picker/model/contact.dart';

import 'sos_store.dart';

/// Abre la agenda y devuelve el contacto elegido (null = no eligió nada).
typedef PickPhoneContact = Future<SosContact?> Function();

/// La de verdad: la pantalla de contactos del móvil.
Future<SosContact?> pickPhoneContact() async {
  final Contact? c;
  try {
    c = await FlutterNativeContactPicker().selectPhoneNumber();
  } on Object {
    // Sin agenda (o la persona cerró la pantalla de golpe): como "nada".
    return null;
  }
  return contactFromPhone(
    c?.fullName,
    c?.selectedPhoneNumber ?? c?.phoneNumbers?.firstOrNull,
  );
}

/// Convierte lo que da la agenda en un contacto de emergencia. Los
/// números de la agenda traen espacios, guiones o paréntesis: se quitan
/// (el "+" del principio se queda). Si no hay número válido, null.
SosContact? contactFromPhone(String? name, String? phone) {
  final String raw = (phone ?? '').trim();
  final String clean =
      (raw.startsWith('+') ? '+' : '') + raw.replaceAll(RegExp(r'[^0-9]'), '');
  if (!SosContact.isPhone(clean)) return null;
  final String n = (name ?? '').trim();
  return SosContact(name: n.isEmpty ? clean : n, phone: clean);
}
