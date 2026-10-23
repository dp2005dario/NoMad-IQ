// Ver un documento de la Bóveda: la foto (se puede ampliar con dos dedos)
// o las páginas del PDF. Se descifra solo en la memoria del móvil.
// Desde aquí se cambia su nombre/caducidad o se borra.
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../core/services.dart';
import '../../core/theme.dart';
import '../../l10n/generated/app_localizations.dart';
import 'doc_form.dart';
import 'vault.dart';
import 'vault_widgets.dart';

class DocViewerScreen extends StatefulWidget {
  const DocViewerScreen({super.key, required this.doc});

  final VaultDoc doc;

  @override
  State<DocViewerScreen> createState() => _DocViewerScreenState();
}

class _DocViewerScreenState extends State<DocViewerScreen> {
  late final AppServices _services = ServicesScope.of(context);
  late final Vault _vault = _services.vault;
  late VaultDoc _doc = widget.doc;
  Future<List<Uint8List>>? _pages;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _pages ??= _load();
    _vault.addListener(_closed);
  }

  @override
  void dispose() {
    _vault.removeListener(_closed);
    super.dispose();
  }

  /// Si la Bóveda se cierra (2 minutos o al salir), el documento desaparece.
  void _closed() {
    if (!_vault.isOpen && mounted) Navigator.of(context).maybePop();
  }

  Future<List<Uint8List>> _load() async {
    final Uint8List bytes = await _vault.content(_doc.id);
    if (!_doc.isPdf) return <Uint8List>[bytes];
    return _services.docReader.render(bytes);
  }

  Future<void> _edit() async {
    final DocFields? f = await showDocForm(
      context,
      kind: _doc.kind,
      title: _doc.title,
      detail: _doc.detail,
      expires: _doc.expires,
    );
    if (f == null || !_vault.isOpen) return;
    final VaultDoc updated = _doc.copyWith(
      kind: f.kind,
      title: f.title,
      detail: f.detail,
      expires: f.expires,
      clearExpires: f.expires == null,
    );
    await _vault.update(updated);
    if (mounted) setState(() => _doc = updated);
  }

  Future<void> _delete() async {
    final AppLocalizations t = AppLocalizations.of(context);
    final bool? yes = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: Text(t.vaultDeleteConfirm(_doc.title)),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(MaterialLocalizations.of(context).cancelButtonLabel),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              minimumSize: const Size(0, 48),
              backgroundColor: NomadColors.safety,
            ),
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(t.moneyDelete),
          ),
        ],
      ),
    );
    if (yes != true || !_vault.isOpen) return;
    _vault.removeListener(_closed);
    await _vault.delete(_doc.id);
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    final (String, Color)? expiry = expiryLine(context, _doc, DateTime.now());
    return Scaffold(
      appBar: AppBar(
        title: Text(_doc.title),
        actions: <Widget>[
          IconButton(
            tooltip: t.vaultEdit,
            onPressed: _edit,
            icon: const Icon(Icons.edit_rounded),
          ),
          IconButton(
            tooltip: t.moneyDelete,
            onPressed: _delete,
            icon: const Icon(Icons.delete_outline_rounded),
          ),
        ],
      ),
      body: Listener(
        onPointerDown: (_) => _vault.touch(),
        child: Column(
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Row(
                children: <Widget>[
                  Icon(kindIcon(_doc.kind), color: kindColor(_doc.kind)),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      <String>[
                        kindLabel(t, _doc.kind),
                        if (_doc.detail != null) _doc.detail!,
                        if (expiry != null) expiry.$1,
                      ].join(' · '),
                      style: TextStyle(
                        color: expiry?.$2 ?? NomadColors.textMuted,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: FutureBuilder<List<Uint8List>>(
                future: _pages,
                builder:
                    (
                      BuildContext context,
                      AsyncSnapshot<List<Uint8List>> snap,
                    ) {
                      if (snap.hasError) {
                        return Center(child: Text(t.vaultCantShow));
                      }
                      final List<Uint8List>? pages = snap.data;
                      if (pages == null) {
                        return const Center(child: CircularProgressIndicator());
                      }
                      if (pages.isEmpty) {
                        return Center(child: Text(t.vaultCantShow));
                      }
                      return InteractiveViewer(
                        maxScale: 5,
                        child: ListView(
                          padding: const EdgeInsets.all(12),
                          children: <Widget>[
                            for (final Uint8List p in pages)
                              Padding(
                                padding: const EdgeInsets.only(bottom: 12),
                                child: Image.memory(
                                  p,
                                  gaplessPlayback: true,
                                  errorBuilder: (_, _, _) =>
                                      Text(t.vaultCantShow),
                                ),
                              ),
                          ],
                        ),
                      );
                    },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
