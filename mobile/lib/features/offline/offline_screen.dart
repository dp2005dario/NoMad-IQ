// Sin conexión (maqueta "SinConexion"): descargar ciudades enteras para que
// el mapa, las audioguías y los avisos de zona funcionen en modo avión o en
// el extranjero sin datos.
//
// Todo lo descargado vive SOLO en este móvil, en la carpeta privada de la
// app, y se borra al desinstalar o al tocar "Borrar".
//
// Como en la maqueta 15: puedes poner varias ciudades en cola (se bajan de
// una en una), parar la descarga, ver el % en un círculo, y al terminar hay
// un pequeño "estallido" con vibración. Borrar pide confirmación. Si falta
// el wifi, Flyra te lo dice.
//
// Lo que la maqueta tiene y aquí NO (todavía): elegir barrios sueltos
// dentro de la ciudad, reanudar justo donde se paró (al volver a empezar se
// baja de nuevo) y la actualización automática en segundo plano.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../../core/services.dart';
import '../../core/settings.dart';
import '../../core/theme.dart';
import '../../l10n/generated/app_localizations.dart';
import '../../widgets/flyra_avatar.dart';
import '../route/world_data.dart';
import 'city_downloader.dart';
import 'city_pack.dart';

class OfflineScreen extends StatefulWidget {
  const OfflineScreen({super.key});

  @override
  State<OfflineScreen> createState() => _OfflineScreenState();
}

class _OfflineScreenState extends State<OfflineScreen> {
  late final AppServices _services = ServicesScope.of(context);
  final TextEditingController _code = TextEditingController();

  Airports? _airports;
  List<CityPack> _cities = <CityPack>[];
  bool _wifiOnly = true;

  /// Qué ciudad se está descargando y por dónde va (null = ninguna).
  String? _busy;
  DownloadProgress? _progress;
  String? _error;

  /// true = el error es "esperando al wifi" (lo dice Flyra).
  bool _wifiProblem = false;

  /// Ciudades esperando su turno (se bajan de una en una).
  final List<Airport> _queue = <Airport>[];

  /// Has tocado "Parar descarga".
  bool _stop = false;

  /// La última ciudad que terminó bien (para el "estallido").
  String? _justDone;

  @override
  void initState() {
    super.initState();
    _cities = _services.offlineCities.all();
    _wifiOnly = _services.prefs.readData(LocalData.offlineWifiOnly) != '0';
    unawaited(_loadWorld());
  }

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  Future<void> _loadWorld() async {
    try {
      final WorldData world = await WorldData.load();
      if (mounted) setState(() => _airports = world.airports);
    } on Object {
      // Sin la lista de aeropuertos no se puede añadir una ciudad: el campo
      // lo dirá ("no conocemos ese aeropuerto").
    }
  }

  Future<void> _setWifiOnly(bool only) async {
    setState(() => _wifiOnly = only);
    await _services.prefs.writeData(
      LocalData.offlineWifiOnly,
      only ? '1' : '0',
    );
  }

  Airport? _airportOf(String code) {
    final Airports? all = _airports;
    final String c = code.trim().toUpperCase();
    if (all == null || c.length != 3) return null;
    return all[c];
  }

  /// Añade a la cola; si no hay nada bajando, empieza ya.
  void _enqueue(Airport airport) {
    if (_busy == airport.iata ||
        _queue.any((Airport a) => a.iata == airport.iata)) {
      return;
    }
    setState(() {
      _queue.add(airport);
      _code.clear();
    });
    if (_busy == null) unawaited(_next());
  }

  Future<void> _next() async {
    while (mounted && _queue.isNotEmpty && _busy == null) {
      final Airport a = _queue.removeAt(0);
      await _download(a);
    }
  }

  Future<void> _download(Airport airport) async {
    if (_busy != null) return;
    final String language = Localizations.localeOf(context).languageCode;
    final bool hadIt = _cities.any((CityPack c) => c.iata == airport.iata);
    bool ok = false;
    setState(() {
      _busy = airport.iata;
      _progress = const DownloadProgress(DownloadStep.zones);
      _error = null;
      _wifiProblem = false;
      _stop = false;
      _justDone = null;
    });
    final AppLocalizations t = AppLocalizations.of(context);
    try {
      await _services.downloads.run(
        iata: airport.iata,
        city: airport.city,
        center: airport.position,
        language: language,
        wifiOnly: _wifiOnly,
        onProgress: (DownloadProgress p) {
          if (mounted) setState(() => _progress = p);
        },
        stopped: () => _stop,
      );
      ok = true;
    } on DownloadException catch (e) {
      // Parada a medias de una ciudad nueva: se borra lo que se bajó.
      if (e.error == DownloadError.cancelled && !hadIt) {
        await _services.downloads.forget(airport.iata);
      }
      if (mounted) {
        setState(() {
          _wifiProblem = e.error == DownloadError.waitingForWifi;
          _error = switch (e.error) {
            DownloadError.waitingForWifi => t.offlineWaitingWifi,
            DownloadError.offline => t.offlineNoNet,
            DownloadError.nothingThere => t.offlineNothingThere,
            DownloadError.failed => t.offlineFailed,
            DownloadError.cancelled => t.offlineCancelled,
          };
        });
      }
    } on Object {
      if (mounted) setState(() => _error = t.offlineFailed);
    } finally {
      if (mounted) {
        setState(() {
          _busy = null;
          _progress = null;
          _cities = _services.offlineCities.all();
          if (ok) _justDone = airport.iata;
        });
        if (ok) unawaited(HapticFeedback.mediumImpact());
      }
    }
  }

  Future<void> _confirmForget(AppLocalizations t, CityPack pack) async {
    final bool? yes = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        content: Text(t.offlineDeleteAsk(pack.city)),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(t.offlineKeep),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(
              t.offlineDelete,
              style: const TextStyle(color: NomadColors.safety),
            ),
          ),
        ],
      ),
    );
    if (yes ?? false) await _forget(pack);
  }

  Future<void> _forget(CityPack pack) async {
    await _services.downloads.forget(pack.iata);
    if (mounted) {
      setState(() => _cities = _services.offlineCities.all());
    }
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    final TextTheme text = Theme.of(context).textTheme;
    final String typed = _code.text.trim();
    final Airport? picked = _airportOf(typed);
    final bool full = _cities.length >= OfflineLibrary.maxCities;
    return Scaffold(
      appBar: AppBar(title: Text(t.offlineTitle)),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
        children: <Widget>[
          Text(
            t.offlineIntro,
            style: text.bodyMedium?.copyWith(color: NomadColors.textMuted),
          ),
          const SizedBox(height: 20),
          TextField(
            controller: _code,
            maxLength: 3,
            textCapitalization: TextCapitalization.characters,
            inputFormatters: <TextInputFormatter>[
              FilteringTextInputFormatter.allow(RegExp('[a-zA-Z]')),
            ],
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              labelText: t.offlineCityField,
              counterText: '',
              helperText: picked?.city,
              errorText: typed.length == 3 && picked == null
                  ? t.offlineUnknownAirport
                  : null,
            ),
          ),
          const SizedBox(height: 12),
          // El botón ocupa el ancho entero: así se pulsa fácil con una mano.
          FilledButton(
            onPressed: picked == null || full ? null : () => _enqueue(picked),
            child: Text(t.offlineDownload),
          ),
          if (full)
            Text(
              t.offlineMax(OfflineLibrary.maxCities),
              style: const TextStyle(color: NomadColors.money),
            ),
          if (_error != null) ...<Widget>[
            const SizedBox(height: 8),
            if (_wifiProblem)
              _FlyraSays(text: _error!)
            else
              Text(_error!, style: const TextStyle(color: NomadColors.safety)),
          ],
          if (_busy != null) ...<Widget>[
            const SizedBox(height: 16),
            _Downloading(
              iata: _busy!,
              progress: _progress,
              onStop: _stop ? null : () => setState(() => _stop = true),
            ),
          ],
          if (_queue.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                t.offlineQueued(_queue.map((Airport a) => a.iata).join(', ')),
                style: const TextStyle(color: NomadColors.textMuted),
              ),
            ),
          const SizedBox(height: 24),
          if (_cities.isEmpty && _busy == null)
            Text(
              t.offlineNone,
              style: text.bodyMedium?.copyWith(color: NomadColors.textMuted),
            ),
          for (final CityPack pack in _cities)
            _CityCard(
              pack: pack,
              fresh: pack.iata == _justDone,
              busy: _busy != null,
              onUpdate: () {
                final Airport? a = _airportOf(pack.iata);
                if (a != null) _enqueue(a);
              },
              onDelete: () => unawaited(_confirmForget(t, pack)),
            ),
          const Divider(height: 40),
          SwitchListTile(
            value: _wifiOnly,
            onChanged: (bool v) => unawaited(_setWifiOnly(v)),
            title: Text(t.offlineWifiOnly),
            subtitle: Text(t.offlineWifiOnlyWhy),
            contentPadding: EdgeInsets.zero,
          ),
          const SizedBox(height: 8),
          Text(
            t.offlineUsed(sizeLabel(_services.offlineCities.totalBytes)),
            style: text.bodyMedium?.copyWith(color: NomadColors.textMuted),
          ),
        ],
      ),
    );
  }
}

/// La ciudad que se está descargando ahora: un círculo con el % y el paso.
class _Downloading extends StatelessWidget {
  const _Downloading({
    required this.iata,
    required this.progress,
    required this.onStop,
  });

  final String iata;
  final DownloadProgress? progress;

  /// null = ya se está parando.
  final VoidCallback? onStop;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    final DownloadProgress? p = progress;
    final double value = p?.fraction ?? 0;
    final String step = switch (p?.step) {
      DownloadStep.guides => t.offlineStepGuides,
      DownloadStep.audio => t.offlineStepAudio(p!.done, p.total),
      DownloadStep.map => t.offlineStepMap,
      _ => t.offlineStepZones,
    };
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: <Widget>[
            SizedBox.square(
              dimension: 72,
              child: TweenAnimationBuilder<double>(
                tween: Tween<double>(end: value),
                duration: const Duration(milliseconds: 400),
                builder: (BuildContext context, double v, _) => Stack(
                  alignment: Alignment.center,
                  children: <Widget>[
                    SizedBox.expand(
                      child: CircularProgressIndicator(
                        value: v,
                        strokeWidth: 7,
                        color: NomadColors.mint,
                        backgroundColor: NomadColors.surfaceHigh,
                      ),
                    ),
                    Text(
                      '${(v * 100).round()} %',
                      style: const TextStyle(fontWeight: FontWeight.w900),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(iata, style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 4),
                  Text(
                    step,
                    style: const TextStyle(color: NomadColors.textMuted),
                  ),
                  TextButton.icon(
                    onPressed: onStop,
                    icon: const Icon(Icons.stop_circle_rounded),
                    label: Text(t.offlineCancel),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Un aviso de Flyra (cuando falta el wifi).
class _FlyraSays extends StatelessWidget {
  const _FlyraSays({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: NomadColors.surfaceHigh,
      borderRadius: BorderRadius.circular(20),
      border: Border.all(color: NomadColors.money),
    ),
    child: Row(
      children: <Widget>[
        const FlyraAvatar(size: 36),
        const SizedBox(width: 10),
        const Icon(Icons.wifi_off_rounded, color: NomadColors.money),
        const SizedBox(width: 8),
        Expanded(child: Text(text)),
      ],
    ),
  );
}

/// Una ciudad ya descargada.
class _CityCard extends StatelessWidget {
  const _CityCard({
    required this.pack,
    required this.fresh,
    required this.busy,
    required this.onUpdate,
    required this.onDelete,
  });

  final CityPack pack;

  /// Acaba de terminar: entra con un "estallido" y un check verde.
  final bool fresh;
  final bool busy;
  final VoidCallback onUpdate;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    final String tag = Localizations.localeOf(context).toLanguageTag();
    final String language = Localizations.localeOf(context).languageCode;
    final bool still = MediaQuery.disableAnimationsOf(context);
    final Widget card = Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: NomadColors.surfaceHigh,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(pack.iata),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    pack.city,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              t.offlineDetail(
                pack.guides,
                sizeLabel(pack.bytes),
                DateFormat.yMMMd(tag).format(pack.savedAt),
              ),
              style: const TextStyle(color: NomadColors.textMuted),
            ),
            if (pack.mapFailed)
              Text(
                t.offlineMapMissing,
                style: const TextStyle(color: NomadColors.money),
              ),
            if (pack.language != language)
              Text(
                t.offlineOtherLanguage,
                style: const TextStyle(color: NomadColors.money),
              ),
            const SizedBox(height: 4),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: <Widget>[
                TextButton(
                  onPressed: busy ? null : onUpdate,
                  child: Text(t.offlineUpdate),
                ),
                TextButton(
                  onPressed: busy ? null : onDelete,
                  child: Text(
                    t.offlineDelete,
                    style: const TextStyle(color: NomadColors.safety),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
    if (!fresh || still) return card;
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0.85, end: 1),
      duration: const Duration(milliseconds: 600),
      curve: Curves.elasticOut,
      builder: (BuildContext context, double v, Widget? child) =>
          Transform.scale(scale: v, child: child),
      child: Stack(
        children: <Widget>[
          card,
          const PositionedDirectional(
            top: 8,
            end: 8,
            child: Icon(
              Icons.check_circle_rounded,
              color: NomadColors.mint,
              size: 28,
            ),
          ),
        ],
      ),
    );
  }
}
