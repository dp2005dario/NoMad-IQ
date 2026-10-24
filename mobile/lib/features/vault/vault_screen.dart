// La pantalla de la Bóveda (maqueta "Bóveda de documentos").
//
// Cerrada: el botón grande de la huella. Abierta: el pasaporte arriba, el
// resto de documentos en una rejilla, "Escanear documento" y "Cerrar".
// Mientras se ve, Android no deja hacer capturas (SecureWindow) y, si sales
// de la app, la Bóveda se cierra sola.
import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/services.dart';
import '../../core/theme.dart';
import '../../l10n/generated/app_localizations.dart';
import 'doc_form.dart';
import 'doc_source.dart';
import 'doc_viewer_screen.dart';
import 'secure_window.dart';
import 'vault.dart';
import 'vault_store.dart';
import 'vault_widgets.dart';

class VaultScreen extends StatefulWidget {
  const VaultScreen({super.key});

  @override
  State<VaultScreen> createState() => _VaultScreenState();
}

class _VaultScreenState extends State<VaultScreen> {
  late final AppServices _services = ServicesScope.of(context);
  late final Vault _vault = _services.vault;
  late final AppLifecycleListener _life;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    unawaited(SecureWindow.set(secure: true));
    // Al salir de la app (o bloquear el móvil), se cierra.
    _life = AppLifecycleListener(onHide: () => _vault.close());
  }

  @override
  void dispose() {
    _life.dispose();
    unawaited(SecureWindow.set(secure: false));
    super.dispose();
  }

  void _say(String text) => ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(text)));

  Future<void> _open() async {
    final AppLocalizations t = AppLocalizations.of(context);
    final UnlockResult r = await _vault.open(t.vaultUnlockReason);
    if (!mounted) return;
    switch (r) {
      case UnlockResult.ok:
        break;
      case UnlockResult.cancelled:
        _say(t.vaultUnlockFailed);
      case UnlockResult.unavailable:
        _say(t.vaultNoLock);
    }
  }

  Future<void> _add(DocOrigin origin) async {
    final AppLocalizations t = AppLocalizations.of(context);
    final PickedDoc? picked = await _services.docSource.pick(origin);
    if (picked == null || !mounted) return;
    if (picked.bytes.isEmpty || picked.bytes.length > maxDocBytes) {
      _say(t.vaultTooBig);
      return;
    }
    final DocFields? fields = await showDocForm(
      context,
      kind: origin == DocOrigin.pdf ? DocKind.other : DocKind.passport,
      title: _nameOf(picked.name),
    );
    if (fields == null || !mounted || !_vault.isOpen) return;
    setState(() => _busy = true);
    try {
      final DocTextReader reader = _services.docReader;
      final List<String> text = await reader.read(picked);
      final int pages = await reader.pages(picked);
      await _vault.add(
        kind: fields.kind,
        title: fields.title,
        detail: fields.detail,
        expires: fields.expires,
        mime: picked.mime,
        bytes: picked.bytes,
        text: text,
        pages: pages,
      );
      if (mounted) _say(t.vaultSaved);
    } on VaultFull {
      if (mounted) _say(t.vaultFull);
    } on DocTooBig {
      if (mounted) _say(t.vaultTooBig);
    } on StateError {
      // Se cerró sola mientras se leía: no se guarda nada a medias.
      if (mounted) _say(t.vaultUnlockFailed);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// "Poliza Viaje Plus.pdf" → "Poliza Viaje Plus".
  static String _nameOf(String? file) {
    if (file == null || file.startsWith('image_picker')) return '';
    final String base = file.replaceFirst(RegExp(r'\.[A-Za-z0-9]{1,5}$'), '');
    return base.length > 60 ? base.substring(0, 60) : base;
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(t.vaultTitle)),
      body: Listener(
        // Cualquier toque cuenta como "sigo aquí" (2 minutos más).
        onPointerDown: (_) => _vault.touch(),
        child: ListenableBuilder(
          listenable: _vault,
          builder: (BuildContext context, _) =>
              _vault.isOpen ? _openView(context) : _lockedView(context),
        ),
      ),
    );
  }

  Widget _lockedView(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    final TextTheme text = Theme.of(context).textTheme;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          children: <Widget>[
            Container(
              width: 180,
              height: 180,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: const Color(0xFF10221C),
                border: Border.all(color: const Color(0xFF1F4237)),
              ),
              child: Material(
                color: NomadColors.background,
                shape: const CircleBorder(
                  side: BorderSide(color: NomadColors.mint, width: 2),
                ),
                child: InkWell(
                  customBorder: const CircleBorder(),
                  onTap: _open,
                  child: SizedBox.square(
                    dimension: 120,
                    child: Icon(
                      Icons.fingerprint_rounded,
                      size: 64,
                      color: NomadColors.mint,
                      semanticLabel: t.vaultTapToOpen,
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 22),
            Text(
              t.vaultTapToOpen,
              textAlign: TextAlign.center,
              style: text.titleLarge,
            ),
            const SizedBox(height: 8),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 320),
              child: Text(
                t.vaultLockedText,
                textAlign: TextAlign.center,
                style: const TextStyle(color: NomadColors.textMuted),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _openView(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    final List<VaultDoc> docs = _vault.docs;
    final VaultDoc? passport = docs
        .where((VaultDoc d) => d.kind == DocKind.passport)
        .firstOrNull;
    final List<VaultDoc> rest = <VaultDoc>[
      for (final VaultDoc d in docs)
        if (d != passport) d,
    ];
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
      children: <Widget>[
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: Container(
            height: 36,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              color: const Color(0xFF10221C),
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: const Color(0xFF1F4237)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                const Icon(
                  Icons.lock_open_rounded,
                  size: 14,
                  color: NomadColors.mint,
                ),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    t.vaultOpenChip(_vault.autoLock.inMinutes),
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: Color(0xFFCFE9DE),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 14),
        if (passport != null) ...<Widget>[
          _PassportCard(doc: passport, onTap: () => _view(passport)),
          const SizedBox(height: 10),
        ],
        if (docs.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: Text(
              t.vaultEmpty,
              style: const TextStyle(color: NomadColors.textMuted),
            ),
          ),
        LayoutBuilder(
          builder: (BuildContext context, BoxConstraints box) {
            final double w = (box.maxWidth - 8) / 2;
            return Wrap(
              spacing: 8,
              runSpacing: 8,
              children: <Widget>[
                for (final VaultDoc d in rest)
                  SizedBox(
                    width: w,
                    child: _DocTile(doc: d, onTap: () => _view(d)),
                  ),
              ],
            );
          },
        ),
        const SizedBox(height: 14),
        if (_busy)
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              const SizedBox.square(
                dimension: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(width: 10),
              Text(t.vaultReading),
            ],
          )
        else ...<Widget>[
          OutlinedButton.icon(
            style: OutlinedButton.styleFrom(
              side: const BorderSide(color: Color(0xFF33444E)),
            ),
            onPressed: () => _add(DocOrigin.camera),
            icon: const Icon(Icons.photo_camera_rounded),
            label: Text(t.vaultScan),
          ),
          const SizedBox(height: 6),
          Row(
            children: <Widget>[
              Expanded(
                child: TextButton.icon(
                  onPressed: () => _add(DocOrigin.gallery),
                  icon: const Icon(Icons.photo_library_rounded),
                  label: Text(t.vaultFromGallery),
                ),
              ),
              Expanded(
                child: TextButton.icon(
                  onPressed: () => _add(DocOrigin.pdf),
                  icon: const Icon(Icons.picture_as_pdf_rounded),
                  label: Text(t.vaultFromPdf),
                ),
              ),
            ],
          ),
        ],
        const SizedBox(height: 10),
        FilledButton.tonal(onPressed: _vault.close, child: Text(t.vaultClose)),
        const SizedBox(height: 14),
        Text(
          t.vaultPrivacyNote,
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 12, color: NomadColors.textMuted),
        ),
      ],
    );
  }

  Future<void> _view(VaultDoc doc) => Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (BuildContext context) => DocViewerScreen(doc: doc),
    ),
  );
}

class _PassportCard extends StatelessWidget {
  const _PassportCard({required this.doc, required this.onTap});

  final VaultDoc doc;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    final (String, Color)? expiry = expiryLine(context, doc, DateTime.now());
    return Material(
      color: const Color(0xFF13213A),
      borderRadius: BorderRadius.circular(24),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: const Color(0xFF2A3E63)),
          ),
          child: Stack(
            children: <Widget>[
              const PositionedDirectional(
                end: -36,
                top: -36,
                child: Icon(
                  Icons.public_rounded,
                  size: 130,
                  color: Color(0xFF2A3E63),
                ),
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    t.vaultKindPassport.toUpperCase(),
                    style: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.8,
                      color: Color(0xFF9CC4FF),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    doc.title,
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 6),
                  Text(
                    <String>[
                      if (expiry != null) expiry.$1,
                      t.vaultNumberHidden,
                    ].join(' · '),
                    style: TextStyle(
                      fontSize: 13,
                      color:
                          expiry == null || expiry.$2 == NomadColors.textMuted
                          ? const Color(0xFFA9BEDF)
                          : expiry.$2,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DocTile extends StatelessWidget {
  const _DocTile({required this.doc, required this.onTap});

  final VaultDoc doc;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    final (String, Color)? expiry = expiryLine(context, doc, DateTime.now());
    return Material(
      color: NomadColors.surface,
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: NomadColors.outline),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: kindColor(doc.kind),
                  borderRadius: BorderRadius.circular(11),
                ),
                child: Icon(
                  kindIcon(doc.kind),
                  size: 18,
                  color: NomadColors.background,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                doc.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w800),
              ),
              Text(
                expiry?.$1 ?? doc.detail ?? kindLabel(t, doc.kind),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12,
                  color: expiry?.$2 ?? NomadColors.textMuted,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
