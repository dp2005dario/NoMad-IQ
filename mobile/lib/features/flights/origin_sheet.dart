// La hoja para elegir un aeropuerto (código IATA de 3 letras). La usa Qué
// pasa para elegir la ciudad de los eventos.
import 'package:flutter/material.dart';

import '../../l10n/generated/app_localizations.dart';

/// La hoja para elegir aeropuerto de salida (código IATA de 3 letras).
Future<String?> showOriginSheet(
  BuildContext context, {
  required String current,
}) {
  return showModalBottomSheet<String>(
    context: context,
    useRootNavigator: true,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (BuildContext sheet) => _OriginSheet(current: current),
  );
}

class _OriginSheet extends StatefulWidget {
  const _OriginSheet({required this.current});

  final String current;

  @override
  State<_OriginSheet> createState() => _OriginSheetState();
}

class _OriginSheetState extends State<_OriginSheet> {
  late final TextEditingController _code = TextEditingController(
    text: widget.current,
  );
  bool _invalid = false;

  static final RegExp _iata = RegExp(r'^[A-Z]{3}$');

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  void _save() {
    final String code = _code.text.trim().toUpperCase();
    if (!_iata.hasMatch(code)) {
      setState(() => _invalid = true);
      return;
    }
    Navigator.pop(context, code);
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(
        20,
        0,
        20,
        20 + MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text(
            t.flightsOriginTitle,
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _code,
            autofocus: true,
            maxLength: 3,
            textCapitalization: TextCapitalization.characters,
            decoration: InputDecoration(
              labelText: t.flightsOriginHint,
              errorText: _invalid ? t.flightsOriginInvalid : null,
            ),
            onSubmitted: (_) => _save(),
          ),
          const SizedBox(height: 8),
          FilledButton(onPressed: _save, child: Text(t.flightsOriginSave)),
        ],
      ),
    );
  }
}
