// "¿No se te ocurren planes?": un carrusel de vídeos cortos (reels) de
// cosas que hacer en un sitio, que se ven DENTRO de ECLIPTA.
//
// Los vídeos salen de dos sitios:
//   - YouTube Shorts: los busca nuestro servidor (que es quien tiene la
//     clave) y los guarda 7 días.
//   - TikTok e Instagram no dejan buscar vídeos desde otras apps, pero sí
//     enseñar uno si tienes su enlace: cualquiera puede pegar el enlace de
//     un TikTok o un reel para ese sitio y le sale a todo el mundo.
// Debajo hay botones que abren la búsqueda de ese sitio en cada red.
import 'package:flutter/material.dart';

import '../../core/api_client.dart';
import '../../core/services.dart';
import '../../core/theme.dart';
import '../../l10n/generated/app_localizations.dart';
import 'reel_player.dart';

/// De qué red es un vídeo (cada una tiene su reproductor oficial).
enum ReelSource { youtube, tiktok, instagram }

/// Un vídeo corto.
class PlanReel {
  const PlanReel({
    required this.id,
    required this.title,
    this.source = ReelSource.youtube,
    this.channel,
    this.thumb,
  });

  final ReelSource source;

  /// El id en su red (YouTube 11 letras, TikTok un número, Instagram un código).
  final String id;
  final String title;
  final String? channel;

  /// Miniatura (solo de los servidores de cada red).
  final Uri? thumb;

  static final Map<ReelSource, RegExp> _ids = <ReelSource, RegExp>{
    ReelSource.youtube: RegExp(r'^[A-Za-z0-9_-]{11}$'),
    ReelSource.tiktok: RegExp(r'^[0-9]{15,25}$'),
    ReelSource.instagram: RegExp(r'^[A-Za-z0-9_-]{5,40}$'),
  };

  static bool _safeThumb(Uri u) =>
      u.isScheme('https') &&
      (u.host.endsWith('ytimg.com') ||
          u.host.endsWith('.tiktokcdn.com') ||
          u.host.endsWith('.tiktokcdn-us.com') ||
          u.host.endsWith('.tiktokcdn-eu.com'));

  /// Su reproductor oficial (para verlo dentro de la app).
  Uri get player => switch (source) {
    ReelSource.youtube => Uri.https(
      'www.youtube.com',
      '/embed/$id',
      <String, String>{
        'autoplay': '1',
        'playsinline': '1',
        'rel': '0',
        'loop': '1',
        'playlist': id,
      },
    ),
    ReelSource.tiktok => Uri.https(
      'www.tiktok.com',
      '/player/v1/$id',
      <String, String>{'autoplay': '1', 'loop': '1', 'description': '1'},
    ),
    ReelSource.instagram => Uri.https('www.instagram.com', '/reel/$id/embed/'),
  };

  /// Los vídeos de la respuesta del servidor (lo raro se salta).
  static List<PlanReel> parseAll(Object? json) {
    final Object? list = json is Map ? json['videos'] : null;
    if (list is! List) return const <PlanReel>[];
    final List<PlanReel> out = <PlanReel>[];
    for (final Object? v in list) {
      if (v is! Map) continue;
      final ReelSource? source = switch (v['source'] ?? 'youtube') {
        'youtube' => ReelSource.youtube,
        'tiktok' => ReelSource.tiktok,
        'instagram' => ReelSource.instagram,
        _ => null,
      };
      final Object? id = v['id'];
      final Object? title = v['title'];
      if (source == null ||
          id is! String ||
          !_ids[source]!.hasMatch(id) ||
          title is! String) {
        continue;
      }
      final Uri? thumb = Uri.tryParse('${v['thumb'] ?? ''}');
      out.add(
        PlanReel(
          source: source,
          id: id,
          title: title,
          channel: v['channel'] is String ? v['channel'] as String : null,
          thumb: thumb != null && _safeThumb(thumb) ? thumb : null,
        ),
      );
    }
    return out;
  }
}

class ReelsApi {
  const ReelsApi(this._api);

  final ApiClient _api;

  /// Vídeos de [place]; [query] es la búsqueda ya en tu idioma.
  Future<List<PlanReel>> search({
    required String place,
    required String query,
    required String language,
  }) async => PlanReel.parseAll(
    await _api.getJson(
      '/v1/plan-videos',
      query: <String, String>{
        'place': place.length > 60 ? place.substring(0, 60) : place,
        'q': query.length > 100 ? query.substring(0, 100) : query,
        'lang': language,
      },
      public: true,
      timeout: ApiClient.verySlow,
    ),
  );

  /// Pegar el enlace de un TikTok o reel de Instagram para [place].
  Future<void> addLink({required String place, required String url}) =>
      _api.postJson('/v1/plan-videos/links', <String, String>{
        'place': place.length > 60 ? place.substring(0, 60) : place,
        'url': url.trim(),
      });
}

/// Dónde buscar más vídeos de [query] en cada red.
Uri tiktokSearch(String query) =>
    Uri.https('www.tiktok.com', '/search/video', <String, String>{'q': query});
Uri instagramSearch(String query) => Uri.https(
  'www.instagram.com',
  '/explore/search/keyword/',
  <String, String>{'q': query},
);
Uri youtubeSearch(String query) => Uri.https(
  'www.youtube.com',
  '/results',
  <String, String>{'search_query': '$query #shorts'},
);

/// El carrusel. [place] es lo que se busca ("" = ideas generales).
class PlanReels extends StatefulWidget {
  const PlanReels({super.key, this.place = ''});

  final String place;

  @override
  State<PlanReels> createState() => _PlanReelsState();
}

class _PlanReelsState extends State<PlanReels> {
  late final AppServices _services = ServicesScope.of(context);
  List<PlanReel>? _reels;
  String? _loadedFor;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _maybeLoad();
  }

  @override
  void didUpdateWidget(PlanReels old) {
    super.didUpdateWidget(old);
    _maybeLoad();
  }

  String _query(AppLocalizations t) => widget.place.trim().isEmpty
      ? t.groupPlansDefault
      : t.groupPlansQuery(widget.place.trim());

  /// El sitio con el que se guardan los vídeos (sin sitio, las ideas generales).
  String _placeKey(AppLocalizations t) =>
      widget.place.trim().isEmpty ? _query(t) : widget.place.trim();

  Future<void> _pasteLink() async {
    final AppLocalizations t = AppLocalizations.of(context);
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final String? url = await showDialog<String>(
      context: context,
      builder: (_) => const _PasteLinkDialog(),
    );
    if (url == null || url.trim().isEmpty || !mounted) return;
    try {
      await _services.reels.addLink(place: _placeKey(t), url: url);
    } on ApiException catch (e) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(switch (e.error) {
            ApiError.invalidInput => t.groupPlansLinkBad,
            ApiError.signedOut => t.groupSignIn,
            ApiError.network => t.errorNetwork,
            _ => t.errorUnavailable,
          }),
        ),
      );
      return;
    }
    messenger.showSnackBar(SnackBar(content: Text(t.groupPlansLinkDone)));
    // Se vuelve a pedir: el enlace nuevo sale el primero.
    _loadedFor = null;
    await _maybeLoad();
  }

  Future<void> _maybeLoad() async {
    final String place = widget.place.trim();
    if (_loadedFor == place) return;
    _loadedFor = place;
    final AppLocalizations t = AppLocalizations.of(context);
    final String query = _query(t);
    setState(() => _reels = null);
    List<PlanReel> found;
    try {
      found = await _services.reels.search(
        place: _placeKey(t),
        query: query,
        language: Localizations.localeOf(context).languageCode,
      );
    } on ApiException {
      found = const <PlanReel>[];
    }
    // Si mientras tanto se buscó otro sitio, esta respuesta ya no vale.
    if (!mounted || _loadedFor != place) return;
    setState(() => _reels = found);
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    final List<PlanReel>? reels = _reels;
    final String query = _query(t);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (reels == null || reels.isNotEmpty)
          SizedBox(
            height: 214,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: reels?.length ?? 4,
              separatorBuilder: (_, _) => const SizedBox(width: 10),
              itemBuilder: (BuildContext context, int i) => reels == null
                  ? const _ReelCard.loading()
                  : _ReelCard(
                      reel: reels[i],
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) =>
                              ReelPlayerScreen(reels: reels, start: i),
                        ),
                      ),
                    ),
            ),
          ),
        if (reels != null && reels.isEmpty)
          Text(
            t.groupPlansNone,
            style: const TextStyle(color: Color(0xFFD6CCF5)),
          ),
        const SizedBox(height: 10),
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: TextButton.icon(
            style: TextButton.styleFrom(
              foregroundColor: const Color(0xFFFF8FD8),
              padding: const EdgeInsets.symmetric(horizontal: 4),
            ),
            onPressed: _pasteLink,
            icon: const Icon(Icons.add_link_rounded, size: 20),
            label: Text(t.groupPlansAddLink),
          ),
        ),
        const SizedBox(height: 6),
        Row(
          children: <Widget>[
            if (reels == null || reels.isNotEmpty) ...<Widget>[
              Text(
                t.groupPlansMoreOn,
                style: const TextStyle(
                  color: NomadColors.textMuted,
                  fontSize: 12.5,
                ),
              ),
              const SizedBox(width: 8),
            ],
            Expanded(
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: <Widget>[
                  _Source(
                    label: 'TikTok',
                    color: const Color(0xFF25F4EE),
                    onTap: () => _services.openLink(tiktokSearch(query)),
                  ),
                  _Source(
                    label: 'Instagram',
                    color: const Color(0xFFFF5FA2),
                    onTap: () => _services.openLink(instagramSearch(query)),
                  ),
                  _Source(
                    label: 'YouTube',
                    color: const Color(0xFFFF4E45),
                    onTap: () => _services.openLink(youtubeSearch(query)),
                  ),
                ],
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// Una tarjeta vertical (como un reel): miniatura, título y "play".
class _ReelCard extends StatelessWidget {
  const _ReelCard({required PlanReel this.reel, required this.onTap});

  const _ReelCard.loading() : reel = null, onTap = null;

  final PlanReel? reel;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final PlanReel? r = reel;
    final Uri? thumb = r?.thumb;
    return GestureDetector(
      onTap: onTap,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(18),
        child: SizedBox(
          width: 122,
          child: Stack(
            fit: StackFit.expand,
            children: <Widget>[
              const DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: <Color>[Color(0xFF3A2470), Color(0xFF0F2A44)],
                  ),
                ),
              ),
              if (thumb != null)
                Image.network(
                  thumb.toString(),
                  fit: BoxFit.cover,
                  errorBuilder: (_, _, _) => const SizedBox.shrink(),
                ),
              if (r != null) ...<Widget>[
                const DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      stops: <double>[0.45, 1],
                      colors: <Color>[Color(0x00000000), Color(0xDD000000)],
                    ),
                  ),
                ),
                const Center(
                  child: CircleAvatar(
                    radius: 20,
                    backgroundColor: Color(0x66000000),
                    child: Icon(Icons.play_arrow_rounded, color: Colors.white),
                  ),
                ),
                Positioned(
                  left: 8,
                  right: 8,
                  bottom: 8,
                  child: Text(
                    r.title,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 11.5,
                      height: 1.2,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                Positioned(
                  left: 8,
                  top: 8,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: switch (r.source) {
                        ReelSource.youtube => const Color(0xFFFF0033),
                        ReelSource.tiktok => const Color(0xFF111111),
                        ReelSource.instagram => const Color(0xFFD62976),
                      },
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      switch (r.source) {
                        ReelSource.youtube => 'Shorts',
                        ReelSource.tiktok => 'TikTok',
                        ReelSource.instagram => 'Instagram',
                      },
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 10,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Botón con el nombre de una red social y su color.
class _Source extends StatelessWidget {
  const _Source({
    required this.label,
    required this.color,
    required this.onTap,
  });

  final String label;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Material(
    color: color.withValues(alpha: 0.12),
    shape: StadiumBorder(side: BorderSide(color: color.withValues(alpha: 0.6))),
    child: InkWell(
      customBorder: const StadiumBorder(),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        child: Text(
          label,
          style: TextStyle(
            color: color,
            fontWeight: FontWeight.w800,
            fontSize: 12.5,
          ),
        ),
      ),
    ),
  );
}

/// La ventanita para pegar el enlace.
class _PasteLinkDialog extends StatefulWidget {
  const _PasteLinkDialog();

  @override
  State<_PasteLinkDialog> createState() => _PasteLinkDialogState();
}

class _PasteLinkDialogState extends State<_PasteLinkDialog> {
  final TextEditingController _url = TextEditingController();

  @override
  void dispose() {
    _url.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    return AlertDialog(
      backgroundColor: const Color(0xFF1D1638),
      title: Text(t.groupPlansAddLink),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            t.groupPlansLinkHelp,
            style: const TextStyle(color: Color(0xFFD6CCF5), height: 1.4),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _url,
            autofocus: true,
            keyboardType: TextInputType.url,
            decoration: const InputDecoration(
              hintText: 'https://www.tiktok.com/…',
              prefixIcon: Icon(Icons.link_rounded),
            ),
            onSubmitted: (String v) => Navigator.of(context).pop(v),
          ),
        ],
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(MaterialLocalizations.of(context).cancelButtonLabel),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_url.text),
          child: Text(t.groupPlansLinkAdd),
        ),
      ],
    );
  }
}
