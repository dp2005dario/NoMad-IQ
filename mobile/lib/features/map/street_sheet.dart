// "VER LA CALLE DE VERDAD": fotos reales a pie de calle del sitio que miras
// en el mapa. El mapa 3D es un dibujo; esto es cómo es la calle de verdad.
//
// Las fotos son de Mapillary: las hace gente de todo el mundo y se pueden
// reutilizar gratis (licencia CC BY-SA 4.0) a cambio de decir quién las
// hizo y de dónde salen (las líneas de abajo y el botón "Abrir en Mapillary").
//
// Cómo se usa:
//   - Arriba, la foto grande. Deslizas el dedo para pasar a la siguiente.
//   - Tocarla la abre a pantalla completa: puedes ampliar con dos dedos y,
//     si es una panorámica de 360°, arrastrar para mirar alrededor.
//   - Debajo, las miniaturas de todas (tocar una salta a ella).
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/theme.dart';
import '../../l10n/generated/app_localizations.dart';
import '../flights/booking.dart';
import 'geo.dart';
import 'street_photos_api.dart';

class StreetSheet extends StatefulWidget {
  const StreetSheet({
    super.key,
    required this.point,
    required this.load,
    required this.openLink,
  });

  /// El centro del mapa cuando se pulsó el botón.
  final GeoPoint point;
  final StreetPhotoLoader load;
  final OpenBooking openLink;

  @override
  State<StreetSheet> createState() => _StreetSheetState();
}

class _StreetSheetState extends State<StreetSheet> {
  late final Future<StreetPhotos?> _photos = widget.load(widget.point);

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.8,
      maxChildSize: 0.95,
      builder: (BuildContext context, ScrollController scroll) =>
          FutureBuilder<StreetPhotos?>(
            future: _photos,
            builder: (BuildContext context, AsyncSnapshot<StreetPhotos?> snap) {
              if (snap.connectionState != ConnectionState.done) {
                return const Center(child: CircularProgressIndicator());
              }
              final StreetPhotos? found = snap.data;
              final String? problem = snap.hasError || found == null
                  ? t.streetViewUnavailable
                  : found.photos.isEmpty
                  ? t.streetViewNone
                  : null;
              if (problem != null) {
                return ListView(
                  controller: scroll,
                  padding: const EdgeInsets.all(24),
                  children: <Widget>[
                    const Icon(
                      Icons.photo_camera_back_rounded,
                      size: 40,
                      color: NomadColors.textMuted,
                    ),
                    const SizedBox(height: 12),
                    Text(
                      problem,
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: NomadColors.textMuted),
                    ),
                  ],
                );
              }
              return _Gallery(
                found: found!,
                scroll: scroll,
                openLink: widget.openLink,
              );
            },
          ),
    );
  }
}

class _Gallery extends StatefulWidget {
  const _Gallery({
    required this.found,
    required this.scroll,
    required this.openLink,
  });

  final StreetPhotos found;
  final ScrollController scroll;
  final OpenBooking openLink;

  @override
  State<_Gallery> createState() => _GalleryState();
}

class _GalleryState extends State<_Gallery> {
  final PageController _pages = PageController();
  int _current = 0;

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  void _jump(int i) {
    setState(() => _current = i);
    _pages.animateToPage(
      i,
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOut,
    );
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    final List<StreetPhoto> photos = widget.found.photos;
    final StreetPhoto photo = photos[_current];
    return ListView(
      controller: widget.scroll,
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
      children: <Widget>[
        Text(
          t.streetViewTitle,
          style: Theme.of(context).textTheme.titleLarge?.copyWith(
            fontFamily: NomadFonts.display,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 12),
        // La foto grande: se pasa de una a otra deslizando.
        SizedBox(
          height: 260,
          child: PageView.builder(
            controller: _pages,
            itemCount: photos.length,
            onPageChanged: (int i) => setState(() => _current = i),
            itemBuilder: (BuildContext context, int i) => Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2),
              child: _BigPhoto(
                photo: photos[i],
                onOpen: () => _openFull(context, photos[i]),
              ),
            ),
          ),
        ),
        const SizedBox(height: 10),
        _Details(photo: photo, openLink: widget.openLink),
        if (photos.length > 1) ...<Widget>[
          const SizedBox(height: 12),
          SizedBox(
            height: 64,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: photos.length,
              separatorBuilder: (_, _) => const SizedBox(width: 8),
              itemBuilder: (BuildContext context, int i) => _Thumb(
                photo: photos[i],
                selected: i == _current,
                onTap: () => _jump(i),
              ),
            ),
          ),
        ],
        const SizedBox(height: 16),
        Text(
          t.streetViewCredits,
          style: const TextStyle(color: NomadColors.textMuted, fontSize: 12),
        ),
      ],
    );
  }

  void _openFull(BuildContext context, StreetPhoto photo) {
    Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute<void>(
        fullscreenDialog: true,
        builder: (BuildContext context) => _FullPhoto(photo: photo),
      ),
    );
  }
}

/// La foto grande con sus etiquetas: año, "360°" y hacia dónde mira.
class _BigPhoto extends StatelessWidget {
  const _BigPhoto({required this.photo, required this.onOpen});

  final StreetPhoto photo;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final double? angle = photo.compassAngle;
    return GestureDetector(
      onTap: onOpen,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: Stack(
          fit: StackFit.expand,
          children: <Widget>[
            _NetPhoto(url: photo.imageUrl, fit: BoxFit.cover),
            if (photo.isPano)
              const PositionedDirectional(
                top: 10,
                start: 10,
                child: _Badge(child: Text('360°')),
              ),
            // Una flechita que apunta hacia donde miraba la cámara (con el
            // norte arriba, como el mapa).
            if (angle != null)
              PositionedDirectional(
                top: 10,
                end: 10,
                child: _Badge(
                  child: Transform.rotate(
                    angle: angle * math.pi / 180,
                    child: const Icon(Icons.navigation_rounded, size: 16),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _Details extends StatelessWidget {
  const _Details({required this.photo, required this.openLink});

  final StreetPhoto photo;
  final OpenBooking openLink;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    final List<String> lines = <String>[
      if (photo.creator case final String name) t.streetViewBy(name),
      if (photo.capturedAt case final DateTime taken)
        t.streetViewTaken('${taken.year}'),
      if (photo.isPano) t.streetViewPano,
    ];
    return Row(
      children: <Widget>[
        Expanded(
          child: Text(
            lines.join(' · '),
            style: const TextStyle(color: NomadColors.textMuted, fontSize: 13),
          ),
        ),
        TextButton.icon(
          onPressed: () => openLink(photo.pageUrl),
          icon: const Icon(Icons.open_in_new_rounded, size: 18),
          label: Text(t.streetViewOpen),
        ),
      ],
    );
  }
}

class _Thumb extends StatelessWidget {
  const _Thumb({
    required this.photo,
    required this.selected,
    required this.onTap,
  });

  final StreetPhoto photo;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: onTap,
    child: AnimatedContainer(
      duration: const Duration(milliseconds: 150),
      width: 88,
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: selected ? NomadColors.mint : NomadColors.outline,
          width: 2,
        ),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(9),
        child: _NetPhoto(url: photo.thumbUrl, fit: BoxFit.cover),
      ),
    ),
  );
}

/// A pantalla completa. Las fotos normales se amplían con dos dedos; las
/// panorámicas (el doble de anchas que de altas) se recorren arrastrando.
class _FullPhoto extends StatelessWidget {
  const _FullPhoto({required this.photo});

  final StreetPhoto photo;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        title: Text(photo.isPano ? t.streetViewPano : t.streetViewTitle),
      ),
      body: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints box) => photo.isPano
            ? SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: SizedBox(
                  height: box.maxHeight,
                  width: box.maxHeight * 2,
                  child: _NetPhoto(url: photo.imageUrl, fit: BoxFit.cover),
                ),
              )
            : InteractiveViewer(
                maxScale: 5,
                child: Center(
                  child: _NetPhoto(url: photo.imageUrl, fit: BoxFit.contain),
                ),
              ),
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
    decoration: BoxDecoration(
      color: Colors.black.withValues(alpha: 0.55),
      borderRadius: BorderRadius.circular(999),
    ),
    child: DefaultTextStyle.merge(
      style: const TextStyle(
        color: Colors.white,
        fontWeight: FontWeight.w700,
        fontSize: 12,
      ),
      child: IconTheme.merge(
        data: const IconThemeData(color: Colors.white),
        child: child,
      ),
    ),
  );
}

/// Una foto de internet. Si no carga (sin red), queda un hueco discreto.
class _NetPhoto extends StatelessWidget {
  const _NetPhoto({required this.url, required this.fit});

  final Uri url;
  final BoxFit fit;

  @override
  Widget build(BuildContext context) => Image.network(
    url.toString(),
    fit: fit,
    semanticLabel: AppLocalizations.of(context).streetViewPhotoLabel,
    loadingBuilder: (_, Widget child, ImageChunkEvent? progress) =>
        progress == null
        ? child
        : const ColoredBox(
            color: NomadColors.surface,
            child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
          ),
    errorBuilder: (_, _, _) => const ColoredBox(
      color: NomadColors.surface,
      child: Center(child: Icon(Icons.broken_image_outlined)),
    ),
  );
}
