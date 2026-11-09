// En qué idioma hablan Flyra y las audioguías. Normalmente, el de la app;
// pero en Idioma se puede apagar "Flyra y las audioguías también en este
// idioma": entonces se quedan en el que tenían (p. ej. la app en inglés para
// practicar y las audioguías en español para entenderlas bien).
import 'package:flutter/widgets.dart';

import 'services.dart';
import 'settings.dart';

/// El idioma de Flyra y las audioguías ("es").
String contentLanguage(BuildContext context) => contentLanguageFrom(
  ServicesScope.of(context).prefs.readData(LocalData.contentLang),
  Localizations.localeOf(context).languageCode,
);

/// Lo guardado si es un código válido; si no, el de la app.
String contentLanguageFrom(String? saved, String appLang) =>
    saved != null && RegExp(r'^[a-z]{2,3}$').hasMatch(saved) ? saved : appLang;
