// "Compartir mi viaje": escribes el título, el destino, los días y las cosas
// que pagaste (o las rellenas desde un bote de Gastos) y te damos un código
// para pasárselo a quien quieras.
//
// Solo se comparte lo que ves en esta pantalla: ni fechas, ni con quién
// fuiste, ni tu cuenta. Los demás ven el nombre que pongas.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/api_client.dart';
import '../../core/money.dart';
import '../../core/services.dart';
import '../../core/theme.dart';
import '../../l10n/generated/app_localizations.dart';
import '../money/expenses_api.dart';
import 'copied_trips.dart';
import 'copy_trip_screen.dart';
import 'shared_trip_api.dart';

class ShareTripScreen extends StatefulWidget {
  const ShareTripScreen({super.key});

  @override
  State<ShareTripScreen> createState() => _ShareTripScreenState();
}

class _ShareTripScreenState extends State<ShareTripScreen> {
  late final AppServices _services = ServicesScope.of(context);
  final TextEditingController _title = TextEditingController();
  late final TextEditingController _author = TextEditingController(
    text: _services.prefs.readGroupName() ?? '',
  );
  final TextEditingController _destination = TextEditingController();
  final TextEditingController _days = TextEditingController(text: '7');
  final TextEditingController _currency = TextEditingController(text: 'EUR');
  final List<TripLine> _lines = <TripLine>[];
  bool _sending = false;
  String? _error;

  @override
  void dispose() {
    for (final TextEditingController c in <TextEditingController>[
      _title,
      _author,
      _destination,
      _days,
      _currency,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  String get _cur => _currency.text.trim().toUpperCase();

  Future<void> _fromExpenses() async {
    final AppLocalizations t = AppLocalizations.of(context);
    List<ExpenseGroupSummary> groups;
    try {
      groups = await _services.expenses.list();
    } on ApiException {
      if (mounted) setState(() => _error = t.copyOffline);
      return;
    }
    if (!mounted) return;
    if (groups.isEmpty) {
      setState(() => _error = t.copyNoGroups);
      return;
    }
    final ExpenseGroupSummary? picked =
        await showModalBottomSheet<ExpenseGroupSummary>(
          context: context,
          useRootNavigator: true,
          builder: (BuildContext context) => SafeArea(
            child: ListView(
              shrinkWrap: true,
              children: <Widget>[
                ListTile(title: Text(t.copyPickGroup)),
                for (final ExpenseGroupSummary g in groups)
                  ListTile(
                    leading: const Icon(Icons.savings_rounded),
                    title: Text(g.title),
                    onTap: () => Navigator.of(context).pop(g),
                  ),
              ],
            ),
          ),
        );
    if (picked == null) return;
    try {
      final ExpenseGroup group = await _services.expenses.get(picked.id);
      if (!mounted) return;
      setState(() {
        _lines
          ..clear()
          ..addAll(linesFromExpenses(group));
        _currency.text = group.currency;
        if (_title.text.trim().isEmpty) _title.text = group.title;
        _error = null;
      });
    } on ApiException {
      if (mounted) setState(() => _error = t.copyOffline);
    }
  }

  Future<void> _editLine([int? index]) async {
    final TripLine? edited = await showModalBottomSheet<TripLine>(
      context: context,
      isScrollControlled: true,
      useRootNavigator: true,
      builder: (BuildContext context) => _LineSheet(
        line: index == null ? null : _lines[index],
        currency: _cur.length == 3 ? _cur : 'EUR',
      ),
    );
    if (edited == null || !mounted) return;
    setState(() {
      if (index == null) {
        if (_lines.length < 30) _lines.add(edited);
      } else {
        _lines[index] = edited;
      }
    });
  }

  Future<void> _send() async {
    final AppLocalizations t = AppLocalizations.of(context);
    final int? days = int.tryParse(_days.text.trim());
    if (_title.text.trim().isEmpty ||
        _author.text.trim().isEmpty ||
        _destination.text.trim().isEmpty ||
        days == null ||
        days < 1 ||
        days > 60 ||
        !RegExp(r'^[A-Z]{3}$').hasMatch(_cur) ||
        _lines.isEmpty) {
      setState(() => _error = t.copyFillAll);
      return;
    }
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      final SharedTrip shared = await _services.sharedTrips.share(
        NewSharedTrip(
          title: _title.text.trim(),
          author: _author.text.trim(),
          destination: _destination.text.trim(),
          days: days,
          currency: _cur,
          lines: List<TripLine>.of(_lines),
        ),
      );
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (BuildContext context) => AlertDialog(
          title: Text(t.copySharedTitle),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(t.copySharedBody),
              const SizedBox(height: 16),
              SelectableText(
                '${shared.code.substring(0, 4)}-${shared.code.substring(4)}',
                style: Theme.of(context).textTheme.headlineMedium,
              ),
            ],
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => unawaited(
                Clipboard.setData(ClipboardData(text: shared.code)),
              ),
              child: Text(t.copyCopyCode),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(t.copyDone),
            ),
          ],
        ),
      );
      if (mounted) Navigator.of(context).pop(shared);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(
        () => _error = switch (e.error) {
          ApiError.conflict => t.copyTooMany,
          ApiError.network => t.copyOffline,
          _ => t.copyFailed,
        },
      );
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    final TextTheme text = Theme.of(context).textTheme;
    final String locale = Localizations.localeOf(context).toLanguageTag();
    final String cur = RegExp(r'^[A-Z]{3}$').hasMatch(_cur) ? _cur : 'EUR';
    return Scaffold(
      appBar: AppBar(title: Text(t.copyShareMine)),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
        children: <Widget>[
          Text(
            t.copyShareWhat,
            style: text.bodyMedium?.copyWith(color: NomadColors.textMuted),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _title,
            maxLength: 60,
            decoration: InputDecoration(labelText: t.copyFieldTitle),
          ),
          TextField(
            controller: _author,
            maxLength: 30,
            decoration: InputDecoration(labelText: t.copyFieldAuthor),
          ),
          TextField(
            controller: _destination,
            maxLength: 60,
            decoration: InputDecoration(labelText: t.copyFieldDestination),
          ),
          Row(
            children: <Widget>[
              Expanded(
                child: TextField(
                  controller: _days,
                  keyboardType: TextInputType.number,
                  inputFormatters: <TextInputFormatter>[
                    FilteringTextInputFormatter.digitsOnly,
                    LengthLimitingTextInputFormatter(2),
                  ],
                  decoration: InputDecoration(labelText: t.copyFieldDays),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: TextField(
                  controller: _currency,
                  textCapitalization: TextCapitalization.characters,
                  inputFormatters: <TextInputFormatter>[
                    FilteringTextInputFormatter.allow(RegExp('[A-Za-z]')),
                    LengthLimitingTextInputFormatter(3),
                  ],
                  onChanged: (_) => setState(() {}),
                  decoration: InputDecoration(labelText: t.copyFieldCurrency),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          OutlinedButton.icon(
            onPressed: () => unawaited(_fromExpenses()),
            icon: const Icon(Icons.savings_rounded),
            label: Text(t.copyFromExpenses),
          ),
          const SizedBox(height: 12),
          for (int i = 0; i < _lines.length; i++)
            Card(
              child: ListTile(
                leading: Icon(tripKindIcon(_lines[i].kind)),
                title: Text(_lines[i].title),
                subtitle: Text(tripKindLabel(t, _lines[i].kind)),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Text(formatMoney(_lines[i].priceMinor, cur, locale)),
                    IconButton(
                      tooltip: t.copyRemove,
                      icon: const Icon(Icons.close_rounded),
                      onPressed: () => setState(() => _lines.removeAt(i)),
                    ),
                  ],
                ),
                onTap: () => unawaited(_editLine(i)),
              ),
            ),
          TextButton.icon(
            onPressed: _lines.length >= 30
                ? null
                : () => unawaited(_editLine()),
            icon: const Icon(Icons.add_rounded),
            label: Text(t.copyAddLine),
          ),
          if (_lines.isNotEmpty)
            Text(
              t.copyTotal(formatMoney(linesTotal(_lines), cur, locale)),
              style: text.titleMedium,
            ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(
                _error!,
                style: const TextStyle(color: NomadColors.safety),
              ),
            ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: _sending ? null : () => unawaited(_send()),
            icon: const Icon(Icons.ios_share_rounded),
            label: Text(t.copyShareButton),
          ),
          const SizedBox(height: 12),
          Text(
            t.copySharePrivacy,
            style: text.bodySmall?.copyWith(color: NomadColors.textMuted),
          ),
        ],
      ),
    );
  }
}

class _LineSheet extends StatefulWidget {
  const _LineSheet({required this.line, required this.currency});

  final TripLine? line;
  final String currency;

  @override
  State<_LineSheet> createState() => _LineSheetState();
}

class _LineSheetState extends State<_LineSheet> {
  late TripKind _kind = widget.line?.kind ?? TripKind.other;
  late final TextEditingController _title = TextEditingController(
    text: widget.line?.title ?? '',
  );
  late final TextEditingController _price = TextEditingController(
    text: widget.line == null
        ? ''
        : '${minorToWhole(widget.line!.priceMinor, widget.currency)}',
  );

  @override
  void dispose() {
    _title.dispose();
    _price.dispose();
    super.dispose();
  }

  void _save() {
    final String title = _title.text.trim();
    final int? whole = int.tryParse(_price.text.trim());
    if (title.isEmpty || whole == null) return;
    Navigator.of(context).pop(
      TripLine(
        kind: _kind,
        title: title,
        priceMinor: wholeToMinor(whole, widget.currency),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(
        16,
        16,
        16,
        16 + MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              for (final TripKind k in TripKind.values)
                ChoiceChip(
                  avatar: Icon(tripKindIcon(k), size: 18),
                  label: Text(tripKindLabel(t, k)),
                  selected: _kind == k,
                  onSelected: (_) => setState(() => _kind = k),
                ),
            ],
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _title,
            maxLength: 80,
            decoration: InputDecoration(labelText: t.copyLineTitle),
          ),
          TextField(
            controller: _price,
            keyboardType: TextInputType.number,
            inputFormatters: <TextInputFormatter>[
              FilteringTextInputFormatter.digitsOnly,
              LengthLimitingTextInputFormatter(7),
            ],
            decoration: InputDecoration(
              labelText: t.copyLinePrice(widget.currency),
            ),
          ),
          const SizedBox(height: 16),
          FilledButton(onPressed: _save, child: Text(t.copyLineSave)),
        ],
      ),
    );
  }
}
