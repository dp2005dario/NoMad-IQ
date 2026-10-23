// El formulario de un documento: tipo, nombre, detalle y caducidad.
// Sirve para uno nuevo (después de la foto o el PDF) y para editarlo.
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../l10n/generated/app_localizations.dart';
import 'vault.dart';
import 'vault_widgets.dart';

/// Lo que se ha escrito.
class DocFields {
  const DocFields({
    required this.kind,
    required this.title,
    this.detail,
    this.expires,
  });

  final DocKind kind;
  final String title;
  final String? detail;
  final DateTime? expires;
}

Future<DocFields?> showDocForm(
  BuildContext context, {
  required DocKind kind,
  String title = '',
  String? detail,
  DateTime? expires,
}) => showDialog<DocFields>(
  context: context,
  builder: (BuildContext context) =>
      _DocForm(kind: kind, title: title, detail: detail, expires: expires),
);

class _DocForm extends StatefulWidget {
  const _DocForm({
    required this.kind,
    required this.title,
    required this.detail,
    required this.expires,
  });

  final DocKind kind;
  final String title;
  final String? detail;
  final DateTime? expires;

  @override
  State<_DocForm> createState() => _DocFormState();
}

class _DocFormState extends State<_DocForm> {
  late DocKind _kind = widget.kind;
  late final TextEditingController _title = TextEditingController(
    text: widget.title,
  );
  late final TextEditingController _detail = TextEditingController(
    text: widget.detail ?? '',
  );
  late DateTime? _expires = widget.expires;

  @override
  void dispose() {
    _title.dispose();
    _detail.dispose();
    super.dispose();
  }

  Future<void> _pickDate() async {
    final DateTime now = DateTime.now();
    final DateTime? d = await showDatePicker(
      context: context,
      initialDate: _expires ?? DateTime(now.year + 1, now.month, now.day),
      firstDate: DateTime(now.year - 20),
      lastDate: DateTime(now.year + 30),
    );
    if (d != null && mounted) setState(() => _expires = d);
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    final String title = _title.text.trim();
    return AlertDialog(
      scrollable: true,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          DropdownButtonFormField<DocKind>(
            initialValue: _kind,
            isExpanded: true,
            decoration: InputDecoration(labelText: t.vaultDocKind),
            items: <DropdownMenuItem<DocKind>>[
              for (final DocKind k in DocKind.values)
                DropdownMenuItem<DocKind>(
                  value: k,
                  child: Row(
                    children: <Widget>[
                      Icon(kindIcon(k), size: 18, color: kindColor(k)),
                      const SizedBox(width: 8),
                      Flexible(
                        child: Text(
                          kindLabel(t, k),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
            ],
            onChanged: (DocKind? k) => setState(() => _kind = k ?? _kind),
          ),
          TextField(
            controller: _title,
            maxLength: 60,
            decoration: InputDecoration(labelText: t.vaultDocTitle),
            onChanged: (_) => setState(() {}),
          ),
          TextField(
            controller: _detail,
            maxLength: 80,
            decoration: InputDecoration(labelText: t.vaultDocDetail),
          ),
          Row(
            children: <Widget>[
              Expanded(
                child: OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size(0, 48),
                  ),
                  onPressed: _pickDate,
                  icon: const Icon(Icons.event_rounded),
                  label: Text(
                    _expires == null
                        ? t.vaultDocExpires
                        : DateFormat.yMMMd(
                            Localizations.localeOf(context).toLanguageTag(),
                          ).format(_expires!),
                  ),
                ),
              ),
              if (_expires != null)
                IconButton(
                  tooltip: t.vaultNoExpiry,
                  onPressed: () => setState(() => _expires = null),
                  icon: const Icon(Icons.close_rounded),
                ),
            ],
          ),
        ],
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(MaterialLocalizations.of(context).cancelButtonLabel),
        ),
        FilledButton(
          style: FilledButton.styleFrom(minimumSize: const Size(0, 48)),
          onPressed: title.isEmpty
              ? null
              : () => Navigator.of(context).pop(
                  DocFields(
                    kind: _kind,
                    title: title,
                    detail: _detail.text.trim().isEmpty
                        ? null
                        : _detail.text.trim(),
                    expires: _expires,
                  ),
                ),
          child: Text(t.flightsOriginSave),
        ),
      ],
    );
  }
}
