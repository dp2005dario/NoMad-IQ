// "Mi pasaporte" de Inicio (maqueta "ECLIPTA Inicio").
//
// Una tarjeta con forma de pasaporte. Al principio todo pone "Sin añadir";
// al tocarla se abre el escáner en dos pasos:
//   Foto 1 de 2 · Pasaporte  → la página de datos (las 2 líneas <<< de abajo)
//   Foto 2 de 2 · DNI        → la cara de ATRÁS (las 3 líneas <<<)
// El móvil lee esas líneas SIN Internet (ML Kit, ver vault/doc_source.dart)
// y comprueba los "dígitos de control" (visa/mrz.dart): si no cuadran, no se
// rellena nada (mejor vacío que mal).
//
// Qué se guarda (solo en este móvil, LocalData.myDocs): nombre, apellidos,
// nacionalidad y fechas. De los números, solo las 3 últimas cifras
// ("••••••916"): el número entero no se guarda nunca. La foto de la tarjeta
// es tu foto de perfil (cámara o galería), no la del documento.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';

import '../../auth/session.dart';

import '../../core/services.dart';
import '../../core/settings.dart';
import '../../l10n/generated/app_localizations.dart';
import '../../widgets/user_avatar.dart' show isTrustedPhotoUrl;
import '../settings/profile_photo.dart';
import '../sos/sos_store.dart';
import '../vault/doc_source.dart';
import '../visa/mrz.dart';
import '../visa/visa_data.dart' show CountryNames;

/// Lo leído de UN documento (pasaporte o DNI), ya sin el número entero.
class ReadDoc {
  const ReadDoc({
    required this.surname,
    required this.given,
    required this.nationality,
    required this.numberTail,
    required this.birth,
    required this.expiry,
  });

  /// Quita el número entero: deja puntos y las 3 últimas cifras.
  factory ReadDoc.fromMrz(MrzData m) => ReadDoc(
    surname: m.surname,
    given: m.givenNames,
    nationality: m.nationality,
    numberTail: maskNumber(m.number),
    birth: m.birth,
    expiry: m.expiry,
  );

  final String surname;
  final String given;

  /// Código de 3 letras del documento ("ESP").
  final String nationality;

  /// "••••••916".
  final String numberTail;
  final DateTime birth;
  final DateTime expiry;

  Map<String, Object?> toJson() => <String, Object?>{
    's': surname,
    'g': given,
    'n': nationality,
    't': numberTail,
    'b': birth.toIso8601String(),
    'e': expiry.toIso8601String(),
  };

  static ReadDoc? parse(Object? j) {
    if (j is! Map<String, Object?>) return null;
    final DateTime? b = DateTime.tryParse('${j['b']}');
    final DateTime? e = DateTime.tryParse('${j['e']}');
    if (b == null || e == null) return null;
    return ReadDoc(
      surname: '${j['s'] ?? ''}',
      given: '${j['g'] ?? ''}',
      nationality: '${j['n'] ?? ''}',
      numberTail: '${j['t'] ?? ''}',
      birth: b,
      expiry: e,
    );
  }
}

/// "XDE482916" → "••••••916".
String maskNumber(String n) {
  if (n.length <= 3) return n;
  return '${'•' * (n.length - 3)}${n.substring(n.length - 3)}';
}

/// Tus dos documentos (cada uno puede faltar).
class MyDocs {
  const MyDocs({this.passport, this.id});

  final ReadDoc? passport;
  final ReadDoc? id;

  static MyDocs load(SettingsStore prefs) {
    final String? raw = prefs.readData(LocalData.myDocs);
    if (raw == null) return const MyDocs();
    try {
      final Object? j = jsonDecode(raw);
      if (j is! Map<String, Object?>) return const MyDocs();
      return MyDocs(passport: ReadDoc.parse(j['p']), id: ReadDoc.parse(j['i']));
    } on FormatException {
      return const MyDocs();
    }
  }

  Future<void> save(SettingsStore prefs) => prefs.writeData(
    LocalData.myDocs,
    jsonEncode(<String, Object?>{'p': passport?.toJson(), 'i': id?.toJson()}),
  );
}

/// "02 SEP 2031", como en el pasaporte.
String _day(DateTime d, String locale) {
  try {
    return DateFormat('dd MMM yyyy', locale).format(d).toUpperCase();
  } on Object {
    return DateFormat('dd MMM yyyy').format(d).toUpperCase();
  }
}

/// "ESP" → "España" (en tu idioma). Si aún no se ha cargado la lista de
/// países, se queda el código.
String countryOf(CountryNames? names, String iso3, String lang) {
  final String? two = names?.fromIso3(iso3);
  if (names == null || two == null) return iso3;
  return names.name(two, lang);
}

/// La tarjeta de Inicio.
class HomePassport extends StatefulWidget {
  const HomePassport({super.key});

  @override
  State<HomePassport> createState() => _HomePassportState();
}

class _HomePassportState extends State<HomePassport>
    with SingleTickerProviderStateMixin {
  // La tarjeta "flota" un poco (como en la maqueta). Unas vueltas y para.
  late final AnimationController _float = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2250),
  );
  CountryNames? _names;
  MyDocs? _docs;

  bool _loadingNames = false;

  /// La lista de países solo se carga cuando hay algo que enseñar.
  void _needNames() {
    if (_loadingNames) return;
    _loadingNames = true;
    unawaited(
      CountryNames.load().then((CountryNames n) {
        if (mounted) setState(() => _names = n);
      }, onError: (Object _) {}),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!MediaQuery.disableAnimationsOf(context) && !_float.isAnimating) {
      unawaited(_float.repeat(reverse: true, count: 4));
    }
  }

  @override
  void dispose() {
    _float.dispose();
    super.dispose();
  }

  Future<void> _scan() async {
    final AppServices services = ServicesScope.of(context);
    final MyDocs before = _docs ?? MyDocs.load(services.prefs);
    // En el Navigator de arriba del todo: así tapa también la barra de
    // abajo (si no, el botón de la cámara quedaría encima del escáner).
    final MyDocs? after = await Navigator.of(context, rootNavigator: true)
        .push<MyDocs>(
          MaterialPageRoute<MyDocs>(
            fullscreenDialog: true,
            builder: (_) => PassportScanScreen(start: before),
          ),
        );
    if (after == null || !mounted) return;
    await after.save(services.prefs);
    if (mounted) setState(() => _docs = after);
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    final AppServices services = ServicesScope.of(context);
    final String lang = Localizations.localeOf(context).languageCode;
    final MyDocs docs = _docs ??= MyDocs.load(services.prefs);
    final ReadDoc? p = docs.passport;
    final ReadDoc? d = docs.id;
    final ReadDoc? any = p ?? d;
    if (any != null) _needNames();
    final String? blood = MedicalCard.load(services.prefs).blood;

    final String cta = p != null && d != null
        ? t.homePassBoth
        : p != null
        ? t.homePassOnlyPass
        : d != null
        ? t.homePassOnlyId
        : t.homePassCta;
    final List<(String, String?)> fields = <(String, String?)>[
      (t.homePassSurname, any?.surname),
      (t.homePassName, any?.given),
      (
        t.homePassNationality,
        any == null ? null : countryOf(_names, any.nationality, lang),
      ),
      (t.sosBlood, blood),
      (t.homePassNumber, p?.numberTail),
      (t.homePassExpires, p == null ? null : _day(p.expiry, lang)),
      (t.homePassId, d?.numberTail),
      (t.homePassBirth, any == null ? null : _day(any.birth, lang)),
      (t.homePassIdValid, d == null ? null : _day(d.expiry, lang)),
    ];

    final Widget card = Semantics(
      button: true,
      label: t.homePassSemantics,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(24),
          onTap: _scan,
          child: Ink(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(24),
              gradient: const LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: <Color>[
                  Color(0xFF14313A),
                  Color(0xFF1B2447),
                  Color(0xFF2B2468),
                ],
                stops: <double>[0, 0.7, 1],
              ),
              border: Border.all(color: const Color(0xFF34476A)),
              boxShadow: const <BoxShadow>[
                BoxShadow(
                  color: Color(0xAA000000),
                  blurRadius: 30,
                  offset: Offset(0, 22),
                  spreadRadius: -14,
                ),
                BoxShadow(
                  color: Color(0x553DDC97),
                  blurRadius: 40,
                  spreadRadius: -10,
                ),
              ],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Text(
                  t.homePassHead.toUpperCase(),
                  style: const TextStyle(
                    color: Color(0xFF9FB2D6),
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.6,
                  ),
                ),
                const SizedBox(height: 14),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    // Tu foto (la misma que la de perfil). Tocar = cambiarla.
                    const _Photo(),
                    const SizedBox(width: 16),
                    Expanded(
                      child: _Fields(fields: fields, empty: t.homePassEmpty),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                Text(
                  p == null
                      ? t.homePassMrzEmpty
                      : 'P<${p.nationality.padRight(3, '<')}'
                            '${p.surname.replaceAll(' ', '<')}<<'
                            '${p.given.replaceAll(' ', '<')}'
                            '<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<',
                  maxLines: 1,
                  overflow: TextOverflow.clip,
                  softWrap: false,
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 10.5,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 1.4,
                    color: const Color(0xFF8FA3C8)
                        .withValues(alpha: p == null ? 0.6 : 1),
                  ),
                ),
                const SizedBox(height: 14),
                _Cta(text: cta, done: p != null || d != null),
              ],
            ),
          ),
        ),
      ),
    );

    return AnimatedBuilder(
      animation: _float,
      child: card,
      builder: (BuildContext context, Widget? child) {
        final double v = Curves.easeInOut.transform(_float.value);
        return Transform.translate(offset: Offset(0, -6 * v), child: child);
      },
    );
  }
}

class _Fields extends StatelessWidget {
  const _Fields({required this.fields, required this.empty});

  final List<(String, String?)> fields;
  final String empty;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints box) {
        final double w = (box.maxWidth - 10) / 2;
        return Wrap(
          spacing: 10,
          runSpacing: 8,
          children: <Widget>[
            for (final (String label, String? value) in fields)
              SizedBox(
                width: w,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      label,
                      style: const TextStyle(
                        color: Color(0xFF9FB2D6),
                        fontSize: 10.5,
                      ),
                    ),
                    Text(
                      (value == null || value.isEmpty) ? empty : value,
                      style: (value == null || value.isEmpty)
                          ? const TextStyle(
                              color: Color(0xCC7D8FB3),
                              fontStyle: FontStyle.italic,
                              fontSize: 13,
                            )
                          : const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w700,
                              fontSize: 13,
                            ),
                    ),
                  ],
                ),
              ),
          ],
        );
      },
    );
  }
}

/// La foto del pasaporte: TU foto de perfil (la que haces o eliges de la
/// galería, guardada solo en el móvil) o, si no hay, la de tu cuenta de
/// Google. Sin ninguna, un hueco "Añadir foto". Al tocarla se elige: hacer
/// una foto o sacarla de la galería (cambia también la de Ajustes).
class _Photo extends StatelessWidget {
  const _Photo();

  Future<void> _choose(BuildContext context) async {
    final ProfilePhotoController photo = ProfilePhotoController.instance;
    await showModalBottomSheet<void>(
      context: context,
      useRootNavigator: true,
      showDragHandle: true,
      builder: (BuildContext sheet) {
        final AppLocalizations t = AppLocalizations.of(sheet);
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              ListTile(
                leading: const Icon(Icons.photo_camera_rounded),
                title: Text(t.profilePhotoTake),
                onTap: () {
                  Navigator.pop(sheet);
                  unawaited(photo.pick(ImageSource.camera));
                },
              ),
              ListTile(
                leading: const Icon(Icons.photo_library_rounded),
                title: Text(t.profilePhotoGallery),
                onTap: () {
                  Navigator.pop(sheet);
                  unawaited(photo.pick(ImageSource.gallery));
                },
              ),
            ],
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    final String? google = SessionScope.read(context).user?.photoUrl;
    return Semantics(
      button: true,
      label: t.homePassPhoto,
      excludeSemantics: true,
      child: GestureDetector(
        onTap: () => _choose(context),
        child: ListenableBuilder(
          listenable: ProfilePhotoController.instance,
          builder: (BuildContext context, Widget? _) {
            final String? file =
                ProfilePhotoController.instance.choice.filePath;
            Widget? image;
            if (file != null) {
              image = Image.file(
                File(file),
                fit: BoxFit.cover,
                errorBuilder: (_, Object e, StackTrace? s) => _empty(t),
              );
            } else if (isTrustedPhotoUrl(google)) {
              image = Image.network(
                google!,
                fit: BoxFit.cover,
                errorBuilder: (_, Object e, StackTrace? s) => _empty(t),
              );
            }
            return Container(
              width: 84,
              height: 108,
              clipBehavior: Clip.antiAlias,
              decoration: BoxDecoration(
                color: const Color(0xFF26324F),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: const Color(0x30FFFFFF), width: 2),
              ),
              child: image ?? _empty(t),
            );
          },
        ),
      ),
    );
  }

  /// Sin foto: un hueco que invita a ponerla.
  Widget _empty(AppLocalizations t) => Column(
    mainAxisAlignment: MainAxisAlignment.center,
    children: <Widget>[
      const Icon(Icons.add_a_photo_rounded, size: 26, color: Color(0xFF8FF0C3)),
      const SizedBox(height: 6),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6),
        child: Text(
          t.homePassAddPhoto,
          textAlign: TextAlign.center,
          style: const TextStyle(
            color: Color(0xFF8FF0C3),
            fontSize: 11,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    ],
  );
}

/// La franja verde de abajo ("Toca para escanear pasaporte y DNI").
class _Cta extends StatelessWidget {
  const _Cta({required this.text, required this.done});

  final String text;
  final bool done;

  @override
  Widget build(BuildContext context) {
    const Color mint = Color(0xFF3DDC97);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: mint.withValues(alpha: done ? 0.2 : 0.13),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: mint),
      ),
      child: Row(
        children: <Widget>[
          Icon(
            done ? Icons.check_circle_rounded : Icons.document_scanner_rounded,
            size: 18,
            color: const Color(0xFF8FF0C3),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(
                color: Color(0xFF8FF0C3),
                fontWeight: FontWeight.w700,
                fontSize: 12.5,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// El escáner a pantalla completa: dos fotos y el resumen. Devuelve lo que
/// se haya leído (también si se cierra a medias).
class PassportScanScreen extends StatefulWidget {
  const PassportScanScreen({super.key, required this.start});

  final MyDocs start;

  @override
  State<PassportScanScreen> createState() => _PassportScanScreenState();
}

class _PassportScanScreenState extends State<PassportScanScreen> {
  // Si el pasaporte ya está y falta el DNI, se empieza por el DNI.
  late int _step = widget.start.passport != null && widget.start.id == null
      ? 1
      : 0;
  late ReadDoc? _passport = widget.start.passport;
  late ReadDoc? _id = widget.start.id;
  final List<int> _readNow = <int>[]; // qué pasos se han leído ahora
  bool _busy = false;
  bool _finished = false;
  String? _message;
  List<(String, String)> _just = const <(String, String)>[];
  Timer? _next;
  CountryNames? _names;

  @override
  void initState() {
    super.initState();
    // Para el nombre del país en lo leído ("España" y no "ESP").
    unawaited(
      CountryNames.load().then((CountryNames n) {
        if (mounted) setState(() => _names = n);
      }, onError: (Object _) {}),
    );
  }

  @override
  void dispose() {
    _next?.cancel();
    super.dispose();
  }

  MyDocs get _result => MyDocs(passport: _passport, id: _id);

  List<(String, String)> _rows(AppLocalizations t, int step, String lang) {
    final ReadDoc? r = step == 0 ? _passport : _id;
    if (r == null) return const <(String, String)>[];
    return step == 0
        ? <(String, String)>[
            (t.homePassNumber, r.numberTail),
            (t.homePassName, r.given),
            (t.homePassNationality, countryOf(_names, r.nationality, lang)),
            (t.homePassBirth, _day(r.birth, lang)),
            (t.homePassExpires, _day(r.expiry, lang)),
          ]
        : <(String, String)>[
            (t.homePassSurname, r.surname),
            (t.homePassName, r.given),
            (t.homePassId, r.numberTail),
            (t.homePassBirth, _day(r.birth, lang)),
            (t.homePassIdValid, _day(r.expiry, lang)),
          ];
  }

  Future<void> _capture(AppLocalizations t, String lang) async {
    if (_busy) return;
    final AppServices services = ServicesScope.of(context);
    setState(() {
      _busy = true;
      _message = null;
    });
    final PickedDoc? photo = await services.docSource.pick(DocOrigin.camera);
    if (!mounted) return;
    if (photo == null || photo.bytes.isEmpty) {
      setState(() => _busy = false);
      return;
    }
    final String name = _step == 0 ? t.scanPassportName : t.scanIdName;
    setState(() => _message = t.scanReading(name));
    List<String> text = const <String>[];
    try {
      text = await services.docReader.read(photo);
    } on Object {
      // Si el lector falla, se trata como "no se ha podido leer".
    }
    if (!mounted) return;
    final MrzData? m = _step == 0 ? parseMrz(text) : parseIdMrz(text);
    if (m == null) {
      setState(() {
        _busy = false;
        _message = t.scanFailed;
      });
      return;
    }
    setState(() {
      if (_step == 0) {
        _passport = ReadDoc.fromMrz(m);
      } else {
        _id = ReadDoc.fromMrz(m);
      }
      _readNow.add(_step);
      _just = _rows(t, _step, lang);
      _message = t.scanRead(name);
    });
    // Un momento para ver lo leído y se pasa al siguiente paso.
    _next = Timer(const Duration(milliseconds: 1300), _advance);
  }

  void _advance() {
    if (!mounted) return;
    setState(() {
      _busy = false;
      _just = const <(String, String)>[];
      _message = null;
      if (_step == 0) {
        _step = 1;
      } else {
        _finished = true;
      }
    });
  }

  void _skip() {
    if (_step == 0) {
      _advance();
    } else if (_readNow.isEmpty) {
      Navigator.of(context).pop(_result);
    } else {
      setState(() => _finished = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    final String lang = Localizations.localeOf(context).languageCode;
    const Color mint = Color(0xFF3DDC97);
    return PopScope<MyDocs>(
      canPop: false,
      onPopInvokedWithResult: (bool didPop, MyDocs? _) {
        if (!didPop) Navigator.of(context).pop(_result);
      },
      child: Scaffold(
        backgroundColor: const Color(0xFF04080B),
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 18),
            child: _finished
                ? _Summary(
                    title: t.scanDoneTitle,
                    done: t.scanDone,
                    rows: <(String, String)>[
                      for (final int s in <int>[0, 1])
                        if (_readNow.contains(s))
                          for (final (String k, String v) in _rows(t, s, lang))
                            (
                              '${s == 0 ? t.scanPassportName : t.scanIdName} · $k',
                              v,
                            ),
                    ],
                    onDone: () => Navigator.of(context).pop(_result),
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      Row(
                        children: <Widget>[
                          IconButton.outlined(
                            tooltip: t.scanClose,
                            onPressed: () => Navigator.of(context).pop(_result),
                            icon: const Icon(Icons.close_rounded),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              _step == 0 ? t.scanStep1 : t.scanStep2,
                              style: const TextStyle(
                                fontWeight: FontWeight.w800,
                                fontSize: 16,
                              ),
                            ),
                          ),
                          for (final int i in <int>[0, 1])
                            Container(
                              width: 22,
                              height: 4,
                              margin: const EdgeInsets.only(left: 6),
                              decoration: BoxDecoration(
                                color: i <= _step
                                    ? mint
                                    : const Color(0xFF2A3A40),
                                borderRadius: BorderRadius.circular(3),
                              ),
                            ),
                        ],
                      ),
                      const SizedBox(height: 14),
                      Expanded(
                        child: _Viewfinder(busy: _busy, rows: _just),
                      ),
                      const SizedBox(height: 14),
                      Text(
                        _message ?? (_step == 0 ? t.scanHint1 : t.scanHint2),
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: _message == t.scanFailed
                              ? const Color(0xFFFF8A65)
                              : const Color(0xFF9FB2C0),
                          fontSize: 13,
                        ),
                      ),
                      const SizedBox(height: 12),
                      Center(
                        child: Semantics(
                          button: true,
                          label: t.scanShutter,
                          child: GestureDetector(
                            onTap: _busy ? null : () => _capture(t, lang),
                            child: Opacity(
                              opacity: _busy ? 0.4 : 1,
                              child: Container(
                                width: 74,
                                height: 74,
                                padding: const EdgeInsets.all(6),
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  border: Border.all(
                                    color: Colors.white,
                                    width: 4,
                                  ),
                                ),
                                child: const DecoratedBox(
                                  decoration: BoxDecoration(
                                    color: Colors.white,
                                    shape: BoxShape.circle,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                      TextButton(
                        onPressed: _busy ? null : _skip,
                        child: Text(t.scanSkip),
                      ),
                    ],
                  ),
          ),
        ),
      ),
    );
  }
}

/// El "visor": fondo oscuro con el marco verde de las cuatro esquinas. La
/// foto la hace la cámara del móvil al pulsar el botón blanco.
class _Viewfinder extends StatelessWidget {
  const _Viewfinder({required this.busy, required this.rows});

  final bool busy;
  final List<(String, String)> rows;

  @override
  Widget build(BuildContext context) {
    const Color mint = Color(0xFF3DDC97);
    return ClipRRect(
      borderRadius: BorderRadius.circular(26),
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: const RadialGradient(
            center: Alignment(0, -0.2),
            radius: 0.9,
            colors: <Color>[Color(0xFF2A3A40), Color(0xFF0A1014)],
          ),
          border: Border.all(color: const Color(0xFF1E2A30)),
          borderRadius: BorderRadius.circular(26),
        ),
        child: Stack(
          fit: StackFit.expand,
          children: <Widget>[
            FractionallySizedBox(
              widthFactor: 0.84,
              heightFactor: 0.72,
              child: CustomPaint(painter: _Corners(mint)),
            ),
            if (busy && rows.isEmpty)
              const Center(child: CircularProgressIndicator(color: mint)),
            if (rows.isNotEmpty)
              Center(
                child: Padding(
                  padding: const EdgeInsets.all(28),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      for (final (String k, String v) in rows)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 3),
                          child: Row(
                            children: <Widget>[
                              Expanded(
                                child: Text(
                                  k,
                                  style: const TextStyle(
                                    color: Color(0xFF9FB2C0),
                                    fontSize: 12.5,
                                  ),
                                ),
                              ),
                              Text(
                                v,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              const SizedBox(width: 6),
                              const Icon(
                                Icons.check_rounded,
                                size: 16,
                                color: mint,
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Las cuatro esquinas verdes del marco.
class _Corners extends CustomPainter {
  const _Corners(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    const double l = 34;
    const double r = 14;
    final Paint p = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.round;
    final double w = size.width;
    final double h = size.height;
    final Path path = Path()
      // Arriba a la izquierda.
      ..moveTo(0, l)
      ..lineTo(0, r)
      ..arcToPoint(const Offset(r, 0), radius: const Radius.circular(r))
      ..lineTo(l, 0)
      // Arriba a la derecha.
      ..moveTo(w - l, 0)
      ..lineTo(w - r, 0)
      ..arcToPoint(Offset(w, r), radius: const Radius.circular(r))
      ..lineTo(w, l)
      // Abajo a la derecha.
      ..moveTo(w, h - l)
      ..lineTo(w, h - r)
      ..arcToPoint(Offset(w - r, h), radius: const Radius.circular(r))
      ..lineTo(w - l, h)
      // Abajo a la izquierda.
      ..moveTo(l, h)
      ..lineTo(r, h)
      ..arcToPoint(Offset(0, h - r), radius: const Radius.circular(r))
      ..lineTo(0, h - l);
    canvas.drawPath(path, p);
  }

  @override
  bool shouldRepaint(_Corners old) => old.color != color;
}

/// "Documentos añadidos" con todo lo leído y el botón Listo.
class _Summary extends StatelessWidget {
  const _Summary({
    required this.title,
    required this.done,
    required this.rows,
    required this.onDone,
  });

  final String title;
  final String done;
  final List<(String, String)> rows;
  final VoidCallback onDone;

  @override
  Widget build(BuildContext context) {
    const Color mint = Color(0xFF3DDC97);
    return ListView(
      children: <Widget>[
        const SizedBox(height: 24),
        Center(
          child: Container(
            width: 84,
            height: 84,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: mint.withValues(alpha: 0.13),
              border: Border.all(color: mint, width: 2),
            ),
            child: const Icon(Icons.check_rounded, size: 42, color: mint),
          ),
        ),
        const SizedBox(height: 14),
        Text(
          title,
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 14),
        for (final (String k, String v) in rows)
          Container(
            margin: const EdgeInsets.only(bottom: 8),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
            decoration: BoxDecoration(
              color: const Color(0xFF111A1F),
              border: Border.all(color: const Color(0xFF1E2A30)),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    k,
                    style: const TextStyle(
                      color: Color(0xFF9FB2C0),
                      fontSize: 13.5,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Flexible(
                  child: Text(
                    v,
                    textAlign: TextAlign.end,
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 13.5,
                    ),
                  ),
                ),
              ],
            ),
          ),
        const SizedBox(height: 14),
        FilledButton(onPressed: onDone, child: Text(done)),
      ],
    );
  }
}
