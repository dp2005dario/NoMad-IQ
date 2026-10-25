// Elegir un punto en el mapa ("¿adónde vas?"): mueves el mapa hasta que la
// diana quede encima del sitio (Disneyland, el Coliseo...) y pulsas el botón.
// Devuelve el centro de lo que se ve.
import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/services.dart';
import '../../core/theme.dart';
import '../../l10n/generated/app_localizations.dart';
import '../map/geo.dart';
import '../map/map_screen.dart';
import '../map/map_style.dart';
import '../map/map_surface.dart';

class PickPointScreen extends StatefulWidget {
  const PickPointScreen({super.key, this.initial});

  final GeoPoint? initial;

  @override
  State<PickPointScreen> createState() => _PickPointScreenState();
}

class _PickPointScreenState extends State<PickPointScreen> {
  late final AppServices _services = ServicesScope.of(context);
  MapSurfaceController? _map;
  Map<String, Object?>? _style;

  Future<void> _use() async {
    final GeoBox? box = await _map?.visibleBox();
    if (!mounted || box == null) return;
    Navigator.of(context).pop(box.center);
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    _style ??= buildMapStyle(
      look: resolveLook(MapLook.auto, DateTime.now()),
      language: Localizations.localeOf(context).languageCode,
      tilesUrl: _services.tilesUrl,
      glyphsUrl: _services.glyphsUrl,
    );
    return Scaffold(
      appBar: AppBar(title: Text(t.staysPickTitle)),
      body: Stack(
        children: <Widget>[
          Positioned.fill(
            child: _services.mapSurface(
              MapSurfaceSpec(
                style: _style!,
                initialCenter: widget.initial ?? MapScreen.defaultCenter,
                initialZoom: widget.initial == null ? 4 : 12,
                onReady: (MapSurfaceController c) => _map = c,
                onIdle: () {},
                // Tocar un sitio = centrar el mapa ahí.
                onTap: (GeoPoint p) => unawaited(_map?.flyTo(p)),
              ),
            ),
          ),
          // La diana del centro: lo que haya debajo es "el sitio".
          const IgnorePointer(
            child: Center(
              child: Icon(
                Icons.add_location_alt_rounded,
                size: 44,
                color: NomadColors.money,
              ),
            ),
          ),
          Positioned(
            left: 16,
            right: 16,
            bottom: 24,
            child: SafeArea(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Text(t.staysPickHint),
                    ),
                  ),
                  const SizedBox(height: 8),
                  FilledButton.icon(
                    icon: const Icon(Icons.check_rounded),
                    label: Text(t.staysPickUse),
                    onPressed: () => unawaited(_use()),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
