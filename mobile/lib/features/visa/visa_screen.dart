// Visado (maqueta "Visado"): la maqueta tal cual (assets/visa/visado.html)
// con lo que te piden para entrar en otro país con TU pasaporte y, si se
// pide por Internet (ESTA, eTA, e-Visa...), los tres pasos para pedirlo con
// los datos de tu pasaporte.
//
// Cómo es gratis y seguro a la vez:
//   - La tabla "pasaporte × país" va dentro de la app (visa_data.dart).
//   - Los datos del pasaporte salen de la foto que ya tienes en la Bóveda
//     (zona MRZ, mrz.dart), se leen en el móvil y solo viven en memoria.
//     (La maqueta leía el chip NFC; la foto da los mismos datos sin pedir
//     permisos nuevos. Si no se puede leer, Flyra lo dice.)
//   - No mandamos nada a ninguna web: tocas cada dato para copiarlo y lo
//     pegas en la web OFICIAL (nunca intermediarios que cobran el doble).
import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../core/router.dart';
import '../../core/services.dart';
import '../../core/settings.dart';
import '../../l10n/generated/app_localizations.dart';
import '../easy/easy_mode.dart';
import '../trip/trip_check.dart' show entryPermits, passportMarginMonths;
import '../passport/passport.dart' show flagOf;
import '../route/flight3d.dart' show CountryCodes;
import '../route/world_data.dart';
import '../vault/vault.dart';
import '../vault/vault_store.dart';
import '../route/web_scene.dart';
import 'mrz.dart';
import 'visa_data.dart';
import 'visa_page.dart';

class VisaScreen extends StatefulWidget {
  const VisaScreen({super.key, this.to});

  /// País de destino ("US"); si no, el de tu próximo vuelo.
  final String? to;

  /// La última conexión con la página (para las pruebas).
  static WebSceneBridge? lastBridge;

  @override
  State<VisaScreen> createState() => _VisaScreenState();
}

/// En qué paso de la solicitud estás (las tres rayitas de arriba).
enum _Step { passport, review, send }

/// Un dato de la lista de "Revisar": qué es, lo que pone (null = lo
/// escribes tú en la web oficial) y lo que se copia.
typedef _Field = ({String label, String? value, String? copy, bool warn});

class _VisaScreenState extends State<VisaScreen> {
  late final AppServices _services = ServicesScope.of(context);
  final WebSceneBridge _bridge = VisaScreen.lastBridge = WebSceneBridge();

  // La página se lee una vez y se guarda (como String, no como Future).
  static String? _pageCache;
  String? _html;
  String? _sent;

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
    WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_open()));
  }

  @override
  void dispose() {
    _wipeClipboard?.cancel();
    super.dispose();
  }

  Future<void> _open() async {
    try {
      _pageCache ??= await rootBundle.loadString(visaPage, cache: false);
    } on Object {
      return;
    }
    if (mounted) setState(() {});
    await _load();
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
      '${flagOf(code)} ${_names?.name(code, _lang) ?? code}';

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
    setState(() => _noMrz = false);
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

  EntryRequirement? get _need {
    final VisaTable? table = _table;
    final String? passport = _passport;
    final String? to = _to;
    if (table == null || passport == null || to == null || passport == to) {
      return null;
    }
    return table.lookup(passport, to);
  }

  /// Los datos de "Revisar": los del pasaporte (si se leyó) y los tuyos.
  List<_Field> _fields(AppLocalizations t) {
    final MrzData? m = _mrz;
    String day(DateTime d) =>
        DateFormat.yMMMd(Localizations.localeOf(context).toLanguageTag())
            .format(d);
    String iso(DateTime d) => DateFormat('yyyy-MM-dd').format(d);
    final bool shortValidity =
        m != null &&
        m.expiry.isBefore(
          DateTime.now().add(const Duration(days: 30 * passportMarginMonths)),
        );
    _Field f(String label, String? v, {String? copy, bool warn = false}) =>
        (label: label, value: v, copy: copy ?? v, warn: warn);
    return <_Field>[
      if (m != null) ...<_Field>[
        f(t.visaFieldSurname, m.surname),
        f(t.visaFieldName, m.givenNames),
        f(t.visaFieldNumber, m.number),
        f(t.visaFieldBirth, day(m.birth), copy: iso(m.birth)),
        f(
          t.visaFieldNationality,
          _names?.name(_passport ?? m.nationality, _lang) ?? m.nationality,
        ),
        f(
          t.visaFieldExpiry,
          day(m.expiry),
          copy: iso(m.expiry),
          warn: shortValidity,
        ),
      ],
      f(t.visaFieldAddress, null),
      f(t.visaFieldEmergency, null),
      f(t.visaFieldJob, null),
    ];
  }

  void _onMessage(String m) {
    final int i = m.indexOf(':');
    final String what = i < 0 ? m : m.substring(0, i);
    final String arg = i < 0 ? '' : m.substring(i + 1);
    switch (what) {
      case 'back':
        if (context.canPop()) context.pop();
      case 'from':
        unawaited(_pick(passport: true));
      case 'to':
        unawaited(_pick(passport: false));
      case 'read':
        if (!_reading) unawaited(_readPassport());
      case 'manual':
        setState(() => (_step = _Step.review, _noMrz = false));
      case 'copy':
        final List<_Field> all = _fields(AppLocalizations.of(context));
        final int n = int.tryParse(arg) ?? -1;
        if (n >= 0 && n < all.length) {
          if (all[n].copy case final String v) unawaited(_copy(v));
        }
      case 'next':
        setState(() => _step = _Step.send);
      case 'official':
        final String? url = entryPermits[_to]?.$2;
        if (url != null) unawaited(_services.openLink(Uri.parse(url)));
      case 'vault':
        setState(() => _noMrz = false);
        unawaited(context.push(Routes.vault));
      case 'flyHide':
        setState(() => _noMrz = false);
    }
  }

  Map<String, Object?> _data(AppLocalizations t) {
    final String? passport = _passport;
    final String? to = _to;
    final EntryRequirement? need = _need;
    final (String, String)? official = to == null ? null : entryPermits[to];
    final String scheme = official?.$1 ?? t.visaGenericScheme;
    final bool apply =
        need != null && (need.applyOnline || need.rule == EntryRule.embassy);
    final MrzData? m = _mrz;
    final bool shortValidity = _fields(t).any((_Field f) => f.warn);

    String? note;
    if (_failed) {
      note = t.visaNoData;
    } else if (_table == null) {
      note = null;
    } else if (passport != null && passport == to) {
      note = t.visaSameCountry;
    } else if (passport == null || to == null) {
      note = t.visaSubtitle;
    }

    Map<String, Object?>? verdict;
    if (need != null) {
      final (String tone, String h, String p) = switch (need.rule) {
        EntryRule.free => ('ok', t.visaFree, t.visaFreeMore),
        EntryRule.onArrival => ('ok', t.visaOnArrival, t.visaOnArrivalMore),
        EntryRule.eta => (
          'info',
          official == null ? t.visaEta : t.visaEtaNamed(official.$1),
          t.visaEtaMore,
        ),
        EntryRule.eVisa => ('info', t.visaEVisa, t.visaEVisaMore),
        EntryRule.embassy => ('warn', t.visaEmbassy, t.visaEmbassyMore),
        EntryRule.refused => ('bad', t.visaRefused, t.visaRefusedMore),
        EntryRule.unknown => ('muted', t.visaUnknown, t.visaUnknownMore),
      };
      verdict = <String, Object?>{
        'tone': tone,
        'h': h,
        'days': need.days == null ? '' : t.visaDays(need.days!),
        'p': p,
        'source': t.visaSource(_table!.updated),
      };
    }

    return <String, Object?>{
      't': <String, Object?>{
        'back': MaterialLocalizations.of(context).backButtonTooltip,
        'steps': <String>[t.visaStepPassport, t.visaStepReview, t.visaStepSend],
        'fromH': t.visaPassport.toUpperCase(),
        'toH': t.visaDestination.toUpperCase(),
        'readH': t.visaReadTitle,
        'readP': t.visaReadBody,
        'read': t.visaRead,
        'reading': 'Leyendo tu pasaporte…',
        'manual': t.visaManual,
        'allGood': t.visaAllGood,
        'readyH': t.visaReadyTitle,
        'tipWait': t.visaTipWait,
        'tipSave': t.visaTipSave,
        'tipOfficial': t.visaTipOfficial,
        'official': t.visaOpenOfficial,
        'save': t.visaSaveApproval,
        'copy': t.visaCopy,
      },
      'title': apply ? t.visaApplyTitle(scheme) : t.visaTitle,
      'sub': to == null
          ? t.visaCheck
          : apply
          ? '${_names?.name(to, _lang) ?? to} · lo rellenamos con tu Bóveda'
          : t.visaCheck,
      'fromTxt': passport == null ? t.visaPickCountry : _country(passport),
      'toTxt': to == null ? t.visaPickCountry : _country(to),
      'verdict': verdict,
      'note': note ?? '',
      'apply': apply,
      'step': _step.index,
      'reading': _reading,
      'fields': <Object?>[
        for (final _Field f in _fields(t))
          <String, Object?>{
            'k': f.label,
            'v': f.value,
            'from': f.value == null ? t.visaYours : t.visaFromPassport,
            'src': f.value == null ? 'you' : 'pass',
            'warn': f.warn,
          },
      ],
      'youAnswer': <String>[
        if (shortValidity && m != null)
          t.visaExpiresSoon(
            DateFormat.yMMMd(Localizations.localeOf(context).toLanguageTag())
                .format(m.expiry),
          ),
        t.visaYouAnswer,
      ].join(' '),
      'readyP': official == null ? t.visaNoOfficial : t.visaReadyBody(scheme),
      'hasOfficial': official != null,
      'fly': _noMrz
          ? <String, Object?>{
              'title': 'No consigo leer tu pasaporte',
              'text': t.visaNoPassport,
              'retry': t.guideRetry,
              'alt': t.visaAddToVault,
            }
          : null,
    };
  }

  @override
  Widget build(BuildContext context) {
    final String? page = _pageCache;
    if (page == null) {
      return const Scaffold(
        backgroundColor: Color(0xFF0B1217),
        body: SizedBox.expand(),
      );
    }
    final Map<String, Object?> data = _data(AppLocalizations.of(context));
    final String push = visaPushScript(data);
    if (_html == null) {
      _html = visaPageWith(page, data);
      _sent = push;
    } else if (push != _sent) {
      _sent = push;
      unawaited(_bridge.run(push));
    }
    final String html = _html!;
    final AppServices services = ServicesScope.of(context);
    return Scaffold(
      backgroundColor: const Color(0xFF0B1217),
      body: SafeArea(
        bottom: false,
        child:
            services.webScene?.call(html, _onMessage) ??
            WebScene(html: html, onMessage: _onMessage, bridge: _bridge),
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
