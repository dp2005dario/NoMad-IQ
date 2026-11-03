// "¿Dónde está tu hotel?" (Eventos → "Cerca de tu hotel").
//
// Tres maneras de decirlo, de la más cómoda a la más manual:
//   1. El hotel que pusiste en Modo fácil (nombre o dirección).
//   2. Tus reservas guardadas en la Bóveda (se abre con tu huella).
//   3. Escribir el nombre o la dirección y buscarlo.
// Y siempre: "Marcarlo yo en el mapa" con la diana.
//
// IMPORTANTE (honestidad): la app NO lee el documento de la reserva (es una
// foto o un PDF cifrado y sacar de ahí el nombre del hotel fallaría mucho).
// Usa el TÍTULO que tú escribiste al guardarla ("Hotel Avenida Palace") y lo
// busca en OpenStreetMap; luego eres tú quien elige el resultado bueno. Nada
// se guarda sin que lo toques.
//
// Buscar por nombre necesita cuenta (lo hace el servidor). Sin cuenta solo
// queda marcarlo en el mapa.
import 'dart:async';

import 'package:flutter/material.dart';

import '../../auth/session.dart';
import '../../core/api_client.dart';
import '../../core/services.dart';
import '../../core/theme.dart';
import '../../l10n/generated/app_localizations.dart';
import '../easy/easy_mode.dart';
import '../map/geo.dart';
import '../map/geocode_api.dart';
import '../vault/vault.dart';

/// Lo que eligió la persona en la hoja.
sealed class HotelChoice {
  const HotelChoice();
}

/// Un sitio encontrado en la búsqueda.
class HotelFound extends HotelChoice {
  const HotelFound(this.point);

  final GeoPoint point;
}

/// "Marcarlo yo en el mapa".
class HotelOnMap extends HotelChoice {
  const HotelOnMap();
}

/// Abre la hoja. [near] es el centro de la ciudad (para buscar ahí cerca).
Future<HotelChoice?> showHotelSheet(BuildContext context, GeoPoint near) =>
    showModalBottomSheet<HotelChoice>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => HotelSheet(near: near),
    );

class HotelSheet extends StatefulWidget {
  const HotelSheet({super.key, required this.near});

  final GeoPoint near;

  @override
  State<HotelSheet> createState() => _HotelSheetState();
}

class _HotelSheetState extends State<HotelSheet> {
  final TextEditingController _query = TextEditingController();
  List<GeoPlace>? _found;
  bool _searching = false;
  bool _failed = false;

  late final AppServices _services = ServicesScope.of(context);

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  /// Busca lo que hay escrito (o [text], si viene de una sugerencia).
  Future<void> _search([String? text]) async {
    if (text != null) _query.text = text;
    String q = _query.text.trim();
    if (q.length < 3 || _searching) return;
    // El servidor acepta hasta 200 letras.
    if (q.length > 200) q = q.substring(0, 200);
    setState(() => (_searching = true, _failed = false, _found = null));
    List<GeoPlace>? found;
    try {
      found = await _services.geocode.search(q, near: widget.near);
    } on ApiException {
      found = null;
    }
    if (!mounted) return;
    setState(() {
      _searching = false;
      _found = found;
      _failed = found == null;
    });
  }

  /// Abre la Bóveda con la huella para ver las reservas.
  Future<void> _openVault(AppLocalizations t) async {
    await _services.vault.open(t.vaultUnlockReason);
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    final TextTheme text = Theme.of(context).textTheme;
    final bool guest =
        SessionScope.of(context).status != SessionStatus.signedIn;
    final EasyTrip easy = loadEasyTrip(_services.prefs);
    final String? easyQuery = easy.hotelAddress ?? easy.hotelName;
    final Vault vault = _services.vault;
    final List<VaultDoc> bookings = <VaultDoc>[
      if (vault.isOpen)
        for (final VaultDoc d in vault.docs)
          if (d.kind == DocKind.booking) d,
    ];
    final double keyboard = MediaQuery.viewInsetsOf(context).bottom;

    return Padding(
      padding: EdgeInsets.fromLTRB(20, 0, 20, 16 + keyboard),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(t.eventsHotelTitle, style: text.titleLarge),
            const SizedBox(height: 12),
            if (guest)
              Text(t.eventsHotelGuest, style: text.bodyMedium)
            else ...<Widget>[
              // 1. El hotel de Modo fácil.
              if (easyQuery != null) ...<Widget>[
                Text(t.eventsHotelFromEasy, style: text.labelLarge),
                const SizedBox(height: 6),
                Wrap(
                  children: <Widget>[
                    ActionChip(
                      avatar: const Icon(Icons.hotel_rounded, size: 18),
                      label: Text(
                        easy.hotelName ?? easyQuery,
                        overflow: TextOverflow.ellipsis,
                      ),
                      onPressed: () => unawaited(_search(easyQuery)),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
              ],
              // 2. Las reservas de la Bóveda.
              Text(t.eventsHotelFromVault, style: text.labelLarge),
              const SizedBox(height: 6),
              if (!vault.isOpen)
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: OutlinedButton.icon(
                    onPressed: () => unawaited(_openVault(t)),
                    icon: const Icon(Icons.lock_open_rounded),
                    label: Text(t.eventsHotelOpenVault),
                  ),
                )
              else
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: <Widget>[
                    for (final VaultDoc d in bookings)
                      ActionChip(
                        avatar: const Icon(Icons.description_rounded, size: 18),
                        label: Text(d.title, overflow: TextOverflow.ellipsis),
                        onPressed: () => unawaited(_search(d.title)),
                      ),
                  ],
                ),
              const SizedBox(height: 6),
              Text(
                t.eventsHotelHonest,
                style: text.bodySmall?.copyWith(color: NomadColors.textMuted),
              ),
              const SizedBox(height: 12),
              // 3. Escribirlo y buscar.
              TextField(
                controller: _query,
                maxLength: 200,
                textInputAction: TextInputAction.search,
                onSubmitted: (_) => unawaited(_search()),
                decoration: InputDecoration(
                  hintText: t.eventsHotelSearchHint,
                  counterText: '',
                  prefixIcon: const Icon(Icons.search_rounded),
                ),
              ),
              const SizedBox(height: 8),
              if (_searching)
                const Center(
                  child: Padding(
                    padding: EdgeInsets.all(12),
                    child: CircularProgressIndicator(),
                  ),
                )
              else if (_failed)
                Text(t.eventsHotelError, style: text.bodyMedium)
              else if (_found != null && _found!.isEmpty)
                Text(t.eventsHotelNone, style: text.bodyMedium)
              else if (_found != null) ...<Widget>[
                for (final GeoPlace p in _found!)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.place_rounded),
                    title: Text(p.name),
                    subtitle: Text(
                      p.address,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    onTap: () => Navigator.of(context).pop(HotelFound(p.point)),
                  ),
                Text(
                  t.eventsHotelSource,
                  style: text.bodySmall?.copyWith(color: NomadColors.textMuted),
                ),
              ],
            ],
            const SizedBox(height: 8),
            // Siempre: marcarlo a mano.
            TextButton.icon(
              onPressed: () => Navigator.of(context).pop(const HotelOnMap()),
              icon: const Icon(Icons.my_location_rounded),
              label: Text(t.eventsHotelOnMap),
            ),
          ],
        ),
      ),
    );
  }
}
