// La Bóveda de documentos (maqueta "Bóveda"), tal cual: la puerta de la caja
// fuerte con la huella, la puerta abriéndose y las 13 tarjetas (pasaporte,
// tarjeta de embarque, seguro, DNI, visado, hotel, entradas, contactos SOS,
// carnet, tarjeta sanitaria, coche, tren/bus y eSIM).
//
// La página es la propia maqueta (assets/vault/boveda.html) dentro de un
// WebView, sin datos de ejemplo. Lo real lo pone la app (vault_page.dart):
//   - La huella es la del móvil (la ventana del sistema).
//   - "Cámara", "Galería" y "PDF" abren los del móvil. El texto se lee
//     DENTRO del móvil y se buscan los tres datos de esa tarjeta
//     (vault_fields.dart); tú los corriges antes de guardar.
//   - "A mano" guarda solo los datos que escribes.
//   - Todo se guarda cifrado (vault.dart). Mientras se ve, Android no deja
//     hacer capturas (SecureWindow) y, si sales de la app, se cierra sola.
//   - Una tarjeta guardada se abre: la foto o el PDF en el visor (con las
//     preguntas a la póliza), y los datos a mano en su formulario.
import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/services.dart';
import '../../l10n/generated/app_localizations.dart';
import '../route/web_scene.dart';
import 'doc_source.dart';
import 'doc_viewer_screen.dart';
import 'secure_window.dart';
import 'vault.dart';
import 'vault_fields.dart';
import 'vault_page.dart';
import 'vault_store.dart';
import 'vault_widgets.dart';

/// Hace la miniatura de una foto para su tarjeta (null si no se puede).
typedef VaultThumbnail = Future<String?> Function(Uint8List image);

/// La miniatura de verdad: la foto a 260 px de ancho, como PNG.
Future<String?> photoThumbnail(Uint8List image) async {
  try {
    final ui.Codec codec = await ui.instantiateImageCodec(
      image,
      targetWidth: 260,
    );
    final ui.FrameInfo frame = await codec.getNextFrame();
    final ByteData? png = await frame.image.toByteData(
      format: ui.ImageByteFormat.png,
    );
    frame.image.dispose();
    codec.dispose();
    if (png == null) return null;
    return 'data:image/png;base64,${base64Encode(png.buffer.asUint8List())}';
  } on Object {
    // Una foto que no se puede abrir se queda sin miniatura.
    return null;
  }
}

/// El nombre de cada tarjeta (el título del documento al guardarlo).
String slotTitle(AppLocalizations t, int slot) => switch (slot) {
  7 => t.vaultSlotTicket,
  8 => t.vaultSlotContacts,
  9 => t.vaultSlotDriving,
  11 => t.vaultSlotCar,
  12 => t.vaultSlotTrain,
  13 => t.vaultSlotEsim,
  _ => kindLabel(t, kindOfSlot(slot)),
};

/// Un PDF elegido que espera a que confirmes sus datos.
class _Pending {
  const _Pending(this.slot, this.doc, this.text, this.pages);

  final int slot;
  final PickedDoc doc;
  final List<String> text;
  final int pages;
}

class VaultScreen extends StatefulWidget {
  const VaultScreen({super.key, this.thumbnail = photoThumbnail});

  final VaultThumbnail thumbnail;

  @override
  State<VaultScreen> createState() => _VaultScreenState();
}

class _VaultScreenState extends State<VaultScreen> {
  late final AppServices _services = ServicesScope.of(context);
  late final Vault _vault = _services.vault;
  late final AppLifecycleListener _life;

  String? _page;
  String? _html;
  bool _started = false;

  /// Ya se vio la puerta abrirse (las siguientes veces sale abierta).
  bool _shownOpening = false;
  final Map<String, String> _thumbs = <String, String>{};
  _Pending? _pending;

  @override
  void initState() {
    super.initState();
    unawaited(SecureWindow.set(secure: true));
    // Al salir de la app (o bloquear el móvil), se cierra. Pero no al abrir
    // la cámara, la galería o los archivos para guardar algo aquí: antes la
    // foto de la cámara te sacaba de la Bóveda y no se guardaba.
    _life = AppLifecycleListener(
      onHide: () {
        if (!_vault.away) _vault.close();
      },
    );
    _vault.addListener(_vaultChanged);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    unawaited(_start());
  }

  @override
  void dispose() {
    _vault.removeListener(_vaultChanged);
    _life.dispose();
    unawaited(SecureWindow.set(secure: false));
    super.dispose();
  }

  Future<void> _start() async {
    // Sin caché: la página solo se lee al abrir la pantalla.
    _page = await rootBundle.loadString(vaultPage, cache: false);
    if (!mounted) return;
    _shownOpening = _vault.isOpen;
    if (_vault.isOpen) await _makeThumbs();
    _show();
  }

  /// Se cerró sola (2 minutos sin tocar o al salir): vuelve la puerta.
  void _vaultChanged() {
    if (!_vault.isOpen && _shownOpening) {
      _shownOpening = false;
      _pending = null;
      _thumbs.clear();
      _show();
    }
  }

  /// Vuelve a pintar la página con lo que haya.
  void _show({
    String scan = '',
    int slot = 1,
    List<String> found = const <String>[],
    String file = '',
    String? message,
    bool opening = false,
    bool denied = false,
  }) {
    if (!mounted || _page == null) return;
    final VaultPhase phase = !_vault.isOpen
        ? VaultPhase.locked
        : opening
        ? VaultPhase.opening
        : VaultPhase.open;
    final Map<String, Object?> data = vaultPageData(
      phase: phase,
      docs: _vault.docs,
      thumbs: _thumbs,
      scan: scan,
      slot: slot,
      found: found,
      file: file,
      message: message,
      denied: denied,
    );
    setState(() => _html = vaultPageWith(_page!, data));
  }

  /// Las miniaturas de las fotos de las tarjetas.
  Future<void> _makeThumbs() async {
    for (final VaultDoc d in docsBySlot(_vault.docs).values) {
      if (d.isPdf || d.isData || _thumbs.containsKey(d.id)) continue;
      try {
        final String? thumb = await widget.thumbnail(
          await _vault.content(d.id),
        );
        if (thumb != null) _thumbs[d.id] = thumb;
      } on Exception {
        // Sin miniatura: la tarjeta sale con sus datos.
      } on StateError {
        return; // Se cerró mientras tanto.
      }
    }
  }

  Future<void> _unlock() async {
    final AppLocalizations t = AppLocalizations.of(context);
    final UnlockResult r = await _vault.open(t.vaultUnlockReason);
    if (!mounted) return;
    switch (r) {
      case UnlockResult.ok:
        await _makeThumbs();
        _shownOpening = true;
        _show(opening: true);
      case UnlockResult.cancelled:
        // No te reconoció (o cerraste la ventana): la huella se pone en
        // rojo, tiembla y el móvil vibra.
        unawaited(HapticFeedback.heavyImpact());
        unawaited(HapticFeedback.vibrate());
        _show(message: t.vaultUnlockFailed, denied: true);
      case UnlockResult.unavailable:
        _show(message: t.vaultNoLock);
    }
  }

  void _lock() {
    _shownOpening = false;
    _pending = null;
    _thumbs.clear();
    _vault.close();
    _show();
  }

  /// Foto con la cámara o de la galería: se lee y se guarda en su tarjeta.
  Future<void> _photo(int slot, DocOrigin origin) async {
    final AppLocalizations t = AppLocalizations.of(context);
    final PickedDoc? picked = await _vault.whileAway(
      () => _services.docSource.pick(origin),
    );
    if (picked == null || !mounted || !_vault.isOpen) return;
    if (picked.bytes.isEmpty || picked.bytes.length > maxDocBytes) {
      _show(message: t.vaultTooBig);
      return;
    }
    final DocTextReader reader = _services.docReader;
    final List<String> text = await reader.read(picked);
    await _save(
      slot,
      picked,
      text: text,
      pages: await reader.pages(picked),
      fields: readFields(slot, text),
    );
  }

  /// PDF: se lee en el móvil y se enseña lo encontrado para confirmarlo.
  Future<void> _pdf(int slot) async {
    final AppLocalizations t = AppLocalizations.of(context);
    final PickedDoc? picked = await _vault.whileAway(
      () => _services.docSource.pick(DocOrigin.pdf),
    );
    if (picked == null || !mounted || !_vault.isOpen) return;
    if (picked.bytes.isEmpty || picked.bytes.length > maxDocBytes) {
      _show(message: t.vaultTooBig);
      return;
    }
    final String file = picked.name ?? '';
    _show(scan: 'pdf', slot: slot, file: file);
    final DocTextReader reader = _services.docReader;
    final List<String> text = await reader.read(picked);
    final int pages = await reader.pages(picked);
    if (!mounted || !_vault.isOpen) return;
    final List<String> found = readFields(slot, text);
    if (found.every((String f) => f.isEmpty)) {
      // "Ese archivo no sirve": no tiene los datos de esta tarjeta.
      _show(scan: 'pdferr', slot: slot, file: file);
      return;
    }
    _pending = _Pending(slot, picked, text, pages);
    _show(scan: 'pdfok', slot: slot, file: file, found: found);
  }

  /// "Guardar": el PDF que espera, o los datos escritos a mano.
  Future<void> _saveData(int slot, List<String> fields) async {
    final _Pending? pending = _pending;
    _pending = null;
    if (pending != null && pending.slot == slot) {
      await _save(
        slot,
        pending.doc,
        text: pending.text,
        pages: pending.pages,
        fields: fields,
      );
      return;
    }
    if (fields.every((String f) => f.isEmpty)) {
      _show();
      return;
    }
    final VaultDoc? old = docsBySlot(_vault.docs)[slot];
    if (old != null && old.isData) {
      await _vault.update(old.copyWith(fields: fields));
      if (mounted) _show(message: AppLocalizations.of(context).vaultSaved);
      return;
    }
    await _save(
      slot,
      PickedDoc(bytes: utf8.encode(jsonEncode(fields)), mime: dataMime),
      fields: fields,
    );
  }

  Future<void> _save(
    int slot,
    PickedDoc picked, {
    List<String> text = const <String>[],
    int pages = 1,
    List<String> fields = const <String>[],
  }) async {
    final AppLocalizations t = AppLocalizations.of(context);
    try {
      final VaultDoc doc = await _vault.add(
        kind: kindOfSlot(slot),
        title: slotTitle(t, slot),
        mime: picked.mime,
        bytes: picked.bytes,
        text: text,
        pages: pages,
        slot: slot,
        fields: fields,
      );
      if (!doc.isPdf && !doc.isData) {
        final String? thumb = await widget.thumbnail(picked.bytes);
        if (thumb != null) _thumbs[doc.id] = thumb;
      }
      _show(message: t.vaultSaved);
    } on VaultFull {
      _show(message: t.vaultFull);
    } on DocTooBig {
      _show(message: t.vaultTooBig);
    } on StateError {
      // Se cerró sola mientras se leía: no se guarda nada a medias.
      _show(message: t.vaultUnlockFailed);
    }
  }

  /// Una tarjeta guardada: la foto o el PDF en el visor; los datos a mano,
  /// en su formulario para cambiarlos.
  Future<void> _view(int slot) async {
    final VaultDoc? doc = docsBySlot(_vault.docs)[slot];
    if (doc == null) return;
    if (doc.isData) {
      _show(scan: 'form', slot: slot);
      return;
    }
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (BuildContext context) => DocViewerScreen(doc: doc),
      ),
    );
    // Al volver (quizá lo borraste), se pinta lo que haya.
    if (mounted && _vault.isOpen) _show();
  }

  /// Lo que pide la página.
  void _onMessage(String message) {
    _vault.touch();
    final List<String> part = message.split(':');
    final int slot = int.tryParse(part.length > 1 ? part[1] : '') ?? 0;
    final bool okSlot = slot >= 1 && slot <= vaultSlots;
    switch (part.first) {
      case 'unlock':
        unawaited(_unlock());
      case 'lock':
        _lock();
      case 'cam' when okSlot:
        unawaited(_photo(slot, DocOrigin.camera));
      case 'gal' when okSlot:
        unawaited(_photo(slot, DocOrigin.gallery));
      case 'pdf' when okSlot:
        unawaited(_pdf(slot));
      case 'save' when okSlot && part.length == 3:
        final List<String>? fields = unpackFields(part[2]);
        if (fields != null) unawaited(_saveData(slot, fields));
      case 'cancel':
        _pending = null;
      case 'view' when okSlot:
        unawaited(_view(slot));
    }
  }

  @override
  Widget build(BuildContext context) {
    final String? html = _html;
    return Scaffold(
      backgroundColor: const Color(0xFF0B1418),
      body: html == null
          ? const SizedBox.expand()
          : Listener(
              // Cualquier toque cuenta como "sigo aquí" (2 minutos más).
              onPointerDown: (_) => _vault.touch(),
              child: SafeArea(
                bottom: false,
                child: KeyedSubtree(
                  key: ValueKey<int>(html.hashCode),
                  child:
                      _services.webScene?.call(html, _onMessage) ??
                      WebScene(html: html, onMessage: _onMessage),
                ),
              ),
            ),
    );
  }
}
