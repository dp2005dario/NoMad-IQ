// La FICHA DE CIUDAD (maqueta "Ruta": "por qué es famosa" y "lo más
// visitado"). Se abre desde la Ruta del vuelo, en el origen y al llegar.
//
// Los textos son de Wikipedia y las fotos de Wikimedia Commons: gratis y con
// licencia libre, a cambio de decir de dónde salen (la línea de abajo) y de
// enlazar cada foto con su autor (tocando la foto).
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../core/theme.dart';
import '../../l10n/generated/app_localizations.dart';
import '../flights/booking.dart';
import '../flights/flight_format.dart';
import 'places_api.dart';

/// Wikimedia pide que quien descarga sus fotos diga quién es.
const Map<String, String> _imageHeaders = <String, String>{
  'User-Agent': 'NomadIQ/1.0 (https://github.com/dp2005dario/NoMad-IQ)',
};

class CitySheet extends StatefulWidget {
  const CitySheet({
    super.key,
    required this.iata,
    required this.load,
    required this.openLink,
  });

  final String iata;
  final PlaceLoader load;
  final OpenBooking openLink;

  @override
  State<CitySheet> createState() => _CitySheetState();
}

class _CitySheetState extends State<CitySheet> {
  Future<PlaceCard?>? _card;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _card ??= widget.load(
      widget.iata,
      Localizations.localeOf(context).languageCode,
    );
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.75,
      maxChildSize: 0.95,
      builder: (BuildContext context, ScrollController scroll) =>
          FutureBuilder<PlaceCard?>(
            future: _card,
            builder: (BuildContext context, AsyncSnapshot<PlaceCard?> snap) {
              if (snap.connectionState != ConnectionState.done) {
                return const Center(child: CircularProgressIndicator());
              }
              final PlaceCard? card = snap.data;
              if (snap.hasError || card == null) {
                return Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(
                    t.placeUnavailable,
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: NomadColors.textMuted),
                  ),
                );
              }
              return _CardBody(
                card: card,
                scroll: scroll,
                openLink: widget.openLink,
              );
            },
          ),
    );
  }
}

class _CardBody extends StatelessWidget {
  const _CardBody({
    required this.card,
    required this.scroll,
    required this.openLink,
  });

  final PlaceCard card;
  final ScrollController scroll;
  final OpenBooking openLink;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    final TextTheme text = Theme.of(context).textTheme;
    final CountryFacts? country = card.country;
    final String lang = Localizations.localeOf(context).languageCode;
    final NumberFormat number = NumberFormat.decimalPattern(localeOf(context));
    return ListView(
      controller: scroll,
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
      children: <Widget>[
        if (card.photo case final PlacePhoto photo)
          _Photo(photo: photo, height: 180, openLink: openLink),
        const SizedBox(height: 12),
        Text(card.city, style: text.headlineSmall),
        if (country != null)
          Text(
            country.name,
            style: const TextStyle(color: NomadColors.textMuted),
          ),
        if (card.summary case final String summary) ...<Widget>[
          const SizedBox(height: 16),
          _Section(t.placeWhyFamous),
          Text(summary),
          if (card.summaryLanguage != null && card.summaryLanguage != lang)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                t.placeInEnglish,
                style: const TextStyle(
                  color: NomadColors.textMuted,
                  fontSize: 12,
                ),
              ),
            ),
          if (card.articleUrl case final Uri url)
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: TextButton(
                onPressed: () => openLink(url),
                child: Text(t.placeReadMore),
              ),
            ),
        ],
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: <Widget>[
            if (card.population case final int p)
              _Fact(t.placePopulation, number.format(p)),
            if (country?.capital case final String c) _Fact(t.placeCapital, c),
            if (country?.currency case final String c)
              _Fact(t.placeCurrency, c),
            if (country != null && country.languages.isNotEmpty)
              _Fact(t.placeLanguages, country.languages.join(', ')),
          ],
        ),
        if (card.attractions.isNotEmpty) ...<Widget>[
          const SizedBox(height: 20),
          _Section(t.placeMostVisited),
          SizedBox(
            height: 196,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: card.attractions.length,
              separatorBuilder: (_, _) => const SizedBox(width: 12),
              itemBuilder: (BuildContext context, int i) => _AttractionTile(
                attraction: card.attractions[i],
                openLink: openLink,
              ),
            ),
          ),
        ],
        const SizedBox(height: 16),
        Text(
          t.placeCredits,
          style: const TextStyle(color: NomadColors.textMuted, fontSize: 11),
        ),
      ],
    );
  }
}

class _Section extends StatelessWidget {
  const _Section(this.title);

  final String title;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Text(
      title,
      style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
    ),
  );
}

class _Fact extends StatelessWidget {
  const _Fact(this.label, this.value);

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: NomadColors.surface,
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: NomadColors.outline),
    ),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(
            label,
            style: const TextStyle(color: NomadColors.textMuted, fontSize: 11),
          ),
          Text(value, style: const TextStyle(fontWeight: FontWeight.w700)),
        ],
      ),
    ),
  );
}

class _AttractionTile extends StatelessWidget {
  const _AttractionTile({required this.attraction, required this.openLink});

  final Attraction attraction;
  final OpenBooking openLink;

  @override
  Widget build(BuildContext context) {
    final Uri? article = attraction.articleUrl;
    return SizedBox(
      width: 160,
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: article == null ? null : () => openLink(article),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            if (attraction.photo case final PlacePhoto photo)
              _Photo(photo: photo, height: 110, openLink: openLink)
            else
              Container(
                height: 110,
                decoration: BoxDecoration(
                  color: NomadColors.surface,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: const Center(child: Icon(Icons.place_rounded)),
              ),
            const SizedBox(height: 6),
            Text(
              attraction.name,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
            if (attraction.description case final String d)
              Text(
                d,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: NomadColors.textMuted,
                  fontSize: 12,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Una foto de Commons. Tocarla abre su página (autor y licencia). Si no
/// carga (sin red), se queda un hueco discreto: la ficha sigue sirviendo.
class _Photo extends StatelessWidget {
  const _Photo({
    required this.photo,
    required this.height,
    required this.openLink,
  });

  final PlacePhoto photo;
  final double height;
  final OpenBooking openLink;

  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: () => openLink(photo.pageUrl),
    child: ClipRRect(
      borderRadius: BorderRadius.circular(14),
      child: Image.network(
        photo.url.toString(),
        height: height,
        width: double.infinity,
        fit: BoxFit.cover,
        headers: _imageHeaders,
        semanticLabel: AppLocalizations.of(context).placePhotoLabel,
        errorBuilder: (_, _, _) =>
            Container(height: height, color: NomadColors.surface),
      ),
    ),
  );
}
