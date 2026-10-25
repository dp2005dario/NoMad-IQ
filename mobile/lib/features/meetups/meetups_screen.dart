// Quedadas de viajeros (maqueta "Quedadas"): si viajas solo, ves planes
// abiertos de otra gente en tu misma ciudad y te apuntas ("Unirme").
//
// Seguridad, sin pedir el DNI a nadie (no hay forma gratis y fiable de
// verificar identidades en todo el mundo):
//   - Hace falta cuenta (un invitado no ve ni propone nada).
//   - Solo sitios públicos: se recuerda al proponer.
//   - La ciudad va por código de aeropuerto; tu posición nunca sale del móvil.
//   - Puedes ir "oculto": los demás ven "Alguien" en vez de tu nombre.
//   - Tres denuncias de personas distintas y la quedada desaparece.
//   - Todo se borra solo una semana después.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../core/api_client.dart';
import '../../core/services.dart';
import '../../core/settings.dart';
import '../../core/theme.dart';
import '../../l10n/generated/app_localizations.dart';
import '../easy/easy_mode.dart';
import '../map/geo.dart' show PositionFix;
import '../map/location.dart';
import '../passport/passport.dart' show flagOf;
import '../route/geo.dart' show LatLon, distanceKm;
import '../route/world_data.dart';
import '../sos/where_am_i.dart' show nearestAirport;
import 'meetups_api.dart';

/// Si el aeropuerto más cercano está más lejos que esto, no estás "en" esa
/// ciudad: mejor preguntar.
const double _nearCityKm = 50;

class MeetupsScreen extends StatefulWidget {
  const MeetupsScreen({super.key, this.city});

  /// Código de aeropuerto de la ciudad ("LIS"). Si no viene, se adivina.
  final String? city;

  @override
  State<MeetupsScreen> createState() => _MeetupsScreenState();
}

class _MeetupsScreenState extends State<MeetupsScreen> {
  late final AppServices _services = ServicesScope.of(context);

  String? _city;
  String? _cityName;
  bool _locating = true;

  List<Meetup>? _meetups;
  ApiError? _error;
  bool _busy = false;

  /// null = todas.
  MeetupKind? _filter;

  late bool _hidden = _services.prefs.readData(LocalData.meetupHidden) == '1';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_start()));
  }

  /// La ciudad: la que te pasan, la del destino de tu viaje o la del
  /// aeropuerto más cercano (calculado en el móvil, sin Internet).
  Future<void> _start() async {
    String? iata = widget.city ?? loadEasyTrip(_services.prefs).to;
    if (iata == null) {
      final LocationSource gps = _services.location;
      if (await gps.check() == LocationAccess.granted) {
        try {
          final PositionFix fix = await gps.watch().first.timeout(
            const Duration(seconds: 8),
          );
          final Airports airports = await _services.loadAirports();
          final Airport? a = nearestAirport(
            airports.all,
            LatLon(fix.point.lat, fix.point.lon),
          );
          final LatLon here = LatLon(fix.point.lat, fix.point.lon);
          if (a != null && distanceKm(here, a.position) < _nearCityKm) {
            iata = a.iata;
          }
        } on Object {
          // Sin GPS a tiempo: se pregunta la ciudad.
        }
      }
    }
    if (!mounted) return;
    setState(() => _locating = false);
    if (iata != null) await _open(iata);
  }

  Future<void> _open(String iata) async {
    final String code = iata.trim().toUpperCase();
    final Airports airports = await _services.loadAirports();
    if (!mounted) return;
    setState(() {
      _city = code;
      _cityName = airports[code]?.city;
      _meetups = null;
      _error = null;
    });
    await _load();
  }

  Future<void> _load() async {
    final String? city = _city;
    if (city == null) return;
    try {
      final List<Meetup> found = await _services.meetups.city(city);
      if (mounted) setState(() => (_meetups = found, _error = null));
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.error);
    }
  }

  Future<void> _pickCity() async {
    final String? iata = await showDialog<String>(
      context: context,
      builder: (BuildContext context) => _CityDialog(initial: _city ?? ''),
    );
    if (iata != null && mounted) await _open(iata);
  }

  /// Tu nombre para los demás: el mismo que usas en los grupos. Si aún no
  /// tienes, se pregunta una vez.
  Future<MeetupMe?> _me() async {
    String? name = _services.prefs.readGroupName()?.trim();
    if (name == null || name.isEmpty) {
      name = await showDialog<String>(
        context: context,
        builder: (BuildContext context) => const _NameDialog(),
      );
      if (name == null || name.trim().isEmpty) return null;
      name = name.trim();
      await _services.prefs.writeGroupName(name);
    }
    return MeetupMe(
      name: name,
      country: _services.prefs.readData(LocalData.visaPassport),
      visible: !_hidden,
    );
  }

  void _snack(String text) => ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(text)));

  /// Llama al servidor y, si sale bien, cambia esa quedada en la lista.
  Future<void> _run(Future<Meetup?> Function() call, {String? done}) async {
    setState(() => _busy = true);
    try {
      final Meetup? m = await call();
      if (!mounted) return;
      setState(() {
        final List<Meetup> list = List<Meetup>.of(_meetups ?? <Meetup>[]);
        final int i = m == null
            ? -1
            : list.indexWhere((Meetup x) => x.id == m.id);
        if (m != null && i >= 0) {
          list[i] = m;
        } else if (m != null) {
          list
            ..add(m)
            ..sort((Meetup a, Meetup b) => a.startsAt.compareTo(b.startsAt));
        }
        _meetups = list;
      });
      if (done != null) _snack(done);
    } on ApiException catch (e) {
      if (!mounted) return;
      final AppLocalizations t = AppLocalizations.of(context);
      _snack(switch (e.error) {
        ApiError.network => t.errorNetwork,
        ApiError.conflict => t.meetupsConflict,
        ApiError.notFound => t.meetupsGone,
        ApiError.signedOut => t.groupSignIn,
        _ => t.errorUnavailable,
      });
      if (e.error == ApiError.notFound) unawaited(_load());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _toggle(Meetup m) async {
    if (m.joined) {
      await _run(() => _services.meetups.leave(m.id));
      return;
    }
    final MeetupMe? me = await _me();
    if (me == null || !mounted) return;
    await _run(() => _services.meetups.join(m.id, me));
  }

  Future<void> _propose() async {
    final String? city = _city;
    if (city == null) return;
    final NewMeetup? draft = await showDialog<NewMeetup>(
      context: context,
      builder: (BuildContext context) => _ProposeDialog(city: city),
    );
    if (draft == null || !mounted) return;
    final MeetupMe? me = await _me();
    if (me == null || !mounted) return;
    final AppLocalizations t = AppLocalizations.of(context);
    await _run(
      () => _services.meetups.create(draft, me),
      done: t.meetupsProposed,
    );
  }

  Future<void> _cancel(Meetup m) async {
    final AppLocalizations t = AppLocalizations.of(context);
    final bool? sure = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: Text(t.meetupsCancelTitle),
        content: Text(t.meetupsCancelBody),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(MaterialLocalizations.of(context).cancelButtonLabel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(t.meetupsCancel),
          ),
        ],
      ),
    );
    if (sure != true || !mounted) return;
    setState(() => _busy = true);
    try {
      await _services.meetups.cancel(m.id);
      if (mounted) {
        setState(
          () => _meetups = <Meetup>[
            for (final Meetup x in _meetups ?? <Meetup>[])
              if (x.id != m.id) x,
          ],
        );
      }
    } on ApiException {
      if (mounted) _snack(t.errorUnavailable);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _report(Meetup m) async {
    final AppLocalizations t = AppLocalizations.of(context);
    final bool? sure = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: Text(t.meetupsReportTitle),
        content: Text(t.meetupsReportBody),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(MaterialLocalizations.of(context).cancelButtonLabel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(t.meetupsReport),
          ),
        ],
      ),
    );
    if (sure != true || !mounted) return;
    try {
      await _services.meetups.report(m.id);
      if (!mounted) return;
      // Ya no te la enseñamos a ti (aunque los demás la vean hasta 3).
      setState(
        () => _meetups = <Meetup>[
          for (final Meetup x in _meetups ?? <Meetup>[])
            if (x.id != m.id) x,
        ],
      );
      _snack(t.meetupsReported);
    } on ApiException {
      if (mounted) _snack(t.errorUnavailable);
    }
  }

  /// "Cómo llegar": Google Maps busca el sitio en esa ciudad (es un enlace).
  void _directions(Meetup m) => unawaited(
    _services.openBooking(
      Uri.https('www.google.com', '/maps/search/', <String, String>{
        'api': '1',
        'query': '${m.place}, ${_cityName ?? m.city}',
      }),
    ),
  );

  Future<void> _toggleHidden() async {
    setState(() => _hidden = !_hidden);
    await _services.prefs.writeData(
      LocalData.meetupHidden,
      _hidden ? '1' : null,
    );
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    final TextTheme text = Theme.of(context).textTheme;
    final List<Meetup>? all = _meetups;
    final List<Meetup> shown = <Meetup>[
      for (final Meetup m in all ?? const <Meetup>[])
        if (_filter == null || m.kind == _filter) m,
    ];
    return Scaffold(
      appBar: AppBar(title: Text(t.meetupsTitle)),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 32),
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  t.meetupsSolo(_cityName ?? _city ?? '—'),
                  style: text.titleMedium,
                ),
              ),
              TextButton.icon(
                onPressed: _busy ? null : _pickCity,
                icon: const Icon(Icons.edit_location_alt_rounded),
                label: Text(t.meetupsChangeCity),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            t.meetupsSafety,
            style: text.bodySmall?.copyWith(color: NomadColors.textMuted),
          ),
          const SizedBox(height: 16),
          if (_locating)
            const Center(child: CircularProgressIndicator())
          else if (_city == null)
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Text(t.meetupsPickCity, style: text.bodyLarge),
                const SizedBox(height: 12),
                FilledButton(
                  onPressed: _pickCity,
                  child: Text(t.meetupsChangeCity),
                ),
              ],
            )
          else if (_error != null)
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Text(switch (_error) {
                  ApiError.signedOut => t.meetupsSignIn,
                  ApiError.notFound => t.meetupsUnknownCity,
                  ApiError.network => t.errorNetwork,
                  _ => t.errorUnavailable,
                }),
                const SizedBox(height: 12),
                if (_error != ApiError.signedOut)
                  FilledButton(onPressed: _load, child: Text(t.guideRetry)),
              ],
            )
          else if (all == null)
            const Center(child: CircularProgressIndicator())
          else ...<Widget>[
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: <Widget>[
                ChoiceChip(
                  label: Text(t.meetupsAll),
                  selected: _filter == null,
                  onSelected: (_) => setState(() => _filter = null),
                ),
                for (final MeetupKind k in MeetupKind.values)
                  ChoiceChip(
                    avatar: Icon(_looks[k]!.$2, size: 18),
                    label: Text(_looks[k]!.$1(t)),
                    selected: _filter == k,
                    onSelected: (_) => setState(() => _filter = k),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            if (shown.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 16),
                child: Text(t.meetupsNone, style: text.bodyLarge),
              )
            else
              for (final Meetup m in shown)
                _MeetupCard(
                  meetup: m,
                  busy: _busy,
                  onToggle: () => _toggle(m),
                  onCancel: () => _cancel(m),
                  onReport: () => _report(m),
                  onDirections: () => _directions(m),
                ),
            const SizedBox(height: 16),
            Row(
              children: <Widget>[
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _busy ? null : _propose,
                    icon: const Icon(Icons.add_rounded),
                    label: Text(t.meetupsPropose),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _toggleHidden,
                    icon: Icon(
                      _hidden
                          ? Icons.visibility_off_rounded
                          : Icons.visibility_rounded,
                    ),
                    label: Text(_hidden ? t.meetupsHidden : t.meetupsVisible),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

final Map<MeetupKind, (String Function(AppLocalizations), IconData, Color)>
_looks = <MeetupKind, (String Function(AppLocalizations), IconData, Color)>{
  MeetupKind.food: (
    (AppLocalizations t) => t.meetupsFood,
    Icons.ramen_dining_rounded,
    NomadColors.money,
  ),
  MeetupKind.walk: (
    (AppLocalizations t) => t.meetupsWalk,
    Icons.directions_walk_rounded,
    NomadColors.mint,
  ),
  MeetupKind.drinks: (
    (AppLocalizations t) => t.meetupsDrinks,
    Icons.local_bar_rounded,
    NomadColors.group,
  ),
  MeetupKind.culture: (
    (AppLocalizations t) => t.meetupsCulture,
    Icons.museum_rounded,
    NomadColors.flights,
  ),
  MeetupKind.other: (
    (AppLocalizations t) => t.meetupsOther,
    Icons.groups_rounded,
    NomadColors.safety,
  ),
};

/// "Hoy 20:00", "Mañana 6:30" o "sáb, 1 nov 10:00" (en tu hora local).
String meetupWhen(
  AppLocalizations t,
  String locale,
  DateTime at,
  DateTime now,
) {
  final DateTime local = at.toLocal();
  final DateTime today = DateTime(now.year, now.month, now.day);
  final int days = DateTime(
    local.year,
    local.month,
    local.day,
  ).difference(today).inDays;
  final String hour = DateFormat.Hm(locale).format(local);
  return switch (days) {
    0 => t.meetupsToday(hour),
    1 => t.meetupsTomorrow(hour),
    _ => '${DateFormat.MMMEd(locale).format(local)} $hour',
  };
}

class _MeetupCard extends StatelessWidget {
  const _MeetupCard({
    required this.meetup,
    required this.busy,
    required this.onToggle,
    required this.onCancel,
    required this.onReport,
    required this.onDirections,
  });

  final Meetup meetup;
  final bool busy;
  final VoidCallback onToggle;
  final VoidCallback onCancel;
  final VoidCallback onReport;
  final VoidCallback onDirections;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    final TextTheme text = Theme.of(context).textTheme;
    final String locale = Localizations.localeOf(context).toLanguageTag();
    final Meetup m = meetup;
    final (String Function(AppLocalizations), IconData, Color) look =
        _looks[m.kind]!;
    final String meta = <String>[
      meetupWhen(t, locale, m.startsAt, DateTime.now()),
      m.place,
      t.meetupsSeats(m.going, m.capacity),
    ].join(' · ');
    final String who = <String>[
      for (final MeetupPerson p in m.people)
        <String>[
          p.name ?? t.meetupsSomeone,
          if (p.country != null) flagOf(p.country!),
        ].join(' '),
    ].join(', ');
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 4, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: look.$3,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Icon(look.$2, color: NomadColors.background),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(m.title, style: text.titleMedium),
                      const SizedBox(height: 2),
                      Text(
                        meta,
                        style: text.bodySmall?.copyWith(
                          color: NomadColors.textMuted,
                        ),
                      ),
                    ],
                  ),
                ),
                PopupMenuButton<VoidCallback>(
                  tooltip: t.meetupsMore,
                  onSelected: (VoidCallback f) => f(),
                  itemBuilder: (BuildContext context) =>
                      <PopupMenuEntry<VoidCallback>>[
                        PopupMenuItem<VoidCallback>(
                          value: onDirections,
                          child: Text(t.meetupsDirections),
                        ),
                        if (m.mine)
                          PopupMenuItem<VoidCallback>(
                            value: onCancel,
                            child: Text(t.meetupsCancel),
                          )
                        else
                          PopupMenuItem<VoidCallback>(
                            value: onReport,
                            child: Text(t.meetupsReport),
                          ),
                      ],
                ),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    who,
                    style: text.bodyMedium,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 8),
                if (m.mine)
                  Padding(
                    padding: const EdgeInsetsDirectional.only(end: 10),
                    child: Chip(label: Text(t.meetupsYours)),
                  )
                else
                  Padding(
                    padding: const EdgeInsetsDirectional.only(end: 10),
                    // Ancho fijo: los botones del tema piden todo el ancho.
                    child: SizedBox(
                      width: 110,
                      child: m.joined
                          ? OutlinedButton(
                              onPressed: busy ? null : onToggle,
                              child: Text(t.meetupsGoing),
                            )
                          : FilledButton(
                              onPressed: busy || m.full ? null : onToggle,
                              child: Text(
                                m.full ? t.meetupsFull : t.meetupsJoin,
                              ),
                            ),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _CityDialog extends StatefulWidget {
  const _CityDialog({required this.initial});

  final String initial;

  @override
  State<_CityDialog> createState() => _CityDialogState();
}

class _CityDialogState extends State<_CityDialog> {
  late final TextEditingController _code = TextEditingController(
    text: widget.initial,
  );

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  bool get _ok => RegExp(r'^[A-Za-z]{3}$').hasMatch(_code.text.trim());

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    return AlertDialog(
      title: Text(t.meetupsChangeCity),
      content: TextField(
        controller: _code,
        maxLength: 3,
        autofocus: true,
        textCapitalization: TextCapitalization.characters,
        decoration: InputDecoration(labelText: t.plansAirport),
        onChanged: (_) => setState(() {}),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(MaterialLocalizations.of(context).cancelButtonLabel),
        ),
        FilledButton(
          onPressed: _ok
              ? () => Navigator.of(context).pop(_code.text.trim().toUpperCase())
              : null,
          child: Text(MaterialLocalizations.of(context).okButtonLabel),
        ),
      ],
    );
  }
}

class _NameDialog extends StatefulWidget {
  const _NameDialog();

  @override
  State<_NameDialog> createState() => _NameDialogState();
}

class _NameDialogState extends State<_NameDialog> {
  final TextEditingController _name = TextEditingController();

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    return AlertDialog(
      title: Text(t.meetupsYourName),
      content: TextField(
        controller: _name,
        maxLength: maxMeetupName,
        autofocus: true,
        textCapitalization: TextCapitalization.words,
        onChanged: (_) => setState(() {}),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(MaterialLocalizations.of(context).cancelButtonLabel),
        ),
        FilledButton(
          onPressed: _name.text.trim().isEmpty
              ? null
              : () => Navigator.of(context).pop(_name.text.trim()),
          child: Text(MaterialLocalizations.of(context).okButtonLabel),
        ),
      ],
    );
  }
}

/// Proponer una quedada: qué, dónde (un sitio público), cuándo y cuántos.
class _ProposeDialog extends StatefulWidget {
  const _ProposeDialog({required this.city});

  final String city;

  @override
  State<_ProposeDialog> createState() => _ProposeDialogState();
}

class _ProposeDialogState extends State<_ProposeDialog> {
  final TextEditingController _title = TextEditingController();
  final TextEditingController _place = TextEditingController();
  MeetupKind _kind = MeetupKind.food;
  int _capacity = 6;

  /// Por defecto: dentro de dos horas, en punto.
  late DateTime _at = () {
    final DateTime soon = DateTime.now().add(const Duration(hours: 2));
    return DateTime(soon.year, soon.month, soon.day, soon.hour);
  }();

  @override
  void dispose() {
    _title.dispose();
    _place.dispose();
    super.dispose();
  }

  bool get _ok =>
      _title.text.trim().isNotEmpty &&
      _place.text.trim().isNotEmpty &&
      _at.isAfter(DateTime.now());

  Future<void> _pickDay() async {
    final DateTime now = DateTime.now();
    final DateTime? day = await showDatePicker(
      context: context,
      initialDate: _at,
      firstDate: DateTime(now.year, now.month, now.day),
      // Un día menos que el tope del servidor: así la hora nunca se pasa.
      lastDate: now.add(maxMeetupAhead - const Duration(days: 1)),
    );
    if (day != null && mounted) {
      setState(
        () =>
            _at = DateTime(day.year, day.month, day.day, _at.hour, _at.minute),
      );
    }
  }

  Future<void> _pickTime() async {
    final TimeOfDay? time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(_at),
    );
    if (time != null && mounted) {
      setState(
        () => _at = DateTime(
          _at.year,
          _at.month,
          _at.day,
          time.hour,
          time.minute,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    final String locale = Localizations.localeOf(context).toLanguageTag();
    return AlertDialog(
      title: Text(t.meetupsPropose),
      scrollable: true,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: <Widget>[
              for (final MeetupKind k in MeetupKind.values)
                ChoiceChip(
                  label: Text(_looks[k]!.$1(t)),
                  selected: _kind == k,
                  onSelected: (_) => setState(() => _kind = k),
                ),
            ],
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _title,
            maxLength: maxMeetupTitle,
            decoration: InputDecoration(labelText: t.meetupsWhat),
            onChanged: (_) => setState(() {}),
          ),
          TextField(
            controller: _place,
            maxLength: maxMeetupPlace,
            decoration: InputDecoration(
              labelText: t.meetupsWhere,
              helperText: t.meetupsPublicPlace,
              helperMaxLines: 3,
            ),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            children: <Widget>[
              ActionChip(
                avatar: const Icon(Icons.calendar_today_rounded, size: 18),
                label: Text(DateFormat.MMMEd(locale).format(_at)),
                onPressed: _pickDay,
              ),
              ActionChip(
                avatar: const Icon(Icons.schedule_rounded, size: 18),
                label: Text(DateFormat.Hm(locale).format(_at)),
                onPressed: _pickTime,
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(t.meetupsCapacity(_capacity)),
          Slider(
            value: _capacity.toDouble(),
            min: minMeetupCapacity.toDouble(),
            max: maxMeetupCapacity.toDouble(),
            divisions: maxMeetupCapacity - minMeetupCapacity,
            label: '$_capacity',
            onChanged: (double v) => setState(() => _capacity = v.round()),
          ),
        ],
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(MaterialLocalizations.of(context).cancelButtonLabel),
        ),
        FilledButton(
          onPressed: _ok
              ? () => Navigator.of(context).pop(
                  NewMeetup(
                    city: widget.city,
                    kind: _kind,
                    title: _title.text.trim(),
                    place: _place.text.trim(),
                    startsAt: _at,
                    capacity: _capacity,
                  ),
                )
              : null,
          child: Text(t.meetupsPublish),
        ),
      ],
    );
  }
}
