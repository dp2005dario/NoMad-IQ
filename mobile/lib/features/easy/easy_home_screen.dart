// Modo fácil (maqueta "Facil", pantalla 48): Inicio con letras grandes,
// botones enormes y solo lo importante, en el mismo orden que la maqueta:
//   1. La fecha, "Hola, <nombre>" y el botón "Modo normal".
//   2. La tarjeta del vuelo: "TU VUELO · MAÑANA", la hora en grande, de qué
//      ciudad a qué ciudad, la puerta y a qué hora salir de casa.
//   3. Cuatro cuadrados grandes: "Llévame al hotel", "Ver a la familia",
//      "Ayuda en el aeropuerto" y "Mis papeles".
//   4. "Pregunta a Flyra · Habla, no hace falta escribir" (abre la voz).
//   5. Emergencia (no está en la maqueta: lo dejamos por seguridad).
// Todo sale de lo que tú (o alguien de tu familia) pones en "Poner mi viaje"
// y de tus contactos del SOS: nada inventado.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../auth/session.dart';
import '../../core/router.dart';
import '../../core/services.dart';
import '../../core/theme.dart';
import '../../l10n/generated/app_localizations.dart';
import '../home/home_screen.dart';
import '../route/flight3d.dart' show CountryCodes;
import '../route/world_data.dart';
import '../sos/sos_store.dart';
import '../trip/country_facts.dart';
import 'easy_mode.dart';

/// Inicio normal o Modo fácil, según lo que hayas elegido en Ajustes.
class HomeOrEasy extends StatelessWidget {
  const HomeOrEasy({super.key});

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<bool>(
    valueListenable: ServicesScope.of(context).easyMode,
    builder: (BuildContext context, bool easy, _) =>
        easy ? const EasyHomeScreen() : const HomeScreen(),
  );
}

/// Los colores de cada persona de la familia (como los círculos de la
/// maqueta): se reparten por orden.
const List<Color> _familyColors = <Color>[
  NomadColors.mint,
  Color(0xFFFF8FB1),
  NomadColors.flights,
  NomadColors.money,
  NomadColors.group,
];

class EasyHomeScreen extends StatefulWidget {
  const EasyHomeScreen({super.key});

  @override
  State<EasyHomeScreen> createState() => _EasyHomeScreenState();
}

class _EasyHomeScreenState extends State<EasyHomeScreen> {
  late final AppServices _services = ServicesScope.of(context);
  late EasyTrip _trip = loadEasyTrip(_services.prefs);

  // Los aeropuertos del mundo: para poner "Madrid → Lisboa" en vez de
  // "MAD → LIS" y saber en qué idioma hablarle al taxista. Si no cargan, se
  // enseñan las letras del aeropuerto y la frase en tu idioma.
  Airports? _airports;
  CountryCodes? _codes;
  CountryFacts? _facts;

  @override
  void initState() {
    super.initState();
    if (_trip.hasFlight) unawaited(_loadWorld());
  }

  Future<void> _loadWorld() async {
    try {
      final WorldData world = await WorldData.load();
      final CountryCodes codes = await CountryCodes.load();
      final CountryFacts facts = await CountryFacts.load();
      if (mounted) {
        setState(() {
          _airports = world.airports;
          _codes = codes;
          _facts = facts;
        });
      }
    } on Object {
      // Sin los datos se queda con las letras del aeropuerto.
    }
  }

  /// "Lisboa" para "LIS" (o "LIS" si no lo conocemos).
  String _city(String? iata) {
    if (iata == null) return '';
    final Airports? all = _airports;
    return (all == null ? null : all[iata])?.city ?? iata;
  }

  /// La frase para el taxista en el idioma del país del hotel, si la app
  /// habla ese idioma. null = no lo sabemos (se enseña solo en el tuyo).
  String? _taxiPhrase() {
    final String? to = _trip.to;
    final Airports? all = _airports;
    final Airport? a = to == null || all == null ? null : all[to];
    final String? iso = a == null ? null : _codes?[a.country];
    final CountryFact? fact = iso == null ? null : _facts?[iso];
    if (fact == null) return null;
    for (final String lang in fact.languages) {
      final bool spoken = AppLocalizations.supportedLocales.any(
        (Locale l) => l.languageCode == lang,
      );
      if (spoken) return lookupAppLocalizations(Locale(lang)).easyTaxiPhrase;
    }
    return null;
  }

  Future<void> _editTrip() async {
    // Un aviso de abajo (p. ej. "pon la dirección del hotel") taparía el
    // botón Guardar del formulario: se quita antes de abrirlo.
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    final EasyTrip? trip = await showModalBottomSheet<EasyTrip>(
      context: context,
      isScrollControlled: true,
      // Por encima de la barra de abajo (si no, tapa el botón Guardar).
      useRootNavigator: true,
      builder: (_) => EasyTripSheet(trip: _trip),
    );
    if (trip == null) return;
    await _save(trip);
    if (trip.hasFlight && _airports == null) unawaited(_loadWorld());
  }

  Future<void> _save(EasyTrip trip) async {
    await saveEasyTrip(_services.prefs, trip);
    if (mounted) setState(() => _trip = trip);
  }

  /// Abre una hoja grande desde abajo, por encima de la barra de la app.
  Future<void> _sheet(WidgetBuilder builder) => showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useRootNavigator: true,
    builder: (BuildContext sheet) => MediaQuery.withClampedTextScaling(
      minScaleFactor: 1.25,
      maxScaleFactor: 2,
      child: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
          child: builder(sheet),
        ),
      ),
    ),
  );

  /// "Llévame al hotel": la hoja con el hotel, ir andando y el taxi.
  Future<void> _toHotel(AppLocalizations t) async {
    final String? address = _trip.hotelAddress;
    if (address == null) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(t.easyNoHotel)));
      return;
    }
    await _sheet(
      (BuildContext sheet) => _HotelSheet(
        name: _trip.hotelName,
        address: address,
        phrase: _taxiPhrase(),
        onWalk: () =>
            unawaited(_services.openLink(directionsTo(address, walking: true))),
      ),
    );
  }

  /// "Ver a la familia": tus contactos del SOS.
  Future<void> _callFamily(AppLocalizations t) async {
    final List<SosContact> family = loadContacts(_services.prefs);
    await _sheet(
      (BuildContext sheet) => _FamilySheet(
        family: family,
        onCall: (SosContact c) {
          Navigator.of(sheet).pop();
          unawaited(_services.openLink(telUri(c.phone)));
        },
        onVideo: (SosContact c) {
          Navigator.of(sheet).pop();
          // WhatsApp abre el chat de esa persona: ahí está el botón de
          // videollamada (WhatsApp no deja empezarla directamente desde
          // otra app).
          unawaited(
            _services.openLink(
              Uri.https('wa.me', '/${c.dial.replaceAll('+', '')}'),
            ),
          );
        },
        onAdd: () {
          Navigator.of(sheet).pop();
          unawaited(context.push(Routes.sos));
        },
      ),
    );
  }

  /// "Ayuda en el aeropuerto": eliges qué necesitas y te dejamos el mensaje
  /// preparado para tu aerolínea.
  Future<void> _airportHelp(AppLocalizations t) async {
    final String tag = Localizations.localeOf(context).toLanguageTag();
    await _sheet(
      (BuildContext sheet) => _HelpSheet(
        asked: _trip.help,
        onAsk: (int? help) => _save(_trip.withHelp(help)),
        onSend: (int help) {
          final DateTime? dep = _trip.departure;
          final String what = _helpLabel(t, help).toLowerCase();
          final String msg = t.easyHelpMessage(
            _trip.hasFlight ? '${_city(_trip.from)} → ${_city(_trip.to)}' : '',
            dep == null ? '' : DateFormat.yMMMd(tag).format(dep),
            what,
          );
          unawaited(_services.share(<String>[], text: msg));
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    final TextTheme text = Theme.of(context).textTheme;
    final String tag = Localizations.localeOf(context).toLanguageTag();
    final String? name = displayName(SessionScope.of(context).user?.email);
    final bool helpAsked = _trip.help != null;
    // Todo un poco más grande que en el resto de la app (sin pasarse: si el
    // móvil ya tiene la letra grande, se respeta).
    return MediaQuery.withClampedTextScaling(
      minScaleFactor: 1.25,
      maxScaleFactor: 2,
      child: Scaffold(
        body: SafeArea(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 120),
            children: <Widget>[
              Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      DateFormat.MMMMEEEEd(tag).format(DateTime.now()),
                      style: const TextStyle(color: NomadColors.textMuted),
                    ),
                  ),
                  TextButton(
                    onPressed: () => unawaited(_services.easyMode.set(false)),
                    child: Text(t.easyNormal),
                  ),
                ],
              ),
              Text(
                name == null ? t.easyHelloGuest : t.easyHello(name),
                style: text.headlineMedium,
              ),
              const SizedBox(height: 16),
              _FlightCard(
                trip: _trip,
                from: _city(_trip.from),
                to: _city(_trip.to),
                onEdit: _editTrip,
              ),
              const SizedBox(height: 16),
              // Los cuatro cuadrados grandes, de dos en dos.
              _TileRow(
                left: _Tile(
                  icon: Icons.hotel_rounded,
                  color: NomadColors.mint,
                  label: t.easyToHotel,
                  onTap: () => unawaited(_toHotel(t)),
                ),
                right: _Tile(
                  icon: Icons.videocam_rounded,
                  color: const Color(0xFFFF8FB1),
                  label: t.easySeeFamily,
                  onTap: () => unawaited(_callFamily(t)),
                ),
              ),
              _TileRow(
                left: _Tile(
                  icon: helpAsked
                      ? Icons.check_circle_rounded
                      : Icons.accessible_rounded,
                  color: helpAsked ? NomadColors.mint : NomadColors.money,
                  label: helpAsked ? t.easyHelpAsked : t.easyAirportHelp,
                  highlight: true,
                  onTap: () => unawaited(_airportHelp(t)),
                ),
                right: _Tile(
                  icon: Icons.lock_rounded,
                  color: NomadColors.flights,
                  label: t.easyPapers,
                  onTap: () => unawaited(context.push(Routes.vault)),
                ),
              ),
              _BigButton(
                icon: Icons.mic_rounded,
                color: NomadColors.group,
                label: t.easyAskFlyra,
                sub: t.easyAskFlyraTalk,
                onTap: () => unawaited(context.push(Routes.voice)),
              ),
              _BigButton(
                icon: Icons.sos_rounded,
                color: NomadColors.safety,
                label: t.easySos,
                onTap: () => unawaited(context.push(Routes.sos)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// El nombre de cada tipo de ayuda del aeropuerto.
String _helpLabel(AppLocalizations t, int i) => switch (i) {
  0 => t.easyHelpWheelchair,
  1 => t.easyHelpWalk,
  _ => t.easyHelpBag,
};

/// La tarjeta del vuelo: cuándo, de dónde a dónde, la puerta y a qué hora
/// salir de casa. Si aún no hay viaje, invita a ponerlo.
class _FlightCard extends StatelessWidget {
  const _FlightCard({
    required this.trip,
    required this.from,
    required this.to,
    required this.onEdit,
  });

  final EasyTrip trip;

  /// Las ciudades ("Madrid"), o las letras del aeropuerto si no se saben.
  final String from;
  final String to;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    final TextTheme text = Theme.of(context).textTheme;
    final String tag = Localizations.localeOf(context).toLanguageTag();
    final DateTime? dep = trip.departure;
    if (!trip.hasFlight || dep == null) {
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Text(t.easyNoTrip),
              const SizedBox(height: 12),
              FilledButton(onPressed: onEdit, child: Text(t.easySetTrip)),
            ],
          ),
        ),
      );
    }
    final DateFormat hour = DateFormat.Hm(tag);
    // "HOY", "MAÑANA" o la fecha, como en la maqueta.
    final DateTime now = DateTime.now();
    final int days = DateTime(
      dep.year,
      dep.month,
      dep.day,
    ).difference(DateTime(now.year, now.month, now.day)).inDays;
    final String when = switch (days) {
      0 => t.easyToday,
      1 => t.easyTomorrow,
      _ => DateFormat.MMMEd(tag).format(dep).toUpperCase(),
    };
    final String leave = hour.format(leaveHomeAt(dep));
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: <Color>[Color(0xFF1B3A4B), Color(0xFF14252F)],
        ),
        borderRadius: BorderRadius.circular(26),
        border: Border.all(color: NomadColors.flights.withValues(alpha: 0.5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              const Icon(
                Icons.flight_takeoff_rounded,
                color: NomadColors.flights,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '${t.easyYourFlight} · $when',
                  style: text.labelLarge?.copyWith(
                    color: NomadColors.flights,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1,
                  ),
                ),
              ),
              TextButton(onPressed: onEdit, child: Text(t.easyEditTrip)),
            ],
          ),
          Text(
            hour.format(dep),
            style: text.displayMedium?.copyWith(fontWeight: FontWeight.w800),
          ),
          Text('$from → $to', style: text.titleLarge),
          const SizedBox(height: 8),
          if (trip.gate != null)
            Text.rich(
              TextSpan(
                children: <InlineSpan>[
                  TextSpan(
                    text: '${t.easyGate} ',
                    style: const TextStyle(color: NomadColors.textMuted),
                  ),
                  TextSpan(
                    text: trip.gate,
                    style: const TextStyle(
                      color: NomadColors.mint,
                      fontWeight: FontWeight.w800,
                      fontSize: 22,
                    ),
                  ),
                  TextSpan(
                    text: ' ${t.easyLeaveLower(leave)}',
                    style: const TextStyle(color: NomadColors.money),
                  ),
                ],
              ),
              style: text.titleMedium,
            )
          else
            Text(
              t.easyLeaveAt(leave),
              style: text.titleMedium?.copyWith(color: NomadColors.money),
            ),
        ],
      ),
    );
  }
}

/// Dos cuadrados grandes, uno al lado del otro.
class _TileRow extends StatelessWidget {
  const _TileRow({required this.left, required this.right});

  final Widget left;
  final Widget right;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Expanded(child: left),
          const SizedBox(width: 12),
          Expanded(child: right),
        ],
      ),
    ),
  );
}

/// Un cuadrado grande con su dibujo arriba y el nombre abajo.
class _Tile extends StatelessWidget {
  const _Tile({
    required this.icon,
    required this.color,
    required this.label,
    required this.onTap,
    this.highlight = false,
  });

  final IconData icon;
  final Color color;
  final String label;
  final VoidCallback onTap;

  /// Con el borde y el fondo de su color (el de "Ayuda en el aeropuerto").
  final bool highlight;

  @override
  Widget build(BuildContext context) => Material(
    color: highlight ? color.withValues(alpha: 0.14) : NomadColors.surface,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(26),
      side: BorderSide(
        color: highlight ? color : NomadColors.outline,
        width: 2,
      ),
    ),
    child: InkWell(
      borderRadius: BorderRadius.circular(26),
      onTap: onTap,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 138),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: <Widget>[
              CircleAvatar(
                radius: 24,
                backgroundColor: color,
                child: Icon(icon, color: NomadColors.background, size: 28),
              ),
              const SizedBox(height: 12),
              Text(
                label,
                style: Theme.of(context).textTheme.titleMedium
                    ?.copyWith(fontWeight: FontWeight.w800),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

class _BigButton extends StatelessWidget {
  const _BigButton({
    required this.icon,
    required this.color,
    required this.label,
    required this.onTap,
    this.sub,
  });

  final IconData icon;
  final Color color;
  final String label;
  final String? sub;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: Material(
      color: NomadColors.surface,
      borderRadius: BorderRadius.circular(24),
      child: InkWell(
        borderRadius: BorderRadius.circular(24),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Row(
            children: <Widget>[
              CircleAvatar(
                radius: 28,
                backgroundColor: color,
                child: Icon(icon, color: NomadColors.background, size: 30),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(label, style: Theme.of(context).textTheme.titleLarge),
                    if (sub != null)
                      Text(
                        sub!,
                        style: const TextStyle(color: NomadColors.textMuted),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

/// La hoja "Tu hotel": el nombre, la dirección, ir andando o enseñárselo al
/// taxista (una tarjeta enorme con la frase en el idioma de allí).
class _HotelSheet extends StatefulWidget {
  const _HotelSheet({
    required this.name,
    required this.address,
    required this.phrase,
    required this.onWalk,
  });

  final String? name;
  final String address;

  /// "Por favor, leve-me a este hotel. Obrigado." (null = no sabemos el
  /// idioma de allí).
  final String? phrase;
  final VoidCallback onWalk;

  @override
  State<_HotelSheet> createState() => _HotelSheetState();
}

class _HotelSheetState extends State<_HotelSheet> {
  bool _taxi = false;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    final TextTheme text = Theme.of(context).textTheme;
    final String name = widget.name ?? t.easyYourHotel;
    if (_taxi) {
      // La tarjeta para el taxista: fondo claro y letras enormes.
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: const Color(0xFFF2F5F3),
              borderRadius: BorderRadius.circular(24),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  t.easyTaxiTitle,
                  style: text.labelLarge?.copyWith(
                    color: const Color(0xFF55636B),
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1,
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  name,
                  style: text.headlineMedium?.copyWith(
                    color: NomadColors.background,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  widget.address,
                  style: text.titleLarge?.copyWith(
                    color: NomadColors.background,
                  ),
                ),
                const SizedBox(height: 14),
                Text(
                  widget.phrase ?? t.easyTaxiPhrase,
                  style: text.titleMedium?.copyWith(
                    color: const Color(0xFF55636B),
                    fontStyle: FontStyle.italic,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          OutlinedButton(
            style: OutlinedButton.styleFrom(minimumSize: const Size(0, 56)),
            onPressed: () => setState(() => _taxi = false),
            child: Text(t.easyBack),
          ),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _SheetTitle(t.easyYourHotel),
        Text(
          name,
          style: text.headlineSmall?.copyWith(fontWeight: FontWeight.w800),
        ),
        Text(
          widget.address,
          style: text.titleMedium?.copyWith(color: NomadColors.textMuted),
        ),
        const SizedBox(height: 20),
        FilledButton(
          style: FilledButton.styleFrom(minimumSize: const Size(0, 60)),
          onPressed: widget.onWalk,
          child: Text(t.easyWalk),
        ),
        const SizedBox(height: 12),
        OutlinedButton(
          style: OutlinedButton.styleFrom(minimumSize: const Size(0, 60)),
          onPressed: () => setState(() => _taxi = true),
          child: Text(t.easyShowTaxi),
        ),
      ],
    );
  }
}

/// El título de una hoja, con la X para cerrarla.
class _SheetTitle extends StatelessWidget {
  const _SheetTitle(this.title);

  final String title;

  @override
  Widget build(BuildContext context) => Row(
    children: <Widget>[
      Expanded(
        child: Text(title, style: Theme.of(context).textTheme.titleLarge),
      ),
      IconButton(
        tooltip: MaterialLocalizations.of(context).closeButtonLabel,
        icon: const Icon(Icons.close_rounded),
        onPressed: () => Navigator.of(context).pop(),
      ),
    ],
  );
}

/// La hoja "¿A quién llamas?" con tus contactos del SOS.
class _FamilySheet extends StatelessWidget {
  const _FamilySheet({
    required this.family,
    required this.onCall,
    required this.onVideo,
    required this.onAdd,
  });

  final List<SosContact> family;
  final ValueChanged<SosContact> onCall;
  final ValueChanged<SosContact> onVideo;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    final TextTheme text = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _SheetTitle(t.easyWhoCall),
        if (family.isEmpty) ...<Widget>[
          Text(t.easyNoFamily, style: text.titleMedium),
          const SizedBox(height: 16),
          FilledButton(
            style: FilledButton.styleFrom(minimumSize: const Size(0, 56)),
            onPressed: onAdd,
            child: Text(t.easyAddFamily),
          ),
        ] else ...<Widget>[
          for (int i = 0; i < family.length; i++)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Material(
                color: NomadColors.surface,
                borderRadius: BorderRadius.circular(20),
                child: InkWell(
                  borderRadius: BorderRadius.circular(20),
                  onTap: () => onCall(family[i]),
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Row(
                      children: <Widget>[
                        CircleAvatar(
                          radius: 29,
                          backgroundColor:
                              _familyColors[i % _familyColors.length],
                          child: Text(
                            family[i].name.isEmpty
                                ? '?'
                                : family[i].name[0].toUpperCase(),
                            style: const TextStyle(
                              color: NomadColors.background,
                              fontSize: 26,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: <Widget>[
                              Text(
                                family[i].name,
                                style: text.titleLarge?.copyWith(
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                              Text(
                                family[i].phone,
                                style: const TextStyle(
                                  color: NomadColors.textMuted,
                                ),
                              ),
                            ],
                          ),
                        ),
                        IconButton.filled(
                          tooltip: 'WhatsApp',
                          style: IconButton.styleFrom(
                            backgroundColor: NomadColors.mint,
                            foregroundColor: NomadColors.background,
                            minimumSize: const Size(56, 56),
                          ),
                          icon: const Icon(Icons.videocam_rounded),
                          onPressed: () => onVideo(family[i]),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          const SizedBox(height: 4),
          Text(
            t.easyCallHint,
            textAlign: TextAlign.center,
            style: const TextStyle(color: NomadColors.textMuted),
          ),
        ],
      ],
    );
  }
}

/// La hoja "Ayuda en el aeropuerto": eliges qué necesitas, la pides y te
/// queda el mensaje listo para enviárselo a tu aerolínea.
class _HelpSheet extends StatefulWidget {
  const _HelpSheet({
    required this.asked,
    required this.onAsk,
    required this.onSend,
  });

  /// La que ya pediste (null = ninguna).
  final int? asked;
  final Future<void> Function(int? help) onAsk;
  final ValueChanged<int> onSend;

  @override
  State<_HelpSheet> createState() => _HelpSheetState();
}

class _HelpSheetState extends State<_HelpSheet> {
  late int _opt = widget.asked ?? 0;
  late bool _asked = widget.asked != null;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    final TextTheme text = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _SheetTitle(t.easyAirportHelp),
        if (!_asked) ...<Widget>[
          Text(t.easyAirportHelpWhy, style: text.titleMedium),
          const SizedBox(height: 16),
          for (int i = 0; i < 3; i++)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Material(
                color: i == _opt
                    ? const Color(0xFF2A2418)
                    : NomadColors.surface,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(18),
                  side: BorderSide(
                    color: i == _opt ? NomadColors.money : NomadColors.outline,
                    width: i == _opt ? 3 : 2,
                  ),
                ),
                child: InkWell(
                  borderRadius: BorderRadius.circular(18),
                  onTap: () => setState(() => _opt = i),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(minHeight: 60),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Row(
                        children: <Widget>[
                          Icon(
                            i == _opt
                                ? Icons.radio_button_checked_rounded
                                : Icons.radio_button_off_rounded,
                            color: i == _opt
                                ? NomadColors.money
                                : NomadColors.textMuted,
                          ),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Text(
                              _helpLabel(t, i),
                              style: text.titleMedium?.copyWith(
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          const SizedBox(height: 6),
          FilledButton(
            style: FilledButton.styleFrom(
              minimumSize: const Size(0, 60),
              backgroundColor: NomadColors.money,
            ),
            onPressed: () async {
              await widget.onAsk(_opt);
              if (mounted) setState(() => _asked = true);
            },
            child: Text(t.easyHelpAsk),
          ),
        ] else ...<Widget>[
          Text(
            t.easyHelpDone(_helpLabel(t, _opt).toLowerCase()),
            style: text.titleMedium,
          ),
          const SizedBox(height: 16),
          FilledButton(
            style: FilledButton.styleFrom(minimumSize: const Size(0, 60)),
            onPressed: () => widget.onSend(_opt),
            child: Text(t.easyHelpSend),
          ),
          const SizedBox(height: 10),
          OutlinedButton(
            style: OutlinedButton.styleFrom(minimumSize: const Size(0, 56)),
            onPressed: () async {
              await widget.onAsk(null);
              if (mounted) setState(() => _asked = false);
            },
            child: Text(t.easyHelpChange),
          ),
        ],
      ],
    );
  }
}

/// Para poner o cambiar el viaje (lo puede hacer alguien de la familia).
class EasyTripSheet extends StatefulWidget {
  const EasyTripSheet({super.key, required this.trip});

  final EasyTrip trip;

  @override
  State<EasyTripSheet> createState() => _EasyTripSheetState();
}

class _EasyTripSheetState extends State<EasyTripSheet> {
  late final TextEditingController _from = TextEditingController(
    text: widget.trip.from,
  );
  late final TextEditingController _to = TextEditingController(
    text: widget.trip.to,
  );
  late final TextEditingController _gate = TextEditingController(
    text: widget.trip.gate,
  );
  late final TextEditingController _hotel = TextEditingController(
    text: widget.trip.hotelName,
  );
  late final TextEditingController _address = TextEditingController(
    text: widget.trip.hotelAddress,
  );
  late DateTime? _departure = widget.trip.departure;

  @override
  void dispose() {
    for (final TextEditingController c in <TextEditingController>[
      _from,
      _to,
      _gate,
      _hotel,
      _address,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _pick() async {
    final DateTime now = DateTime.now();
    final DateTime? day = await showDatePicker(
      context: context,
      firstDate: DateTime(now.year, now.month, now.day),
      lastDate: DateTime(now.year + 2),
      initialDate: _departure ?? now,
    );
    if (day == null || !mounted) return;
    final TimeOfDay? time = await showTimePicker(
      context: context,
      initialTime: _departure == null
          ? const TimeOfDay(hour: 10, minute: 0)
          : TimeOfDay.fromDateTime(_departure!),
    );
    if (time == null || !mounted) return;
    setState(
      () => _departure = DateTime(
        day.year,
        day.month,
        day.day,
        time.hour,
        time.minute,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    final String tag = Localizations.localeOf(context).toLanguageTag();
    final DateTime? dep = _departure;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        20,
        20,
        20,
        20 + MediaQuery.of(context).viewInsets.bottom,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text(
              t.easyDeparture,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: _pick,
              icon: const Icon(Icons.event_rounded),
              label: Text(
                dep == null
                    ? t.easyPickDay
                    : DateFormat.yMMMEd(tag).add_Hm().format(dep),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: <Widget>[
                Expanded(
                  child: TextField(
                    controller: _from,
                    maxLength: 3,
                    textCapitalization: TextCapitalization.characters,
                    decoration: InputDecoration(
                      labelText: t.easyFrom,
                      counterText: '',
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: _to,
                    maxLength: 3,
                    textCapitalization: TextCapitalization.characters,
                    decoration: InputDecoration(
                      labelText: t.easyTo,
                      counterText: '',
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _gate,
              maxLength: 8,
              decoration: InputDecoration(
                labelText: t.easyGateField,
                counterText: '',
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _hotel,
              decoration: InputDecoration(labelText: t.easyHotelName),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _address,
              decoration: InputDecoration(labelText: t.easyHotelAddress),
            ),
            const SizedBox(height: 20),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(
                EasyTrip.parse(<String, Object?>{
                  if (dep != null) 'departure': dep.toIso8601String(),
                  'from': _from.text,
                  'to': _to.text,
                  'gate': _gate.text,
                  'hotel_name': _hotel.text,
                  'hotel_address': _address.text,
                  // La ayuda del aeropuerto ya pedida se conserva.
                  'help': ?widget.trip.help,
                }),
              ),
              child: Text(t.easySave),
            ),
          ],
        ),
      ),
    );
  }
}
