// SOS (maqueta "Sos"): un botón que se mantiene pulsado 3 segundos (para
// que no salte sin querer en el bolsillo), los números de emergencia del
// país donde estás, tus contactos, "¡Ayuda!" en el idioma local, tu ficha
// médica y las embajadas cercanas.
//
// Todo funciona SIN servidor: la ubicación la da el GPS, el país se saca de
// los datos que la app lleva dentro y el aviso es un SMS que mandas tú.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/services.dart';
import '../../core/settings.dart';
import '../../core/theme.dart';
import '../../l10n/generated/app_localizations.dart';
import '../map/geo.dart';
import '../map/location.dart';
import 'emergency_data.dart';
import 'sos_store.dart';
import 'where_am_i.dart';

/// Cuánto hay que mantener el botón.
const Duration sosHold = Duration(seconds: 3);

class SosScreen extends StatefulWidget {
  const SosScreen({super.key, this.locate = whereabouts});

  /// País y ciudad de un punto (en los tests, uno fijo).
  final Future<Whereabouts> Function(GeoPoint) locate;

  @override
  State<SosScreen> createState() => _SosScreenState();
}

class _SosScreenState extends State<SosScreen> with TickerProviderStateMixin {
  late final AppServices _services = ServicesScope.of(context);
  late final SettingsStore _prefs = _services.prefs;
  late final AnimationController _hold = AnimationController(
    vsync: this,
    duration: sosHold,
  )..addStatusListener(_onHold);

  /// El "latido" de la luz de alarma: va y viene sin parar, pero SOLO
  /// mientras mantienes el botón (si no, la pantalla nunca se quedaría quieta).
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 800),
  );

  PositionFix? _fix;
  Whereabouts _where = const Whereabouts();
  bool _locating = true;
  bool _active = false;
  late List<SosContact> _contacts = loadContacts(_prefs);
  late MedicalCard _card = MedicalCard.load(_prefs);

  @override
  void initState() {
    super.initState();
    unawaited(_locate());
  }

  @override
  void dispose() {
    _hold.dispose();
    _pulse.dispose();
    super.dispose();
  }

  Future<void> _locate() async {
    final LocationSource gps = _services.location;
    try {
      LocationAccess access = await gps.check();
      if (access == LocationAccess.denied) access = await gps.request();
      if (access == LocationAccess.granted) {
        final PositionFix fix = await gps.watch().first.timeout(
          const Duration(seconds: 15),
        );
        final Whereabouts where = await widget.locate(fix.point);
        if (!mounted) return;
        setState(() {
          _fix = fix;
          _where = where;
        });
      }
    } on Object {
      // Sin GPS: el SOS sigue funcionando (el 112 y los contactos).
    }
    if (mounted) setState(() => _locating = false);
  }

  void _onHold(AnimationStatus status) {
    if (status == AnimationStatus.forward) {
      // Empieza a pulsar la luz roja (salvo que el usuario pida reducir
      // animaciones: entonces el fondo solo se enciende, sin parpadear).
      unawaited(HapticFeedback.selectionClick());
      if (!MediaQuery.disableAnimationsOf(context)) {
        _pulse.repeat(reverse: true);
      }
    } else {
      _pulse.stop();
    }
    if (status == AnimationStatus.completed) {
      unawaited(HapticFeedback.heavyImpact());
      setState(() => _active = true);
      _hold.reset();
    }
  }

  Future<void> _open(Uri uri) async {
    await _services.openLink(uri);
  }

  Future<void> _textContacts(AppLocalizations t) =>
      _open(smsUri(_contacts, sosMessage(t.sosMessage, _fix?.point)));

  Future<void> _addContact() async {
    if (_contacts.length >= maxSosContacts) return;
    final SosContact? c = await showDialog<SosContact>(
      context: context,
      builder: (BuildContext context) => const _ContactDialog(),
    );
    if (c == null || !mounted) return;
    setState(() => _contacts = <SosContact>[..._contacts, c]);
    await saveContacts(_prefs, _contacts);
  }

  Future<void> _removeContact(SosContact c) async {
    setState(() => _contacts = <SosContact>[..._contacts]..remove(c));
    await saveContacts(_prefs, _contacts);
  }

  Future<void> _editCard() async {
    final MedicalCard? card = await showDialog<MedicalCard>(
      context: context,
      builder: (BuildContext context) => _MedicalDialog(card: _card),
    );
    if (card == null || !mounted) return;
    setState(() => _card = card);
    await card.save(_prefs);
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    final TextTheme text = Theme.of(context).textTheme;
    final EmergencyNumbers numbers = numbersFor(_where.country);
    final HelpPhrase? phrase = phraseFor(_where.country);
    final GeoPoint? me = _fix?.point;

    final String place = _locating
        ? t.sosLocating
        : me == null
        ? t.sosNoLocation
        : <String>[
            if (_where.city != null) t.sosNear(_where.city!),
            t.sosAccuracy(_fix!.accuracyM.round()),
          ].join(' · ');

    final Widget page = Scaffold(
      backgroundColor: _active ? const Color(0xFF2A0909) : Colors.transparent,
      appBar: AppBar(
        title: Text(t.sosTitle),
        backgroundColor: _active ? const Color(0xFF2A0909) : null,
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
        children: <Widget>[
          Row(
            children: <Widget>[
              const Icon(
                Icons.place_rounded,
                size: 18,
                color: NomadColors.safety,
              ),
              const SizedBox(width: 6),
              Expanded(child: Text(place, style: text.bodySmall)),
            ],
          ),
          const SizedBox(height: 16),
          Text(
            _active ? t.sosActive : t.sosQuestion,
            style: text.headlineMedium,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          if (!_active)
            Text(
              t.sosHoldHint,
              textAlign: TextAlign.center,
              style: text.bodyMedium?.copyWith(color: NomadColors.textMuted),
            ),
          const SizedBox(height: 20),
          if (!_active)
            Center(
              child: _HoldButton(hold: _hold, label: t.sosButtonLabel),
            )
          else ...<Widget>[
            FilledButton.icon(
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFFE53935),
                foregroundColor: Colors.white,
                minimumSize: const Size.fromHeight(64),
              ),
              icon: const Icon(Icons.call_rounded),
              label: Text(t.sosCall(numbers.general)),
              onPressed: () => _open(telUri(numbers.general)),
            ),
            const SizedBox(height: 10),
            if (_contacts.isEmpty)
              Text(t.sosNoContacts, textAlign: TextAlign.center)
            else
              OutlinedButton.icon(
                icon: const Icon(Icons.sms_rounded),
                label: Text(t.sosTextContacts),
                onPressed: () => _textContacts(t),
              ),
            TextButton(
              onPressed: () => setState(() => _active = false),
              child: Text(t.sosImOk),
            ),
          ],
          _Section(t.sosNumbersTitle),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              for (final (String label, String? n) in <(String, String?)>[
                (t.sosGeneral, numbers.general),
                (t.sosPolice, numbers.police),
                (t.sosAmbulance, numbers.ambulance),
                (t.sosFire, numbers.fire),
              ])
                if (n != null &&
                    (label == t.sosGeneral || n != numbers.general))
                  ActionChip(
                    avatar: const Icon(Icons.call_rounded, size: 18),
                    label: Text('$label · $n'),
                    onPressed: () => _open(telUri(n)),
                  ),
            ],
          ),
          // De dónde salen los números, para poder comprobarlos.
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton.icon(
              icon: const Icon(Icons.verified_outlined, size: 18),
              label: Text(t.dataSourceCheck),
              onPressed: () => _open(Uri.parse(emergencySource)),
            ),
          ),
          _Section(t.sosContactsTitle),
          Card(
            child: Column(
              children: <Widget>[
                for (final SosContact c in _contacts)
                  ListTile(
                    leading: CircleAvatar(
                      backgroundColor: NomadColors.group,
                      foregroundColor: NomadColors.background,
                      child: Text(c.name.characters.first.toUpperCase()),
                    ),
                    title: Text(c.name),
                    subtitle: Text(c.phone),
                    trailing: IconButton(
                      tooltip: t.sosDelete,
                      icon: const Icon(Icons.close_rounded),
                      onPressed: () => _removeContact(c),
                    ),
                  ),
                if (_contacts.length < maxSosContacts)
                  ListTile(
                    leading: const Icon(
                      Icons.person_add_rounded,
                      color: NomadColors.mint,
                    ),
                    title: Text(t.sosAddContact),
                    onTap: _addContact,
                  ),
              ],
            ),
          ),
          if (phrase != null) ...<Widget>[
            _Section(t.sosSayThis),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  children: <Widget>[
                    Text(
                      phrase.text,
                      style: text.displaySmall,
                      textAlign: TextAlign.center,
                    ),
                    if (phrase.sounds != null)
                      Text(
                        '«${phrase.sounds}»',
                        style: text.titleMedium,
                        textAlign: TextAlign.center,
                      ),
                    const SizedBox(height: 4),
                    Text(
                      t.sosMeansHelp,
                      style: text.bodySmall?.copyWith(
                        color: NomadColors.textMuted,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
          _Section(t.sosMedicalTitle),
          Card(
            child: ListTile(
              leading: const Icon(
                Icons.medical_information_rounded,
                color: NomadColors.safety,
              ),
              title: Text(_card.isEmpty ? t.sosMedicalEmpty : _card.summary()),
              subtitle: Text(t.sosMedicalPrivacy),
              trailing: const Icon(Icons.edit_rounded),
              onTap: _editCard,
            ),
          ),
          const SizedBox(height: 12),
          if (me != null)
            Card(
              child: ListTile(
                leading: const Icon(
                  Icons.account_balance_rounded,
                  color: NomadColors.flights,
                ),
                title: Text(t.sosEmbassies),
                subtitle: Text(t.sosEmbassiesSub),
                trailing: const Icon(Icons.open_in_new_rounded),
                onTap: () => _open(embassiesUri(me)),
              ),
            ),
        ],
      ),
    );
    // La luz de alarma va por detrás del Scaffold (que es transparente) y no
    // recibe toques.
    return Stack(
      children: <Widget>[
        const Positioned.fill(child: ColoredBox(color: NomadColors.background)),
        Positioned.fill(
          child: IgnorePointer(
            child: _AlarmGlow(hold: _hold, pulse: _pulse),
          ),
        ),
        page,
      ],
    );
  }
}

/// Resplandor rojo de fondo, como la luz de una alarma de emergencia: crece
/// mientras mantienes el botón y late suave (nada de destellos bruscos).
class _AlarmGlow extends StatelessWidget {
  const _AlarmGlow({required this.hold, required this.pulse});

  final Animation<double> hold;
  final Animation<double> pulse;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge(<Listenable>[hold, pulse]),
    builder: (BuildContext context, _) {
      // Sin pulsar no se pinta nada.
      if (hold.value == 0) return const SizedBox.shrink();
      // De 0.55 a 1.0: el latido nunca apaga del todo la luz.
      final double beat = 0.55 + 0.45 * Curves.easeInOut.transform(pulse.value);
      final double alpha = (0.12 + 0.38 * hold.value) * beat;
      return DecoratedBox(
        key: const ValueKey<String>('sos-glow'),
        decoration: BoxDecoration(
          gradient: RadialGradient(
            radius: 1.1,
            colors: <Color>[
              const Color(0xFFE53935).withValues(alpha: alpha),
              const Color(0xFF2A0909).withValues(alpha: alpha * 0.6),
            ],
          ),
        ),
      );
    },
  );
}

/// El botón rojo grande: se va llenando mientras lo mantienes pulsado.
class _HoldButton extends StatelessWidget {
  const _HoldButton({required this.hold, required this.label});

  final AnimationController hold;
  final String label;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: label,
    // Con lector de pantalla, mantener pulsado es difícil: un doble toque
    // largo del lector también lo activa.
    onLongPress: () => hold.forward(from: 0),
    child: Listener(
      onPointerDown: (_) => hold.forward(from: 0),
      onPointerUp: (_) {
        if (!hold.isCompleted) hold.reverse();
      },
      onPointerCancel: (_) => hold.reverse(),
      child: AnimatedBuilder(
        animation: hold,
        builder: (BuildContext context, _) {
          final int left = (sosHold.inSeconds * (1 - hold.value)).ceil();
          return SizedBox(
            key: const ValueKey<String>('sos-hold'),
            width: 200,
            height: 200,
            child: Stack(
              alignment: Alignment.center,
              children: <Widget>[
                SizedBox.expand(
                  child: CircularProgressIndicator(
                    value: hold.value,
                    strokeWidth: 8,
                    color: Colors.white,
                    backgroundColor: Colors.white12,
                  ),
                ),
                Container(
                  width: 170,
                  height: 170,
                  alignment: Alignment.center,
                  decoration: const BoxDecoration(
                    shape: BoxShape.circle,
                    color: Color(0xFFE53935),
                  ),
                  child: Text(
                    hold.value > 0 ? '$left' : 'SOS',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 44,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    ),
  );
}

class _Section extends StatelessWidget {
  const _Section(this.label);

  final String label;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(4, 24, 4, 8),
    child: Text(
      label,
      style: Theme.of(context).textTheme.labelMedium
          ?.copyWith(color: NomadColors.textMuted, letterSpacing: 1.2),
    ),
  );
}

class _ContactDialog extends StatefulWidget {
  const _ContactDialog();

  @override
  State<_ContactDialog> createState() => _ContactDialogState();
}

class _ContactDialogState extends State<_ContactDialog> {
  final TextEditingController _name = TextEditingController();
  final TextEditingController _phone = TextEditingController();
  bool _tried = false;

  @override
  void dispose() {
    _name.dispose();
    _phone.dispose();
    super.dispose();
  }

  void _save() {
    final String name = _name.text.trim();
    final String phone = _phone.text.trim();
    if (name.isEmpty || !SosContact.isPhone(phone)) {
      setState(() => _tried = true);
      return;
    }
    Navigator.pop(context, SosContact(name: name, phone: phone));
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    final bool badPhone = _tried && !SosContact.isPhone(_phone.text);
    return AlertDialog(
      title: Text(t.sosAddContact),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          TextField(
            controller: _name,
            maxLength: 40,
            textCapitalization: TextCapitalization.words,
            decoration: InputDecoration(labelText: t.sosContactName),
          ),
          TextField(
            controller: _phone,
            keyboardType: TextInputType.phone,
            decoration: InputDecoration(
              labelText: t.sosContactPhone,
              errorText: badPhone ? t.sosContactInvalid : null,
            ),
          ),
        ],
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(MaterialLocalizations.of(context).cancelButtonLabel),
        ),
        FilledButton(
          style: FilledButton.styleFrom(minimumSize: const Size(0, 48)),
          onPressed: _save,
          child: Text(t.sosSave),
        ),
      ],
    );
  }
}

class _MedicalDialog extends StatefulWidget {
  const _MedicalDialog({required this.card});

  final MedicalCard card;

  @override
  State<_MedicalDialog> createState() => _MedicalDialogState();
}

class _MedicalDialogState extends State<_MedicalDialog> {
  late String? _blood = widget.card.blood;
  late final TextEditingController _allergies = TextEditingController(
    text: widget.card.allergies,
  );
  late final TextEditingController _conditions = TextEditingController(
    text: widget.card.conditions,
  );
  late final TextEditingController _medication = TextEditingController(
    text: widget.card.medication,
  );

  @override
  void dispose() {
    _allergies.dispose();
    _conditions.dispose();
    _medication.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    final TextTheme text = Theme.of(context).textTheme;
    return AlertDialog(
      title: Text(t.sosMedicalEdit),
      content: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            // Grupo sanguíneo: botones grandes en rejilla, un toque y listo.
            Row(
              children: <Widget>[
                const Icon(Icons.bloodtype_rounded, color: NomadColors.safety),
                const SizedBox(width: 8),
                Text(t.sosBlood, style: text.titleSmall),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              t.sosBloodPick,
              style: text.bodySmall?.copyWith(color: NomadColors.textMuted),
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: <Widget>[
                for (final String b in bloodTypes)
                  _BloodChip(
                    label: b.replaceAll('-', '\u2212'),
                    selected: _blood == b,
                    onTap: () => setState(() => _blood = b),
                  ),
                _BloodChip(
                  label: t.sosBloodUnknown,
                  selected: _blood == null,
                  onTap: () => setState(() => _blood = null),
                ),
              ],
            ),
            const SizedBox(height: 20),
            _MedicalField(
              icon: Icons.warning_amber_rounded,
              label: t.sosAllergies,
              hint: t.sosAllergiesHint,
              controller: _allergies,
            ),
            _MedicalField(
              icon: Icons.medication_rounded,
              label: t.sosMedication,
              hint: t.sosMedicationHint,
              controller: _medication,
            ),
            _MedicalField(
              icon: Icons.monitor_heart_rounded,
              label: t.sosConditions,
              hint: t.sosConditionsHint,
              controller: _conditions,
            ),
            Row(
              children: <Widget>[
                const Icon(
                  Icons.lock_outline_rounded,
                  size: 16,
                  color: NomadColors.textMuted,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    t.sosMedicalPrivacy,
                    style: text.bodySmall?.copyWith(
                      color: NomadColors.textMuted,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(MaterialLocalizations.of(context).cancelButtonLabel),
        ),
        FilledButton(
          style: FilledButton.styleFrom(minimumSize: const Size(0, 48)),
          onPressed: () => Navigator.pop(
            context,
            MedicalCard(
              blood: _blood,
              allergies: _allergies.text.trim(),
              conditions: _conditions.text.trim(),
              medication: _medication.text.trim(),
            ),
          ),
          child: Text(t.sosSave),
        ),
      ],
    );
  }
}

/// Un botón de la rejilla de grupos sanguíneos (menta si está elegido).
class _BloodChip extends StatelessWidget {
  const _BloodChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => ChoiceChip(
    label: Text(label),
    selected: selected,
    showCheckmark: false,
    selectedColor: NomadColors.mint,
    labelStyle: TextStyle(
      fontWeight: FontWeight.w800,
      color: selected ? NomadColors.background : null,
    ),
    // Un poco más alto: cómodo de pulsar con el dedo.
    visualDensity: const VisualDensity(vertical: 1),
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
    onSelected: (_) => onTap(),
  );
}

/// Un campo de la ficha: icono, nombre y un ejemplo para saber qué escribir.
class _MedicalField extends StatelessWidget {
  const _MedicalField({
    required this.icon,
    required this.label,
    required this.hint,
    required this.controller,
  });

  final IconData icon;
  final String label;
  final String hint;
  final TextEditingController controller;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 14),
    child: TextField(
      controller: controller,
      maxLength: 200,
      minLines: 1,
      maxLines: 3,
      textCapitalization: TextCapitalization.sentences,
      decoration: InputDecoration(
        prefixIcon: Icon(icon),
        labelText: label,
        hintText: hint,
        counterText: '',
        filled: true,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
      ),
    ),
  );
}
