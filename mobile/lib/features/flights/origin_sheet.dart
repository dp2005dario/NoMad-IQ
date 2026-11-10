// Elegir una ciudad ESCRIBIENDO SU NOMBRE ("Lisboa", "Tokio"), no el código
// raro de tres letras. Sale una lista con la bandera de cada sitio; tocar
// uno devuelve su código de aeropuerto (LIS, NRT...). Si escribes el
// código, también vale.
import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/theme.dart';
import '../../l10n/generated/app_localizations.dart';
import 'airport_names.dart';

/// Abre la hoja y devuelve el código del aeropuerto elegido (o null).
/// [title]: lo que se pregunta arriba (por defecto, "¿Desde dónde vuelas?").
Future<String?> showOriginSheet(
  BuildContext context, {
  required String current,
  String? title,
}) {
  return showModalBottomSheet<String>(
    context: context,
    useRootNavigator: true,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (BuildContext sheet) =>
        _OriginSheet(current: current, title: title),
  );
}

class _OriginSheet extends StatefulWidget {
  const _OriginSheet({required this.current, this.title});

  final String current;
  final String? title;

  @override
  State<_OriginSheet> createState() => _OriginSheetState();
}

class _OriginSheetState extends State<_OriginSheet> {
  final TextEditingController _text = TextEditingController();
  AirportNames? _names;

  @override
  void initState() {
    super.initState();
    _text.addListener(() => setState(() {}));
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final AirportNames names = await AirportNames.load();
      if (mounted) setState(() => _names = names);
    } on Object {
      // Sin la lista solo vale escribir el código.
      if (mounted) setState(() => _names = AirportNames(const <AirportName>[]));
    }
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  /// Lo que sale en la lista: lo que coincide con lo escrito o, sin nada
  /// escrito, las ciudades más buscadas.
  List<AirportName> _found(AirportNames names) {
    final String q = _text.text.trim();
    if (q.isEmpty) return names.all.take(10).toList();
    return names.search(q, limit: 12);
  }

  /// Enter en el teclado: el primero de la lista, o el código si escribiste
  /// uno de 3 letras.
  void _submit(List<AirportName> list) {
    if (list.isNotEmpty) {
      Navigator.pop(context, list.first.iata);
      return;
    }
    final String code = _text.text.trim().toUpperCase();
    if (RegExp(r'^[A-Z]{3}$').hasMatch(code)) Navigator.pop(context, code);
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    final AirportNames? names = _names;
    final List<AirportName> list = names == null
        ? const <AirportName>[]
        : _found(names);
    final AirportName? now = names?[widget.current];
    return Padding(
      padding: EdgeInsets.fromLTRB(
        20,
        0,
        20,
        12 + MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.7,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text(
              widget.title ?? t.flightsOriginTitle,
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 14),
            TextField(
              controller: _text,
              autofocus: true,
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                hintText: t.searchCityHint,
                prefixIcon: const Icon(Icons.search_rounded),
                filled: true,
                fillColor: const Color(0xFF0E1828),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(16),
                  borderSide: BorderSide.none,
                ),
              ),
              onSubmitted: (_) => _submit(list),
            ),
            const SizedBox(height: 12),
            if (_text.text.trim().isEmpty && names != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text(
                  t.cityPickPopular.toUpperCase(),
                  style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.8,
                    color: NomadColors.textMuted,
                  ),
                ),
              ),
            if (names == null)
              const Padding(
                padding: EdgeInsets.all(20),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (list.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 18),
                child: Text(
                  t.cityPickNone,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: NomadColors.textMuted),
                ),
              )
            else
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: list.length,
                  itemBuilder: (BuildContext _, int i) {
                    final AirportName a = list[i];
                    return _CityRow(
                      airport: a,
                      chosen: a.iata == now?.iata,
                      onTap: () => Navigator.pop(context, a.iata),
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

/// Una fila: bandera, ciudad, país y el código pequeñito a la derecha.
class _CityRow extends StatelessWidget {
  const _CityRow({
    required this.airport,
    required this.chosen,
    required this.onTap,
  });

  final AirportName airport;
  final bool chosen;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Material(
      color: chosen
          ? NomadColors.mint.withValues(alpha: 0.12)
          : const Color(0xFF111C23),
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            children: <Widget>[
              Text(airport.flag, style: const TextStyle(fontSize: 24)),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      airport.city,
                      style: const TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 15,
                      ),
                    ),
                    Text(
                      airport.country,
                      style: const TextStyle(
                        color: NomadColors.textMuted,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
              Text(
                airport.iata,
                style: const TextStyle(
                  color: NomadColors.textMuted,
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1,
                ),
              ),
              if (chosen) ...<Widget>[
                const SizedBox(width: 8),
                const Icon(
                  Icons.check_circle_rounded,
                  color: NomadColors.mint,
                  size: 18,
                ),
              ],
            ],
          ),
        ),
      ),
    ),
  );
}
