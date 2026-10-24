// Menú (maqueta "Menu"): el traductor de cartas de restaurante.
//
// Cómo funciona: haces una foto de la carta, el móvil lee el texto DENTRO
// del teléfono (ML Kit, sin red) y manda solo esas líneas al servidor, donde
// Flyra dice qué es cada plato, qué lleva, si tiene alérgenos frecuentes y
// cómo pedirlo en el idioma del sitio. La foto nunca sale del móvil.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../auth/session.dart';
import '../../core/api_client.dart';
import '../../core/languages.dart';
import '../../core/router.dart';
import '../../core/services.dart';
import '../../core/theme.dart';
import '../../l10n/generated/app_localizations.dart';
import '../money/receipt_scanner.dart';
import 'menu_api.dart';

/// Idiomas que se pueden elegir como "idioma del sitio". Son los que llevan
/// un alfabeto propio en el lector o los más habituales en una carta.
const List<String> menuLanguages = <String>[
  'ja',
  'zh',
  'ko',
  'th',
  'vi',
  'hi',
  'ar',
  'el',
  'tr',
  'ru',
  'es',
  'it',
  'fr',
  'pt',
  'de',
  'en',
];

/// Nombres de los idiomas que no están en [languageEndonyms].
const Map<String, String> _extraNames = <String, String>{
  'ko': '한국어',
  'th': 'ไทย',
  'vi': 'Tiếng Việt',
  'el': 'Ελληνικά',
  'tr': 'Türkçe',
  'ru': 'Русский',
};

String menuLanguageName(String code) => _extraNames[code] ?? endonymFor(code);

class MenuScreen extends StatefulWidget {
  const MenuScreen({super.key});

  @override
  State<MenuScreen> createState() => _MenuScreenState();
}

class _MenuScreenState extends State<MenuScreen> {
  late final AppServices _services = ServicesScope.of(context);
  String _place = 'ja';
  MenuTranslation? _result;
  bool _reading = false;
  ApiError? _error;
  bool _nothingRead = false;

  bool get _guest => SessionScope.of(context).status != SessionStatus.signedIn;

  Future<void> _scan(ReceiptSource source) async {
    setState(() {
      _error = null;
      _nothingRead = false;
    });
    // 1) La foto y el texto: todo dentro del móvil.
    final List<String>? lines = await _services.receipts.scan(
      source,
      language: _place,
    );
    if (lines == null || !mounted) return; // canceló
    if (lines.isEmpty) {
      setState(() => _nothingRead = true);
      return;
    }
    // 2) Solo el texto va al servidor, y se recorta a lo que acepta.
    setState(() {
      _reading = true;
      _result = null;
    });
    try {
      final MenuTranslation found = await _services.menu.translate(
        lines: lines.take(80).toList(),
        language: Localizations.localeOf(context).toLanguageTag(),
        placeLanguage: _place,
      );
      if (mounted) {
        setState(() {
          _result = found;
          _reading = false;
        });
      }
    } on ApiException catch (e) {
      if (mounted) {
        setState(() {
          _reading = false;
          _error = e.error;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    final TextTheme text = Theme.of(context).textTheme;
    if (_guest) {
      return Scaffold(
        appBar: AppBar(title: Text(t.menuTitle)),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(t.menuSignIn, textAlign: TextAlign.center),
                const SizedBox(height: 16),
                FilledButton(
                  onPressed: () => context.push(Routes.signIn),
                  child: Text(t.signInFromGuest),
                ),
              ],
            ),
          ),
        ),
      );
    }
    final MenuTranslation? result = _result;
    return Scaffold(
      appBar: AppBar(title: Text(t.menuTitle)),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
        children: <Widget>[
          Text(
            t.menuSubtitle,
            style: text.bodyMedium?.copyWith(color: NomadColors.textMuted),
          ),
          const SizedBox(height: 16),
          DropdownButtonFormField<String>(
            initialValue: _place,
            decoration: InputDecoration(labelText: t.menuPlaceLanguage),
            items: <DropdownMenuItem<String>>[
              for (final String code in menuLanguages)
                DropdownMenuItem<String>(
                  value: code,
                  child: Text(menuLanguageName(code)),
                ),
            ],
            onChanged: (String? code) {
              if (code != null) setState(() => _place = code);
            },
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: _reading
                ? null
                : () => unawaited(_scan(ReceiptSource.camera)),
            icon: const Icon(Icons.photo_camera_rounded),
            label: Text(t.menuTakePhoto),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: _reading
                ? null
                : () => unawaited(_scan(ReceiptSource.gallery)),
            icon: const Icon(Icons.photo_library_rounded),
            label: Text(t.menuFromGallery),
          ),
          if (_reading)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 32),
              child: Column(
                children: <Widget>[
                  const CircularProgressIndicator(),
                  const SizedBox(height: 12),
                  Text(t.menuReading),
                ],
              ),
            ),
          if (_nothingRead)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 24),
              child: Text(t.menuNothingRead),
            ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 24),
              child: Text(switch (_error!) {
                // 429 = se acabaron las cartas de hoy.
                ApiError.rateLimited => t.menuOutOfCards,
                ApiError.network => t.errorNetwork,
                _ => t.errorUnavailable,
              }, style: const TextStyle(color: NomadColors.safety)),
            ),
          if (result != null) ...<Widget>[
            const SizedBox(height: 24),
            if (result.dishes.isEmpty)
              Text(t.menuNoDishes)
            else ...<Widget>[
              Text(
                t.menuTapADish,
                style: text.bodySmall?.copyWith(color: NomadColors.textMuted),
              ),
              const SizedBox(height: 8),
              for (final Dish dish in result.dishes)
                _DishTile(dish: dish, onTap: () => _show(dish)),
              const SizedBox(height: 12),
              Text(
                t.menuLeftToday(result.remainingToday),
                style: text.bodySmall?.copyWith(color: NomadColors.textMuted),
              ),
            ],
          ],
        ],
      ),
    );
  }

  Future<void> _show(Dish dish) => showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (_) => _DishSheet(dish: dish, services: _services, place: _place),
  );
}

/// Una línea de la carta: el nombre original, lo que es y su precio.
class _DishTile extends StatelessWidget {
  const _DishTile({required this.dish, required this.onTap});

  final Dish dish;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: ListTile(
        onTap: onTap,
        title: Text(dish.original),
        subtitle: Text(dish.name),
        trailing: dish.price.isEmpty
            ? const Icon(Icons.chevron_right_rounded)
            : Text(
                dish.price,
                style: Theme.of(context).textTheme.titleMedium
                    ?.copyWith(color: NomadColors.money),
              ),
      ),
    );
  }
}

/// La ficha de un plato: qué es, alérgenos y cómo pedirlo (con voz).
class _DishSheet extends StatefulWidget {
  const _DishSheet({
    required this.dish,
    required this.services,
    required this.place,
  });

  final Dish dish;
  final AppServices services;
  final String place;

  @override
  State<_DishSheet> createState() => _DishSheetState();
}

class _DishSheetState extends State<_DishSheet> {
  bool _speaking = false;

  @override
  void dispose() {
    if (_speaking) unawaited(widget.services.speaker.stop());
    super.dispose();
  }

  /// Lee la frase EN EL IDIOMA DEL SITIO: es para que la oiga el camarero.
  Future<void> _say() async {
    if (_speaking) {
      await widget.services.speaker.stop();
      if (mounted) setState(() => _speaking = false);
      return;
    }
    setState(() => _speaking = true);
    await widget.services.speaker.speak(widget.dish.orderPhrase, widget.place);
    if (mounted) setState(() => _speaking = false);
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    final TextTheme text = Theme.of(context).textTheme;
    final Dish d = widget.dish;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(d.original, style: text.titleMedium),
            Text(d.name, style: text.headlineSmall),
            if (d.price.isNotEmpty)
              Text(
                d.price,
                style: text.titleLarge?.copyWith(color: NomadColors.money),
              ),
            if (d.description.isNotEmpty) ...<Widget>[
              const SizedBox(height: 12),
              Text(d.description, style: text.bodyLarge),
            ],
            if (d.allergens.isNotEmpty) ...<Widget>[
              const SizedBox(height: 12),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  const Icon(
                    Icons.warning_amber_rounded,
                    color: NomadColors.safety,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      d.allergens,
                      style: const TextStyle(color: NomadColors.safety),
                    ),
                  ),
                ],
              ),
            ],
            const SizedBox(height: 4),
            Text(
              t.menuAllergenNote,
              style: text.bodySmall?.copyWith(color: NomadColors.textMuted),
            ),
            if (d.orderPhrase.isNotEmpty) ...<Widget>[
              const SizedBox(height: 20),
              Text(
                t.menuOrderLike,
                style: const TextStyle(
                  color: NomadColors.textMuted,
                  fontSize: 11,
                  letterSpacing: 1.2,
                ),
              ),
              const SizedBox(height: 4),
              Text(d.orderPhrase, style: text.titleLarge),
              if (d.orderSounds.isNotEmpty)
                Text(
                  d.orderSounds,
                  style: const TextStyle(color: NomadColors.mint),
                ),
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed: _say,
                icon: Icon(
                  _speaking ? Icons.stop_rounded : Icons.volume_up_rounded,
                ),
                label: Text(_speaking ? t.cameraStopListening : t.cameraListen),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
