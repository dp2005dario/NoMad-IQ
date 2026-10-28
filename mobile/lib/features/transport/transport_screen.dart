// Moverte (maqueta "Transporte"): cómo ir del aeropuerto al hotel, qué bono
// de transporte te compensa y tus billetes.
//
// Todo a 0 €:
//   - Rutas: las estaciones de tren, metro, bus y taxi del aeropuerto salen
//     de OpenStreetMap (la misma guía del aeropuerto, un mes de caché en el
//     servidor). La ruta exacta con horarios y precios la calcula Google
//     Maps con los datos de cada operador: no hay datos de transporte
//     gratis y fiables para todo el mundo que podamos usar nosotros.
//   - Bonos: qué bonos hay y su web oficial (transport_data.dart). La app
//     NO pone precios (no hay una fuente gratis y comprobada): los apuntas
//     tú desde la web oficial y la calculadora te dice si compensa.
//   - Mis billetes: solo en el móvil (my_tickets.dart).
import 'dart:async';
import 'dart:math' show Random, max;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../../core/api_client.dart';
import '../../core/services.dart';
import '../../core/settings.dart';
import '../../core/theme.dart';
import '../../l10n/generated/app_localizations.dart';
import '../../widgets/flyra_avatar.dart';
import '../airport/airport_guide.dart';
import '../easy/easy_mode.dart';
import '../flights/flights_screen.dart' show showOriginSheet;
import '../map/geo.dart';
import 'my_tickets.dart';
import 'transport_data.dart';

enum _Tab { routes, passes, tickets }

/// Las "salidas" del aeropuerto, en el orden en que se enseñan.
const List<SpotKind> transitKinds = <SpotKind>[
  SpotKind.train,
  SpotKind.metro,
  SpotKind.tram,
  SpotKind.bus,
  SpotKind.taxi,
];

String _money(double v, String currency, String locale) =>
    NumberFormat.simpleCurrency(locale: locale, name: currency).format(v);

/// Google Maps de [from] a [to] (gratis y sin clave).
Uri transitDirections(GeoPoint from, String to, {required String mode}) =>
    Uri.https('www.google.com', '/maps/dir/', <String, String>{
      'api': '1',
      'origin': '${from.lat.toStringAsFixed(5)},${from.lon.toStringAsFixed(5)}',
      'destination': to,
      'travelmode': mode,
    });

class TransportScreen extends StatefulWidget {
  const TransportScreen({super.key, this.iata});

  /// El aeropuerto al que llegas (si no, el del Modo fácil o el que elijas).
  final String? iata;

  @override
  State<TransportScreen> createState() => _TransportScreenState();
}

class _TransportScreenState extends State<TransportScreen> {
  late final AppServices _services = ServicesScope.of(context);
  late final EasyTrip _trip = loadEasyTrip(_services.prefs);
  late String? _iata = widget.iata?.toUpperCase() ?? _trip.to;
  late final TextEditingController _hotel = TextEditingController(
    text: _trip.hotelAddress ?? '',
  );

  _Tab _tab = _Tab.routes;
  AirportGuide? _guide;
  bool _loading = false;
  ApiError? _error;
  int _days = 3;
  int _rides = 4;
  double? _single;
  double? _passPrice;
  int? _passHours;
  late List<TransitTicket> _tickets = decodeTickets(
    _services.prefs.readData(LocalData.transitTickets),
  );
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_load()));
    // Para que "Quedan X h" baje solo mientras miras la pantalla.
    _tick = Timer.periodic(const Duration(minutes: 1), (_) {
      if (mounted && _tab == _Tab.tickets) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    _hotel.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final String? iata = _iata;
    if (iata == null) return;
    setState(() => (_loading = true, _error = null, _guide = null));
    try {
      final AirportGuide g = await _services.airportGuide.get(iata);
      if (mounted) setState(() => (_guide = g, _loading = false));
    } on ApiException catch (e) {
      if (mounted) setState(() => (_error = e.error, _loading = false));
    }
  }

  Future<void> _pickAirport() async {
    final String? code = await showOriginSheet(context, current: _iata ?? '');
    if (code == null || !mounted) return;
    setState(() => _iata = code);
    await _load();
  }

  Future<void> _saveTickets(List<TransitTicket> list) async {
    setState(() => _tickets = list);
    await _services.prefs.writeData(
      LocalData.transitTickets,
      list.isEmpty ? null : encodeTickets(list),
    );
  }

  String _newId() =>
      '${DateTime.now().microsecondsSinceEpoch}${Random().nextInt(999)}';

  Future<void> _haveCard(CityTransit city, TransitCard card) async {
    await _saveTickets(<TransitTicket>[
      ..._tickets,
      TransitTicket(
        id: _newId(),
        name: card.name,
        currency: city.currency,
        url: card.url,
      ),
    ]);
    _showTickets();
  }

  Future<void> _havePass(CityTransit city, TransitPass pass) async {
    final AppLocalizations t = AppLocalizations.of(context);
    final List<String>? got = await _ask(
      context,
      title: pass.name,
      fields: <_Field>[_Field(t.transportHowManyHours, _FieldKind.integer)],
    );
    final int? hours = int.tryParse(got?.first ?? '');
    if (hours == null || hours <= 0 || hours > 24 * 31 || !mounted) return;
    await _saveTickets(<TransitTicket>[
      ..._tickets,
      TransitTicket(
        id: _newId(),
        name: pass.name,
        hours: hours,
        activatedAt: DateTime.now(),
        currency: city.currency,
        url: pass.url,
      ),
    ]);
    _showTickets();
  }

  void _showTickets() {
    if (mounted) setState(() => _tab = _Tab.tickets);
  }

  Future<void> _addTicket() async {
    final AppLocalizations t = AppLocalizations.of(context);
    final List<String>? got = await _ask(
      context,
      title: t.transportAdd,
      fields: <_Field>[
        _Field(t.transportName, _FieldKind.text),
        _Field(t.transportHoursField, _FieldKind.integer),
      ],
    );
    if (got == null || !mounted) return;
    final String n = got[0].trim();
    final int? h = int.tryParse(got[1]);
    if (n.isEmpty) return;
    final bool pass = h != null && h > 0 && h <= 24 * 31;
    await _saveTickets(<TransitTicket>[
      ..._tickets,
      TransitTicket(
        id: _newId(),
        name: n.length > 60 ? n.substring(0, 60) : n,
        hours: pass ? h : null,
        activatedAt: pass ? DateTime.now() : null,
        currency: cityForAirport(_iata)?.currency,
      ),
    ]);
  }

  Future<void> _editBalance(TransitTicket ticket) async {
    final AppLocalizations t = AppLocalizations.of(context);
    final List<String>? got = await _ask(
      context,
      title: t.transportEditBalance,
      fields: <_Field>[
        _Field(
          t.transportEditBalance,
          _FieldKind.decimal,
          initial: ticket.balance?.toString() ?? '',
        ),
      ],
    );
    if (got == null || !mounted) return;
    final double? v = double.tryParse(got.first.replaceAll(',', '.'));
    await _saveTickets(<TransitTicket>[
      for (final TransitTicket x in _tickets)
        x.id == ticket.id
            ? x.withBalance(v != null && v >= 0 && v < 1e7 ? v : null)
            : x,
    ]);
  }

  void _open(String url) => unawaited(_services.openBooking(Uri.parse(url)));

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    final CityTransit? city = cityForAirport(_iata);
    return Scaffold(
      appBar: AppBar(title: Text(t.transportTitle)),
      body: ListView(
        // Al arrastrar la lista se esconde el teclado, y el hueco de abajo
        // deja subir los campos de la calculadora por encima de él.
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 120),
        children: <Widget>[
          Text(
            city == null
                ? t.transportSubtitle
                : '${city.city} · ${t.transportSubtitle}',
            style: const TextStyle(color: NomadColors.textMuted),
          ),
          const SizedBox(height: 12),
          SegmentedButton<_Tab>(
            segments: <ButtonSegment<_Tab>>[
              ButtonSegment<_Tab>(
                value: _Tab.routes,
                label: Text(t.transportTabRoutes),
              ),
              ButtonSegment<_Tab>(
                value: _Tab.passes,
                label: Text(t.transportTabPasses),
              ),
              ButtonSegment<_Tab>(
                value: _Tab.tickets,
                label: Text(t.transportTabTickets),
              ),
            ],
            selected: <_Tab>{_tab},
            showSelectedIcon: false,
            onSelectionChanged: (Set<_Tab> v) => setState(() => _tab = v.first),
          ),
          const SizedBox(height: 12),
          ...switch (_tab) {
            _Tab.routes => _routes(t),
            _Tab.passes => _passes(t, city),
            _Tab.tickets => _ticketList(t),
          },
        ],
      ),
    );
  }

  List<Widget> _routes(AppLocalizations t) {
    final String? iata = _iata;
    final AirportGuide? guide = _guide;
    final String hotel = _hotel.text.trim();
    return <Widget>[
      Card(
        child: ListTile(
          leading: const Icon(
            Icons.flight_land_rounded,
            color: NomadColors.flights,
          ),
          title: Text(
            iata == null ? t.transportNoAirport : t.transportAirport(iata),
          ),
          trailing: TextButton(
            onPressed: () => unawaited(_pickAirport()),
            child: Text(
              iata == null ? t.transportPickAirport : t.transportChange,
            ),
          ),
        ),
      ),
      const SizedBox(height: 8),
      TextField(
        controller: _hotel,
        maxLength: 200,
        decoration: InputDecoration(
          labelText: t.transportTo,
          hintText: t.transportHotelHint,
          prefixIcon: const Icon(Icons.hotel_rounded),
        ),
        onChanged: (_) => setState(() {}),
      ),
      if (iata != null) ...<Widget>[
        Text(t.transportWaysOut, style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 6),
        if (_loading)
          const Padding(
            padding: EdgeInsets.all(16),
            child: Center(child: CircularProgressIndicator()),
          )
        else if (_error != null)
          Text(t.transportWaysError)
        else if (guide != null)
          ..._waysOut(t, guide),
        const SizedBox(height: 12),
        for (final (String mode, IconData icon, String title, String note)
            in <(String, IconData, String, String)>[
              (
                'transit',
                Icons.directions_transit_rounded,
                t.transportRouteTransit,
                t.transportRouteTransitNote,
              ),
              (
                'driving',
                Icons.local_taxi_rounded,
                t.transportRouteTaxi,
                t.transportRouteTaxiNote,
              ),
            ])
          Card(
            child: ListTile(
              leading: Icon(icon, color: NomadColors.mint),
              title: Text(title),
              subtitle: Text(note),
              trailing: IconButton.filledTonal(
                tooltip: t.transportGo,
                icon: const Icon(Icons.directions_rounded),
                onPressed: guide == null || hotel.isEmpty
                    ? null
                    : () => unawaited(
                        _services.openBooking(
                          transitDirections(guide.center, hotel, mode: mode),
                        ),
                      ),
              ),
            ),
          ),
        if (hotel.isEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              t.transportNeedHotel,
              style: const TextStyle(color: NomadColors.textMuted),
            ),
          ),
        const SizedBox(height: 12),
        Text(
          t.transportRoutesNote,
          style: const TextStyle(fontSize: 12, color: NomadColors.textMuted),
        ),
      ],
    ];
  }

  List<Widget> _waysOut(AppLocalizations t, AirportGuide guide) {
    final List<Widget> rows = <Widget>[];
    for (final SpotKind k in transitKinds) {
      final List<AirportSpot> spots = <AirportSpot>[
        for (final AirportSpot s in guide.spots)
          if (s.kind == k) s,
      ];
      if (spots.isEmpty) continue;
      // Nombres distintos (una estación suele estar dibujada varias veces).
      final List<String> names = <String>{
        for (final AirportSpot s in spots)
          if (s.name != null) s.name!,
      }.take(3).toList();
      rows.add(
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: Icon(_kindIcon(k), color: _kindColor(k)),
          title: Text(_kindLabel(t, k)),
          subtitle: names.isEmpty ? null : Text(names.join(' · ')),
          trailing: const Icon(Icons.directions_walk_rounded),
          // Andando hasta la estación (Google Maps, desde donde estés).
          onTap: () => unawaited(
            _services.openBooking(
              Uri.https('www.google.com', '/maps/dir/', <String, String>{
                'api': '1',
                'destination':
                    '${spots.first.point.lat.toStringAsFixed(5)},${spots.first.point.lon.toStringAsFixed(5)}',
                'travelmode': 'walking',
              }),
            ),
          ),
        ),
      );
    }
    if (rows.isEmpty) return <Widget>[Text(t.transportWaysNone)];
    return rows;
  }

  List<Widget> _passes(AppLocalizations t, CityTransit? city) {
    final String locale = Localizations.localeOf(context).toLanguageTag();
    final double? single = _single, price = _passPrice;
    final int? hours = _passHours;
    final PassMath? math = single == null || price == null || hours == null
        ? null
        : passPaysOff(
            days: _days,
            ridesPerDay: _rides,
            single: single,
            passPrice: price,
            passHours: hours,
          );
    String money(double v) => city == null
        ? NumberFormat.decimalPatternDigits(
            locale: locale,
            decimalDigits: 2,
          ).format(v)
        : _money(v, city.currency, locale);
    final TransitCard? card = city?.card;
    return <Widget>[
      if (city == null) ...<Widget>[
        _Flyra(text: t.transportNoCity),
        if (_iata == null) ...<Widget>[
          const SizedBox(height: 8),
          OutlinedButton(
            onPressed: () => unawaited(_pickAirport()),
            child: Text(t.transportPickAirport),
          ),
        ],
        const SizedBox(height: 8),
      ] else ...<Widget>[
        if (city.capping)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(t.transportCapInfo),
          ),
        if (card != null)
          _PassCard(
            badge: 'IC',
            name: card.name,
            what: t.transportCardWhat,
            good: true,
            onOfficial: () => _open(card.url),
            onHave: () => unawaited(_haveCard(city, card)),
          ),
        for (final TransitPass p in city.passes)
          _PassCard(
            badge: p.kind == PassKind.cityCard ? 'CARD' : 'PASS',
            name: p.name,
            what: p.kind == PassKind.cityCard
                ? t.transportCityCard
                : t.transportUnlimited,
            good: p.kind == PassKind.unlimited,
            onOfficial: () => _open(p.url),
            onHave: () => unawaited(_havePass(city, p)),
          ),
        if (city.passes.isEmpty && card == null)
          TextButton(
            onPressed: () => _open(city.url),
            child: Text(t.transportOfficial),
          ),
        const SizedBox(height: 12),
      ],
      // La calculadora: con los precios que la persona ve en la web oficial.
      Text(
        t.transportCalcTitle,
        style: Theme.of(context).textTheme.titleMedium,
      ),
      const SizedBox(height: 6),
      _Stepper(
        label: t.transportDays(_days),
        onMinus: _days > 1 ? () => setState(() => _days--) : null,
        onPlus: _days < 30 ? () => setState(() => _days++) : null,
      ),
      _Stepper(
        label: t.transportRides(_rides),
        onMinus: _rides > 1 ? () => setState(() => _rides--) : null,
        onPlus: _rides < 12 ? () => setState(() => _rides++) : null,
      ),
      const SizedBox(height: 8),
      _Number(
        label: t.transportSingleField,
        decimal: true,
        onChanged: (double? v) => setState(() => _single = v),
      ),
      // Separación entre campos: antes salían pegados.
      const SizedBox(height: 16),
      Row(
        children: <Widget>[
          Expanded(
            child: _Number(
              label: t.transportPassField,
              decimal: true,
              onChanged: (double? v) => setState(() => _passPrice = v),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: _Number(
              label: t.transportPassHoursField,
              decimal: false,
              onChanged: (double? v) => setState(
                () => _passHours = v == null || v < 1 || v > 24 * 31
                    ? null
                    : v.round(),
              ),
            ),
          ),
        ],
      ),
      const SizedBox(height: 16),
      _Flyra(
        text: math == null
            ? t.transportCalcHint
            : math.passPaysOff
            ? t.transportCalcWorth(money(math.passes), money(math.singles))
            : t.transportCalcNotWorth(money(math.passes), money(math.singles)),
      ),
    ];
  }

  List<Widget> _ticketList(AppLocalizations t) {
    final DateTime now = DateTime.now();
    final String locale = Localizations.localeOf(context).toLanguageTag();
    return <Widget>[
      if (_tickets.isEmpty)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Text(t.transportNoTickets),
        ),
      for (final TransitTicket k in _tickets)
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Expanded(
                      child: Text(
                        k.name,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ),
                    if (k.isPass)
                      Text(
                        (k.leftAt(now) ?? Duration.zero) > Duration.zero
                            ? '● ${t.transportActive}'
                            : t.transportExpired,
                        style: TextStyle(
                          fontWeight: FontWeight.w800,
                          color:
                              (k.leftAt(now) ?? Duration.zero) > Duration.zero
                              ? NomadColors.mint
                              : NomadColors.textMuted,
                        ),
                      ),
                    IconButton(
                      tooltip: t.transportDelete,
                      icon: const Icon(Icons.delete_outline_rounded),
                      onPressed: () => unawaited(
                        _saveTickets(<TransitTicket>[
                          for (final TransitTicket x in _tickets)
                            if (x.id != k.id) x,
                        ]),
                      ),
                    ),
                  ],
                ),
                if (k.isPass) ...<Widget>[
                  Text(t.transportPassHours(k.hours!)),
                  if ((k.leftAt(now) ?? Duration.zero) >
                      Duration.zero) ...<Widget>[
                    Text(_left(t, k.leftAt(now)!)),
                    const SizedBox(height: 6),
                    LinearProgressIndicator(value: k.leftFraction(now)),
                  ],
                ] else ...<Widget>[
                  Text(
                    k.balance == null
                        ? t.transportBalanceUnknown
                        : t.transportBalance(
                            k.currency == null
                                ? NumberFormat.decimalPattern(locale)
                                      .format(k.balance)
                                : _money(k.balance!, k.currency!, locale),
                          ),
                  ),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 8,
                    children: <Widget>[
                      OutlinedButton(
                        onPressed: () => unawaited(_editBalance(k)),
                        child: Text(t.transportEditBalance),
                      ),
                      if (k.url case final String url)
                        FilledButton.tonal(
                          onPressed: () => _open(url),
                          child: Text(t.transportTopUp),
                        ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ),
      const SizedBox(height: 8),
      OutlinedButton.icon(
        icon: const Icon(Icons.add_rounded),
        label: Text(t.transportAdd),
        onPressed: () => unawaited(_addTicket()),
      ),
      const SizedBox(height: 12),
      Text(
        t.transportTicketsNote,
        style: const TextStyle(fontSize: 12, color: NomadColors.textMuted),
      ),
    ];
  }

  String _left(AppLocalizations t, Duration left) => left.inHours >= 1
      ? t.transportLeftHours(left.inHours)
      : t.transportLeftMinutes(max(1, left.inMinutes));
}

String _kindLabel(AppLocalizations t, SpotKind k) => switch (k) {
  SpotKind.train => t.transportModeTrain,
  SpotKind.metro => t.transportModeMetro,
  SpotKind.tram => t.transportModeTram,
  SpotKind.bus => t.transportModeBus,
  _ => t.transportModeTaxi,
};

IconData _kindIcon(SpotKind k) => switch (k) {
  SpotKind.train => Icons.train_rounded,
  SpotKind.metro => Icons.subway_rounded,
  SpotKind.tram => Icons.tram_rounded,
  SpotKind.bus => Icons.directions_bus_rounded,
  _ => Icons.local_taxi_rounded,
};

Color _kindColor(SpotKind k) => switch (k) {
  SpotKind.train => NomadColors.flights,
  SpotKind.metro => NomadColors.mint,
  SpotKind.tram => NomadColors.group,
  SpotKind.bus => NomadColors.money,
  _ => NomadColors.safety,
};

class _Stepper extends StatelessWidget {
  const _Stepper({required this.label, this.onMinus, this.onPlus});

  final String label;
  final VoidCallback? onMinus;
  final VoidCallback? onPlus;

  @override
  Widget build(BuildContext context) => Row(
    children: <Widget>[
      Expanded(
        child: Text(label, style: Theme.of(context).textTheme.titleSmall),
      ),
      IconButton.outlined(
        icon: const Icon(Icons.remove_rounded),
        onPressed: onMinus,
      ),
      IconButton.outlined(
        icon: const Icon(Icons.add_rounded),
        onPressed: onPlus,
      ),
    ],
  );
}

class _Flyra extends StatelessWidget {
  const _Flyra({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: const Color(0xFF13342A),
      borderRadius: BorderRadius.circular(16),
      border: Border.all(color: const Color(0xFF23523F)),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        const FlyraAvatar(size: 28),
        const SizedBox(width: 10),
        Expanded(child: Text(text)),
      ],
    ),
  );
}

class _PassCard extends StatelessWidget {
  const _PassCard({
    required this.badge,
    required this.name,
    required this.what,
    required this.good,
    required this.onOfficial,
    required this.onHave,
  });

  final String badge;
  final String name;
  final String what;
  final bool good;
  final VoidCallback onOfficial;
  final VoidCallback onHave;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    final Color color = good ? NomadColors.mint : NomadColors.safety;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Container(
              width: 46,
              height: 46,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: color,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                badge,
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                  color: Color(0xFF0B1217),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(name, style: Theme.of(context).textTheme.titleMedium),
                  Text(
                    what,
                    style: const TextStyle(color: NomadColors.textMuted),
                  ),
                  Wrap(
                    spacing: 8,
                    children: <Widget>[
                      TextButton(
                        onPressed: onOfficial,
                        child: Text(t.transportOfficial),
                      ),
                      TextButton(
                        onPressed: onHave,
                        child: Text(t.transportHaveIt),
                      ),
                    ],
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

class _Number extends StatelessWidget {
  const _Number({
    required this.label,
    required this.decimal,
    required this.onChanged,
  });

  final String label;
  final bool decimal;
  final ValueChanged<double?> onChanged;

  @override
  Widget build(BuildContext context) => TextField(
    keyboardType: TextInputType.numberWithOptions(decimal: decimal),
    inputFormatters: <TextInputFormatter>[
      FilteringTextInputFormatter.allow(
        RegExp(decimal ? r'[0-9.,]' : r'[0-9]'),
      ),
    ],
    // Margen extra al enfocar: el campo sube y no lo tapa el teclado.
    scrollPadding: const EdgeInsets.fromLTRB(20, 20, 20, 160),
    decoration: InputDecoration(
      labelText: label,
      border: const OutlineInputBorder(),
      contentPadding: const EdgeInsets.symmetric(
        horizontal: 14,
        vertical: 14,
      ),
    ),
    onChanged: (String v) {
      final double? x = double.tryParse(v.replaceAll(',', '.'));
      onChanged(x != null && x > 0 && x < 1e7 ? x : null);
    },
  );
}

enum _FieldKind { text, integer, decimal }

class _Field {
  const _Field(this.label, this.kind, {this.initial = ''});

  final String label;
  final _FieldKind kind;
  final String initial;
}

/// Un diálogo con unos campos; devuelve lo escrito (null = cancelar).
Future<List<String>?> _ask(
  BuildContext context, {
  required String title,
  required List<_Field> fields,
}) => showDialog<List<String>>(
  context: context,
  builder: (_) => _AskDialog(title: title, fields: fields),
);

class _AskDialog extends StatefulWidget {
  const _AskDialog({required this.title, required this.fields});

  final String title;
  final List<_Field> fields;

  @override
  State<_AskDialog> createState() => _AskDialogState();
}

class _AskDialogState extends State<_AskDialog> {
  // Los controladores viven lo que el diálogo (se cierran en dispose, cuando
  // la animación de cierre ya terminó).
  late final List<TextEditingController> _c = <TextEditingController>[
    for (final _Field f in widget.fields)
      TextEditingController(text: f.initial),
  ];

  @override
  void dispose() {
    for (final TextEditingController c in _c) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    return AlertDialog(
      title: Text(widget.title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          for (int i = 0; i < widget.fields.length; i++)
            TextField(
              controller: _c[i],
              autofocus: i == 0,
              maxLength: widget.fields[i].kind == _FieldKind.text ? 60 : null,
              keyboardType: switch (widget.fields[i].kind) {
                _FieldKind.text => TextInputType.text,
                _FieldKind.integer => TextInputType.number,
                _FieldKind.decimal => const TextInputType.numberWithOptions(
                  decimal: true,
                ),
              },
              inputFormatters: <TextInputFormatter>[
                if (widget.fields[i].kind == _FieldKind.integer)
                  FilteringTextInputFormatter.digitsOnly,
                if (widget.fields[i].kind == _FieldKind.decimal)
                  FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]')),
              ],
              decoration: InputDecoration(labelText: widget.fields[i].label),
            ),
        ],
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(t.transportCancel),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, <String>[
            for (final TextEditingController c in _c) c.text,
          ]),
          child: Text(t.transportSave),
        ),
      ],
    );
  }
}
