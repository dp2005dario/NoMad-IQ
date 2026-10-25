// Visado (maqueta "Pedir el ESTA"): qué te piden para entrar en otro país
// con TU pasaporte y, si se pide por Internet (ESTA, eTA, e-Visa...), te
// ayudamos a rellenarlo con los datos de tu pasaporte.
//
// Cómo es gratis y seguro a la vez:
//   - La tabla "pasaporte × país" va dentro de la app (visa_data.dart).
//   - Los datos del pasaporte salen de la foto que ya tienes en la Bóveda
//     (zona MRZ, mrz.dart), se leen en el móvil y solo viven en memoria.
//   - No mandamos nada a ninguna web: tú copias cada dato y lo pegas en la
//     web OFICIAL (nunca intermediarios que cobran el doble). La maqueta
//     soñaba con "rellenarlo solo", pero ninguna web oficial lo permite sin
//     meter tus datos en un servidor ajeno: así es más honrado.
//   - La maqueta también leía el chip NFC del pasaporte; la foto de la
//     Bóveda da los mismos datos sin pedir permisos nuevos.
import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../core/router.dart';
import '../../core/services.dart';
import '../../core/settings.dart';
import '../../core/theme.dart';
import '../../l10n/generated/app_localizations.dart';
import '../easy/easy_mode.dart';
import '../papers/trip_check.dart' show entryPermits, passportMarginMonths;
import '../passport/passport.dart' show flagOf;
import '../route/flight3d.dart' show CountryCodes;
import '../route/world_data.dart';
import '../vault/vault.dart';
import '../vault/vault_store.dart';
import 'mrz.dart';
import 'visa_data.dart';

class VisaScreen extends StatefulWidget {
  const VisaScreen({super.key, this.to});

  /// País de destino ("US"); si no, el de tu próximo vuelo.
  final String? to;

  @override
  State<VisaScreen> createState() => _VisaScreenState();
}

/// En qué paso de la solicitud estás (las tres rayitas de arriba).
enum _Step { passport, review, send }

class _VisaScreenState extends State<VisaScreen> {
  late final AppServices _services = ServicesScope.of(context);

  VisaTable? _table;
  CountryNames? _names;
  bool _failed = false;

  String? _passport;
  String? _to;

  _Step _step = _Step.passport;
  MrzData? _mrz;
  bool _noMrz = false;
  bool _reading = false;
  Timer? _wipeClipboard;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _wipeClipboard?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final VisaData data = await _services.loadVisaData();
      final VisaTable table = data.table;
      final CountryNames names = data.names;
      final String? to = widget.to?.toUpperCase() ?? await _tripCountry();
      if (!mounted) return;
      final String? saved = _services.prefs.readData(LocalData.visaPassport);
      final String? phone = ui.PlatformDispatcher.instance.locale.countryCode;
      setState(() {
        _table = table;
        _names = names;
        _passport = <String?>[saved, phone]
            .firstWhere(
              (String? c) => c != null && names.codes.contains(c.toUpperCase()),
              orElse: () => null,
            )
            ?.toUpperCase();
        _to = to != null && names.codes.contains(to) ? to : null;
      });
    } on Object {
      if (mounted) setState(() => _failed = true);
    }
  }

  /// El país del destino de tu próximo vuelo (el de Modo fácil / Widgets).
  Future<String?> _tripCountry() async {
    final String? iata = loadEasyTrip(_services.prefs).to;
    if (iata == null) return null;
    try {
      final Airport? a = (await _services.loadAirports())[iata];
      if (a == null) return null;
      return (await CountryCodes.load())[a.country];
    } on Object {
      return null;
    }
  }

  String get _lang => Localizations.localeOf(context).languageCode;

  String _country(String code) =>
      '${flagOf(code)}  ${_names?.name(code, _lang) ?? code}';

  Future<void> _pick({required bool passport}) async {
    final CountryNames? names = _names;
    if (names == null) return;
    final String? code = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      useRootNavigator: true,
      builder: (BuildContext context) =>
          _CountryPicker(names: names, language: _lang),
    );
    if (code == null || !mounted) return;
    setState(() {
      if (passport) {
        _passport = code;
        _mrz = null;
      } else {
        _to = code;
      }
      _step = _Step.passport;
    });
    if (passport) {
      await _services.prefs.writeData(LocalData.visaPassport, code);
    }
  }

  /// Abre la Bóveda y busca la MRZ en tus pasaportes (el más nuevo primero).
  Future<void> _readPassport() async {
    final AppLocalizations t = AppLocalizations.of(context);
    final Vault vault = _services.vault;
    if (!vault.isOpen) {
      final UnlockResult r = await vault.open(t.vaultUnlockReason);
      if (r != UnlockResult.ok || !mounted) return;
    }
    setState(() => _reading = true);
    MrzData? found;
    final List<VaultDoc> passports =
        vault.docs.where((VaultDoc d) => d.kind == DocKind.passport).toList()
          ..sort((VaultDoc a, VaultDoc b) => b.added.compareTo(a.added));
    for (final VaultDoc d in passports) {
      try {
        found = parseMrz(await vault.text(d.id));
      } on Object {
        found = null;
      }
      if (found != null) break;
    }
    if (!mounted) return;
    final String? country = found == null
        ? null
        : _names?.fromIso3(found.nationality);
    setState(() {
      _reading = false;
      _mrz = found;
      _noMrz = found == null;
      if (found != null) {
        _step = _Step.review;
        if (country != null) _passport = country;
      }
    });
    if (country != null) {
      await _services.prefs.writeData(LocalData.visaPassport, country);
    }
  }

  /// Copia un dato y lo borra del portapapeles al minuto (otras apps
  /// pueden leer el portapapeles: mejor que no se quede ahí tu pasaporte).
  Future<void> _copy(String value) async {
    final AppLocalizations t = AppLocalizations.of(context);
    await Clipboard.setData(ClipboardData(text: value));
    _wipeClipboard?.cancel();
    _wipeClipboard = Timer(const Duration(minutes: 1), () {
      unawaited(Clipboard.setData(const ClipboardData(text: '')));
    });
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(t.visaCopied)));
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    final TextTheme text = Theme.of(context).textTheme;
    final VisaTable? table = _table;
    final String? passport = _passport;
    final String? to = _to;
    final EntryRequirement? need =
        table == null || passport == null || to == null
        ? null
        : passport == to
        ? null
        : table.lookup(passport, to);

    return Scaffold(
      appBar: AppBar(title: Text(t.visaTitle)),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
        children: <Widget>[
          Text(
            t.visaSubtitle,
            style: text.bodyMedium?.copyWith(color: NomadColors.textMuted),
          ),
          const SizedBox(height: 12),
          if (_failed)
            Text(t.visaNoData)
          else if (table == null)
            const Center(child: CircularProgressIndicator())
          else ...<Widget>[
            _CountryField(
              label: t.visaPassport,
              value: passport == null ? null : _country(passport),
              hint: t.visaPickCountry,
              onTap: () => _pick(passport: true),
            ),
            const SizedBox(height: 8),
            _CountryField(
              label: t.visaDestination,
              value: to == null ? null : _country(to),
              hint: t.visaPickCountry,
              onTap: () => _pick(passport: false),
            ),
            const SizedBox(height: 16),
            if (passport != null && passport == to)
              Text(t.visaSameCountry, style: text.titleMedium)
            else if (need != null) ...<Widget>[
              _Verdict(need: need, scheme: entryPermits[to]?.$1),
              const SizedBox(height: 8),
              Text(
                t.visaSource(table.updated),
                style: text.bodySmall?.copyWith(color: NomadColors.textMuted),
              ),
              const SizedBox(height: 16),
              if (need.applyOnline || need.rule == EntryRule.embassy)
                _apply(t, text, to!, need),
            ],
          ],
        ],
      ),
    );
  }

  /// Los tres pasos: pasaporte → revisar → enviar.
  Widget _apply(
    AppLocalizations t,
    TextTheme text,
    String to,
    EntryRequirement need,
  ) {
    final (String, String)? official = entryPermits[to];
    final String scheme = official?.$1 ?? t.visaGenericScheme;
    final List<String> labels = <String>[
      t.visaStepPassport,
      t.visaStepReview,
      t.visaStepSend,
    ];
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text(t.visaApplyTitle(scheme), style: text.titleMedium),
            const SizedBox(height: 12),
            Row(
              children: <Widget>[
                for (int i = 0; i < labels.length; i++) ...<Widget>[
                  if (i > 0) const SizedBox(width: 6),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Container(
                          height: 6,
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(3),
                            color: i <= _step.index
                                ? NomadColors.flights
                                : NomadColors.outline,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          labels[i],
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w800,
                            color: i <= _step.index
                                ? null
                                : NomadColors.textMuted,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 16),
            ...switch (_step) {
              _Step.passport => _passportStep(t, text),
              _Step.review => _reviewStep(t, text),
              _Step.send => _sendStep(t, text, scheme, official?.$2),
            },
          ],
        ),
      ),
    );
  }

  List<Widget> _passportStep(AppLocalizations t, TextTheme text) => <Widget>[
    Text(t.visaReadTitle, style: text.titleSmall),
    const SizedBox(height: 4),
    Text(t.visaReadBody),
    const SizedBox(height: 12),
    if (_noMrz) ...<Widget>[
      Text(t.visaNoPassport, style: const TextStyle(color: NomadColors.money)),
      TextButton.icon(
        icon: const Icon(Icons.add_a_photo_rounded),
        label: Text(t.visaAddToVault),
        onPressed: () => context.push(Routes.vault),
      ),
    ],
    FilledButton.icon(
      icon: _reading
          ? const SizedBox.square(
              dimension: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(Icons.fingerprint_rounded),
      label: Text(t.visaRead),
      onPressed: _reading ? null : _readPassport,
    ),
    TextButton(
      onPressed: () => setState(() => _step = _Step.review),
      child: Text(t.visaManual),
    ),
  ];

  List<Widget> _reviewStep(AppLocalizations t, TextTheme text) {
    final MrzData? m = _mrz;
    String day(DateTime d) =>
        DateFormat.yMMMd(Localizations.localeOf(context).toLanguageTag())
            .format(d);
    final bool shortValidity =
        m != null &&
        m.expiry.isBefore(
          DateTime.now().add(const Duration(days: 30 * passportMarginMonths)),
        );
    return <Widget>[
      if (m != null) ...<Widget>[
        _Field(t.visaFieldSurname, m.surname, t.visaFromPassport, _copy),
        _Field(t.visaFieldName, m.givenNames, t.visaFromPassport, _copy),
        _Field(t.visaFieldNumber, m.number, t.visaFromPassport, _copy),
        _Field(
          t.visaFieldBirth,
          day(m.birth),
          t.visaFromPassport,
          _copy,
          copyValue: DateFormat('yyyy-MM-dd').format(m.birth),
        ),
        _Field(
          t.visaFieldNationality,
          _names?.name(_passport ?? m.nationality, _lang) ?? m.nationality,
          t.visaFromPassport,
          _copy,
        ),
        _Field(
          t.visaFieldExpiry,
          day(m.expiry),
          t.visaFromPassport,
          _copy,
          copyValue: DateFormat('yyyy-MM-dd').format(m.expiry),
        ),
        if (shortValidity)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              t.visaExpiresSoon(day(m.expiry)),
              style: const TextStyle(color: NomadColors.money),
            ),
          ),
      ],
      _Field(t.visaFieldAddress, null, t.visaYours, null),
      _Field(t.visaFieldEmergency, null, t.visaYours, null),
      _Field(t.visaFieldJob, null, t.visaYours, null),
      const SizedBox(height: 8),
      Text(t.visaYouAnswer, style: text.bodySmall),
      const SizedBox(height: 12),
      FilledButton(
        onPressed: () => setState(() => _step = _Step.send),
        child: Text(t.visaAllGood),
      ),
    ];
  }

  List<Widget> _sendStep(
    AppLocalizations t,
    TextTheme text,
    String scheme,
    String? url,
  ) => <Widget>[
    Text(t.visaReadyTitle, style: text.titleSmall),
    const SizedBox(height: 4),
    Text(url == null ? t.visaNoOfficial : t.visaReadyBody(scheme)),
    const SizedBox(height: 8),
    for (final (IconData icon, String line) in <(IconData, String)>[
      (Icons.gpp_good_rounded, t.visaTipOfficial),
      (Icons.schedule_rounded, t.visaTipWait),
      (Icons.lock_rounded, t.visaTipSave),
    ])
      ListTile(
        contentPadding: EdgeInsets.zero,
        dense: true,
        leading: Icon(icon, color: NomadColors.flights),
        title: Text(line),
      ),
    if (url != null)
      FilledButton.icon(
        icon: const Icon(Icons.open_in_new_rounded),
        label: Text(t.visaOpenOfficial),
        onPressed: () => _services.openLink(Uri.parse(url)),
      ),
    TextButton.icon(
      icon: const Icon(Icons.lock_rounded),
      label: Text(t.visaSaveApproval),
      onPressed: () => context.push(Routes.vault),
    ),
  ];
}

/// El veredicto grande: "No necesitas visado · hasta 90 días".
class _Verdict extends StatelessWidget {
  const _Verdict({required this.need, this.scheme});

  final EntryRequirement need;
  final String? scheme;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    final (
      Color color,
      IconData icon,
      String title,
      String more,
    ) = switch (need.rule) {
      EntryRule.free => (
        NomadColors.mint,
        Icons.check_circle_rounded,
        t.visaFree,
        t.visaFreeMore,
      ),
      EntryRule.onArrival => (
        NomadColors.mint,
        Icons.flight_land_rounded,
        t.visaOnArrival,
        t.visaOnArrivalMore,
      ),
      EntryRule.eta => (
        NomadColors.flights,
        Icons.assignment_rounded,
        scheme == null ? t.visaEta : t.visaEtaNamed(scheme!),
        t.visaEtaMore,
      ),
      EntryRule.eVisa => (
        NomadColors.flights,
        Icons.assignment_rounded,
        t.visaEVisa,
        t.visaEVisaMore,
      ),
      EntryRule.embassy => (
        NomadColors.money,
        Icons.account_balance_rounded,
        t.visaEmbassy,
        t.visaEmbassyMore,
      ),
      EntryRule.refused => (
        NomadColors.safety,
        Icons.block_rounded,
        t.visaRefused,
        t.visaRefusedMore,
      ),
      EntryRule.unknown => (
        NomadColors.textMuted,
        Icons.help_outline_rounded,
        t.visaUnknown,
        t.visaUnknownMore,
      ),
    };
    final int? days = need.days;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        color: color.withValues(alpha: 0.12),
        border: Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(icon, color: color, size: 32),
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
                if (days != null)
                  Text(
                    t.visaDays(days),
                    style: const TextStyle(fontWeight: FontWeight.w800),
                  ),
                const SizedBox(height: 4),
                Text(more),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _CountryField extends StatelessWidget {
  const _CountryField({
    required this.label,
    required this.value,
    required this.hint,
    required this.onTap,
  });

  final String label;
  final String? value;
  final String hint;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => InkWell(
    onTap: onTap,
    borderRadius: BorderRadius.circular(14),
    child: InputDecorator(
      decoration: InputDecoration(
        labelText: label,
        suffixIcon: const Icon(Icons.expand_more_rounded),
      ),
      child: Text(
        value ?? hint,
        style: value == null
            ? const TextStyle(color: NomadColors.textMuted)
            : null,
      ),
    ),
  );
}

/// Una fila de datos: "Nº DE PASAPORTE · •••• 4821 · [Pasaporte] [Copiar]".
class _Field extends StatelessWidget {
  const _Field(
    this.label,
    this.value,
    this.source,
    this.onCopy, {
    this.copyValue,
  });

  final String label;

  /// null = lo tienes que escribir tú en la web oficial.
  final String? value;
  final String source;
  final Future<void> Function(String)? onCopy;
  final String? copyValue;

  @override
  Widget build(BuildContext context) {
    final String? v = value;
    final bool mine = v == null;
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        color: NomadColors.surface,
        border: Border.all(color: NomadColors.outline),
      ),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  label,
                  style: const TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w800,
                    color: NomadColors.textMuted,
                  ),
                ),
                if (v != null) Text(v),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(11),
              color: mine ? NomadColors.money : NomadColors.flights,
            ),
            child: Text(
              source,
              style: const TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w800,
                color: NomadColors.background,
              ),
            ),
          ),
          if (v != null && onCopy != null)
            IconButton(
              tooltip: AppLocalizations.of(context).visaCopy,
              icon: const Icon(Icons.copy_rounded, size: 18),
              onPressed: () => onCopy!(copyValue ?? v),
            )
          else
            const SizedBox(width: 12),
        ],
      ),
    );
  }
}

/// Lista de países con buscador (en tu idioma).
class _CountryPicker extends StatefulWidget {
  const _CountryPicker({required this.names, required this.language});

  final CountryNames names;
  final String language;

  @override
  State<_CountryPicker> createState() => _CountryPickerState();
}

class _CountryPickerState extends State<_CountryPicker> {
  String _q = '';

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    final String q = _q.trim().toLowerCase();
    final List<(String, String)> all = <(String, String)>[
      for (final String c in widget.names.codes)
        (c, widget.names.name(c, widget.language)),
    ]..sort(((String, String) a, (String, String) b) => a.$2.compareTo(b.$2));
    final List<(String, String)> shown = q.isEmpty
        ? all
        : all
              .where(
                ((String, String) e) =>
                    e.$2.toLowerCase().contains(q) || e.$1.toLowerCase() == q,
              )
              .toList();
    return SafeArea(
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.8,
        child: Column(
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.all(16),
              child: TextField(
                autofocus: true,
                decoration: InputDecoration(
                  prefixIcon: const Icon(Icons.search_rounded),
                  hintText: t.visaSearch,
                ),
                onChanged: (String v) => setState(() => _q = v),
              ),
            ),
            Expanded(
              child: ListView.builder(
                itemCount: shown.length,
                itemBuilder: (BuildContext context, int i) => ListTile(
                  leading: Text(
                    flagOf(shown[i].$1),
                    style: const TextStyle(fontSize: 22),
                  ),
                  title: Text(shown[i].$2),
                  onTap: () => Navigator.of(context).pop(shown[i].$1),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
