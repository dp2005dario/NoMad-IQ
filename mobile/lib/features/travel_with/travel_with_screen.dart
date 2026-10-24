// "Viajo con…" (maqueta "ViajoCon"): dos pestañas, "Mi mascota" y
// "Embarazada". Todo se calcula en el móvil con reglas generales y no se
// manda nada a ningún sitio. Las semanas de embarazo ni siquiera se guardan:
// es un dato de salud y solo hace falta mientras miras la pantalla.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/services.dart';
import '../../core/theme.dart';
import '../../l10n/generated/app_localizations.dart';
import 'travel_with.dart';

class TravelWithScreen extends StatelessWidget {
  const TravelWithScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: Text(t.twTitle),
          bottom: TabBar(
            tabs: <Widget>[
              Tab(text: t.twTabPet),
              Tab(text: t.twTabPregnant),
            ],
          ),
        ),
        body: const TabBarView(children: <Widget>[_PetTab(), _PregnancyTab()]),
      ),
    );
  }
}

// --- Mascota -----------------------------------------------------------------

class _PetTab extends StatefulWidget {
  const _PetTab();

  @override
  State<_PetTab> createState() => _PetTabState();
}

class _PetTabState extends State<_PetTab> {
  late final PetChecks _checks = PetChecks(ServicesScope.of(context).prefs);
  final TextEditingController _pet = TextEditingController();
  final TextEditingController _carrier = TextEditingController(text: '2');
  Set<PetCheck>? _done;

  @override
  void dispose() {
    _pet.dispose();
    _carrier.dispose();
    super.dispose();
  }

  /// Lee un número escrito con coma o con punto ("6,5" o "6.5").
  static double? _kg(String text) =>
      double.tryParse(text.trim().replaceAll(',', '.'));

  Future<void> _toggle(PetCheck check) async {
    final bool ready = !(_done ?? <PetCheck>{}).contains(check);
    await _checks.set(check, ready: ready);
    if (mounted) setState(() => _done = _checks.done());
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    final TextTheme text = Theme.of(context).textTheme;
    final Set<PetCheck> done = _done ??= _checks.done();
    final double? petKg = _kg(_pet.text);
    final double carrierKg = _kg(_carrier.text) ?? 0;
    final PetPlace? place = petKg == null || petKg <= 0
        ? null
        : petPlace(petKg: petKg, carrierKg: carrierKg);
    final int max = cabinMaxKg.round();
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
      children: <Widget>[
        Text(
          t.twSubtitle,
          style: text.bodyMedium?.copyWith(color: NomadColors.textMuted),
        ),
        const SizedBox(height: 16),
        Row(
          children: <Widget>[
            Expanded(
              child: _KgField(
                controller: _pet,
                label: t.twPetWeight,
                onChanged: () => setState(() {}),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _KgField(
                controller: _carrier,
                label: t.twCarrierWeight,
                onChanged: () => setState(() {}),
              ),
            ),
          ],
        ),
        if (place != null) ...<Widget>[
          const SizedBox(height: 16),
          _Verdict(
            color: place == PetPlace.cabin
                ? NomadColors.mint
                : NomadColors.money,
            icon: place == PetPlace.cabin
                ? Icons.airline_seat_recline_normal_rounded
                : Icons.luggage_rounded,
            title: place == PetPlace.cabin ? t.twCabin : t.twHold,
            body: place == PetPlace.cabin
                ? t.twCabinWhy(max)
                : t.twHoldWhy(max),
          ),
        ],
        const SizedBox(height: 24),
        Text(t.twEuTitle, style: text.labelLarge),
        const SizedBox(height: 8),
        for (final PetCheck c in PetCheck.values)
          Card(
            child: CheckboxListTile(
              value: done.contains(c),
              onChanged: (_) => unawaited(_toggle(c)),
              controlAffinity: ListTileControlAffinity.leading,
              title: Text(switch (c) {
                PetCheck.microchip => t.twChip,
                PetCheck.rabies => t.twRabies,
                PetCheck.passport => t.twPassport,
              }),
              subtitle: Text(switch (c) {
                PetCheck.microchip => t.twChipWhy,
                PetCheck.rabies => t.twRabiesWhy(rabiesWaitDays),
                PetCheck.passport => t.twPassportWhy,
              }),
            ),
          ),
        const SizedBox(height: 12),
        _Tip(icon: Icons.public_rounded, text: t.twOutsideEu),
        _Tip(icon: Icons.hotel_rounded, text: t.twPetHotels),
        const SizedBox(height: 12),
        Text(
          t.twPetDisclaimer,
          style: text.bodySmall?.copyWith(color: NomadColors.textMuted),
        ),
      ],
    );
  }
}

class _KgField extends StatelessWidget {
  const _KgField({
    required this.controller,
    required this.label,
    required this.onChanged,
  });

  final TextEditingController controller;
  final String label;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) => TextField(
    controller: controller,
    keyboardType: const TextInputType.numberWithOptions(decimal: true),
    inputFormatters: <TextInputFormatter>[
      FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]')),
    ],
    onChanged: (_) => onChanged(),
    decoration: InputDecoration(labelText: label),
  );
}

// --- Embarazo ----------------------------------------------------------------

class _PregnancyTab extends StatefulWidget {
  const _PregnancyTab();

  @override
  State<_PregnancyTab> createState() => _PregnancyTabState();
}

class _PregnancyTabState extends State<_PregnancyTab> {
  int _weeks = 20;
  bool _twins = false;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    final TextTheme text = Theme.of(context).textTheme;
    final int noFly = noFlyFromWeek(twins: _twins);
    final PregnancyVerdict v = pregnancyVerdict(_weeks, twins: _twins);
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
      children: <Widget>[
        Text(t.twWeeksQuestion, style: text.titleMedium),
        const SizedBox(height: 8),
        Text(
          t.twWeeks(_weeks),
          style: text.headlineMedium,
          textAlign: TextAlign.center,
        ),
        Slider(
          value: _weeks.toDouble(),
          max: 42,
          divisions: 42,
          label: t.twWeeks(_weeks),
          onChanged: (double w) => setState(() => _weeks = w.round()),
        ),
        SwitchListTile(
          value: _twins,
          onChanged: (bool v) => setState(() => _twins = v),
          title: Text(t.twTwins),
          contentPadding: EdgeInsets.zero,
        ),
        const SizedBox(height: 8),
        switch (v) {
          PregnancyVerdict.fly => _Verdict(
            color: NomadColors.mint,
            icon: Icons.check_circle_rounded,
            title: t.twVerdictFly,
            body: t.twVerdictFlyWhy(certificateFromWeek),
          ),
          PregnancyVerdict.certificate => _Verdict(
            color: NomadColors.money,
            icon: Icons.description_rounded,
            title: t.twVerdictCert,
            body: t.twVerdictCertWhy(certificateFromWeek, noFly),
          ),
          PregnancyVerdict.dontFly => _Verdict(
            color: NomadColors.safety,
            icon: Icons.do_not_disturb_on_rounded,
            title: t.twVerdictNo,
            body: t.twVerdictNoWhy(noFly),
          ),
        },
        const SizedBox(height: 16),
        _Tip(icon: Icons.event_seat_rounded, text: t.twTipAisle),
        _Tip(icon: Icons.health_and_safety_rounded, text: t.twTipInsurance),
        _Tip(icon: Icons.local_hospital_rounded, text: t.twTipHospital),
        const SizedBox(height: 12),
        Text(
          t.twDisclaimer,
          style: text.bodySmall?.copyWith(color: NomadColors.textMuted),
        ),
      ],
    );
  }
}

// --- Piezas comunes ------------------------------------------------------------

/// La tarjeta de colores con la respuesta ("puede ir en cabina", "mejor no
/// volar"...).
class _Verdict extends StatelessWidget {
  const _Verdict({
    required this.color,
    required this.icon,
    required this.title,
    required this.body,
  });

  final Color color;
  final IconData icon;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.12),
      borderRadius: BorderRadius.circular(20),
      border: Border.all(color: color),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Icon(icon, color: color),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                title,
                style: Theme.of(context).textTheme.titleMedium
                    ?.copyWith(color: color),
              ),
              const SizedBox(height: 4),
              Text(body),
            ],
          ),
        ),
      ],
    ),
  );
}

class _Tip extends StatelessWidget {
  const _Tip({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Icon(icon, size: 20, color: NomadColors.textMuted),
        const SizedBox(width: 12),
        Expanded(child: Text(text)),
      ],
    ),
  );
}
