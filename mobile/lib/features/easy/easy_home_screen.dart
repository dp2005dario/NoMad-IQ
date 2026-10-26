// Modo fácil (maqueta "Facil"): Inicio con letras grandes, botones enormes y
// solo lo importante. Arriba, el vuelo y a qué hora salir de casa; debajo,
// los cinco botones que de verdad se usan en un viaje.
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
import '../sos/sos_store.dart';
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

class EasyHomeScreen extends StatefulWidget {
  const EasyHomeScreen({super.key});

  @override
  State<EasyHomeScreen> createState() => _EasyHomeScreenState();
}

class _EasyHomeScreenState extends State<EasyHomeScreen> {
  late final AppServices _services = ServicesScope.of(context);
  late EasyTrip _trip = loadEasyTrip(_services.prefs);

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
    await saveEasyTrip(_services.prefs, trip);
    if (mounted) setState(() => _trip = trip);
  }

  Future<void> _toHotel(AppLocalizations t) async {
    final String? address = _trip.hotelAddress;
    if (address == null) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(t.easyNoHotel)));
      return;
    }
    await _services.openLink(directionsTo(address));
  }

  Future<void> _callFamily(AppLocalizations t) async {
    final List<SosContact> family = loadContacts(_services.prefs);
    await showDialog<void>(
      context: context,
      builder: (BuildContext dialog) => AlertDialog(
        title: Text(t.easyWhoCall),
        content: family.isEmpty
            ? Text(t.easyNoFamily, style: const TextStyle(fontSize: 18))
            : Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  for (final SosContact c in family)
                    ListTile(
                      leading: CircleAvatar(
                        child: Text(c.name.isEmpty ? '?' : c.name[0]),
                      ),
                      title: Text(c.name, style: const TextStyle(fontSize: 20)),
                      subtitle: Text(c.phone),
                      trailing: const Icon(Icons.call_rounded),
                      onTap: () {
                        Navigator.of(dialog).pop();
                        unawaited(_services.openLink(telUri(c.phone)));
                      },
                    ),
                ],
              ),
        actions: <Widget>[
          if (family.isEmpty)
            TextButton(
              onPressed: () {
                Navigator.of(dialog).pop();
                unawaited(context.push(Routes.sos));
              },
              child: Text(t.easyAddFamily),
            ),
          TextButton(
            onPressed: () => Navigator.of(dialog).pop(),
            child: Text(MaterialLocalizations.of(dialog).closeButtonLabel),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    final TextTheme text = Theme.of(context).textTheme;
    final String tag = Localizations.localeOf(context).toLanguageTag();
    final String? name = displayName(SessionScope.of(context).user?.email);
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
              _FlightCard(trip: _trip, onEdit: _editTrip),
              const SizedBox(height: 16),
              _BigButton(
                icon: Icons.hotel_rounded,
                color: NomadColors.mint,
                label: t.easyToHotel,
                onTap: () => unawaited(_toHotel(t)),
              ),
              _BigButton(
                icon: Icons.call_rounded,
                color: NomadColors.group,
                label: t.easyFamily,
                onTap: () => unawaited(_callFamily(t)),
              ),
              _BigButton(
                icon: Icons.lock_rounded,
                color: NomadColors.money,
                label: t.easyPapers,
                onTap: () => unawaited(context.push(Routes.vault)),
              ),
              _BigButton(
                icon: Icons.auto_awesome_rounded,
                color: NomadColors.flights,
                label: t.easyAskFlyra,
                sub: t.easyAskFlyraWhy,
                onTap: () => unawaited(context.push(Routes.flyra())),
              ),
              _BigButton(
                icon: Icons.sos_rounded,
                color: NomadColors.safety,
                label: t.easySos,
                onTap: () => unawaited(context.push(Routes.sos)),
              ),
              const SizedBox(height: 8),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Row(
                        children: <Widget>[
                          const Icon(
                            Icons.accessible_rounded,
                            color: NomadColors.mint,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              t.easyAirportHelp,
                              style: text.titleMedium,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Text(t.easyAirportHelpWhy),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// La tarjeta del vuelo: cuándo, de dónde a dónde, la puerta y a qué hora
/// salir de casa. Si aún no hay viaje, invita a ponerlo.
class _FlightCard extends StatelessWidget {
  const _FlightCard({required this.trip, required this.onEdit});

  final EasyTrip trip;
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
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    '${t.easyYourFlight} · ${DateFormat.MMMEd(tag).format(dep)}',
                    style: text.labelLarge,
                  ),
                ),
                TextButton(onPressed: onEdit, child: Text(t.easyEditTrip)),
              ],
            ),
            Text(hour.format(dep), style: text.displaySmall),
            Text('${trip.from} → ${trip.to}', style: text.titleLarge),
            if (trip.gate != null)
              Text(
                '${t.easyGate} ${trip.gate}',
                style: text.titleMedium?.copyWith(color: NomadColors.mint),
              ),
            const SizedBox(height: 8),
            Text(
              t.easyLeaveAt(hour.format(leaveHomeAt(dep))),
              style: text.titleMedium?.copyWith(color: NomadColors.money),
            ),
          ],
        ),
      ),
    );
  }
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
