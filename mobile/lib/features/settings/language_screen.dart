// Elegir idioma (maqueta 46). Lista TODOS los idiomas que trae la app,
// cada uno escrito en su propio idioma, con buscador.
import 'package:flutter/material.dart';

import '../../core/languages.dart';
import '../../core/settings.dart';
import '../../core/theme.dart';
import '../../l10n/generated/app_localizations.dart';

class LanguageScreen extends StatefulWidget {
  const LanguageScreen({super.key});

  @override
  State<LanguageScreen> createState() => _LanguageScreenState();
}

class _LanguageScreenState extends State<LanguageScreen> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    final SettingsController settings = SettingsScope.of(context);
    // La lista sale del código generado: añadir un .arb lo añade aquí solo.
    final List<Locale> locales = AppLocalizations.supportedLocales.toList()
      ..sort(
        (Locale a, Locale b) =>
            endonymFor(a.languageCode).compareTo(endonymFor(b.languageCode)),
      );
    final String q = _query.trim().toLowerCase();
    final List<Locale> shown = locales
        .where(
          (Locale l) =>
              q.isEmpty ||
              endonymFor(l.languageCode).toLowerCase().contains(q) ||
              l.toLanguageTag().toLowerCase().contains(q),
        )
        .toList();

    // RadioGroup: un solo idioma marcado a la vez. El valor null = "el del móvil".
    return Scaffold(
      appBar: AppBar(title: Text(t.languageTitle)),
      body: RadioGroup<String?>(
        groupValue: settings.locale?.toLanguageTag(),
        onChanged: (String? tag) =>
            settings.setLocale(tag == null ? null : Locale(tag)),
        child: ListView(
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: TextField(
                onChanged: (String v) => setState(() => _query = v),
                decoration: InputDecoration(
                  hintText: t.languageSearchHint,
                  prefixIcon: const Icon(Icons.search_rounded),
                ),
              ),
            ),
            if (q.isEmpty)
              RadioListTile<String?>(
                value: null,
                title: Text(t.languageSystem),
                secondary: const Icon(Icons.smartphone_rounded),
              ),
            for (final Locale l in shown)
              RadioListTile<String?>(
                value: l.toLanguageTag(),
                title: Text(endonymFor(l.languageCode)),
                subtitle: Text(
                  l.toLanguageTag(),
                  style: const TextStyle(color: NomadColors.textMuted),
                ),
              ),
            if (shown.isEmpty)
              Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  t.languageNoResults(_query.trim()),
                  textAlign: TextAlign.center,
                ),
              ),
          ],
        ),
      ),
    );
  }
}
