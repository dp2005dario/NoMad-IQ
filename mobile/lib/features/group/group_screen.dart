// Grupo (pestaña de abajo): tus viajes en grupo. Desde aquí se crea uno nuevo
// o se entra en el de un amigo con su código de invitación.
//
// Cómo funciona, para el usuario: cada persona le cuenta a SU agente de IA lo
// que le gusta y cuánto puede gastar (nadie más lo ve). Los agentes negocian
// entre ellos y Flyra trae un plan que todos aceptan.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/api_client.dart';
import '../../core/router.dart';
import '../../core/services.dart';
import '../../core/theme.dart';
import '../../l10n/generated/app_localizations.dart';
import '../../widgets/flyra_avatar.dart';
import 'group_api.dart';
import 'group_widgets.dart';

class GroupScreen extends StatefulWidget {
  const GroupScreen({super.key});

  @override
  State<GroupScreen> createState() => _GroupScreenState();
}

class _GroupScreenState extends State<GroupScreen> {
  late final AppServices _services = ServicesScope.of(context);
  List<GroupTrip>? _trips;
  ApiError? _error;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_trips == null && _error == null) unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final List<GroupTrip> trips = await _services.group.list();
      if (mounted) {
        setState(() {
          _trips = trips;
          _error = null;
        });
      }
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.error);
    }
  }

  Future<void> _open(String id) async {
    await context.push(Routes.groupTrip(id));
    if (mounted) unawaited(_load()); // quizá cambió algo dentro
  }

  Future<void> _create() async {
    final Object? created = await context.push(Routes.groupNew);
    if (created is String && mounted) await _open(created);
  }

  Future<void> _join() async {
    final GroupTrip? trip = await showJoinSheet(context);
    if (trip != null && mounted) await _open(trip.id);
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    final TextTheme text = Theme.of(context).textTheme;
    final List<GroupTrip>? trips = _trips;
    final ApiError? error = _error;
    return Scaffold(
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: _load,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 120),
            children: <Widget>[
              Text(t.groupTitle, style: text.headlineMedium),
              const SizedBox(height: 12),
              _Intro(text: t.groupIntro),
              const SizedBox(height: 16),
              if (error == ApiError.signedOut) ...<Widget>[
                Text(t.groupSignIn, style: text.bodyLarge),
                const SizedBox(height: 12),
                FilledButton(
                  onPressed: () => context.push(Routes.signIn),
                  child: Text(t.signInFromGuest),
                ),
              ] else ...<Widget>[
                FilledButton.icon(
                  onPressed: _create,
                  icon: const Icon(Icons.add_rounded),
                  label: Text(t.groupNew),
                ),
                const SizedBox(height: 10),
                OutlinedButton.icon(
                  onPressed: _join,
                  icon: const Icon(Icons.vpn_key_rounded),
                  label: Text(t.groupJoin),
                ),
                const SizedBox(height: 20),
                if (error != null)
                  _Retry(
                    text: error == ApiError.network
                        ? t.errorNetwork
                        : t.errorUnavailable,
                    onRetry: _load,
                  )
                else if (trips == null)
                  const Padding(
                    padding: EdgeInsets.all(24),
                    child: Center(child: CircularProgressIndicator()),
                  )
                else if (trips.isEmpty)
                  Text(
                    t.groupEmpty,
                    style: const TextStyle(color: NomadColors.textMuted),
                  )
                else
                  for (final GroupTrip trip in trips) ...<Widget>[
                    _TripCard(trip: trip, onTap: () => _open(trip.id)),
                    const SizedBox(height: 10),
                  ],
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// La tarjeta violeta de Flyra que explica la idea en dos líneas.
class _Intro extends StatelessWidget {
  const _Intro({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: const Color(0xFF1A1530),
      borderRadius: BorderRadius.circular(24),
      border: Border.all(color: const Color(0xFF3E3163)),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        const FlyraAvatar(size: 40),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            text,
            style: const TextStyle(color: Color(0xFFDCD3F7), height: 1.4),
          ),
        ),
      ],
    ),
  );
}

class _TripCard extends StatelessWidget {
  const _TripCard({required this.trip, required this.onTap});

  final GroupTrip trip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    final TripOption? chosen = trip.option(trip.result?.chosenOptionId);
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Expanded(child: Text(trip.title, style: text.titleLarge)),
                  const Icon(Icons.chevron_right_rounded),
                ],
              ),
              if (chosen != null) ...<Widget>[
                const SizedBox(height: 4),
                Text(
                  chosen.label,
                  style: const TextStyle(
                    color: NomadColors.group,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
              const SizedBox(height: 12),
              Row(
                children: <Widget>[
                  MemberFaces(members: trip.members, size: 30),
                  const Spacer(),
                  TripStatusChip(trip: trip),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Retry extends StatelessWidget {
  const _Retry({required this.text, required this.onRetry});

  final String text;
  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) => Column(
    children: <Widget>[
      Text(text, textAlign: TextAlign.center),
      const SizedBox(height: 8),
      TextButton(
        onPressed: () => unawaited(onRetry()),
        child: Text(AppLocalizations.of(context).guideRetry),
      ),
    ],
  );
}

/// "Unirme con un código": pide el código y tu nombre y entra en el grupo.
/// Devuelve el viaje si todo fue bien (null si se cerró sin entrar).
Future<GroupTrip?> showJoinSheet(BuildContext context) =>
    showModalBottomSheet<GroupTrip>(
      context: context,
      // Encima de la barra de abajo (si no, el botón de la cámara lo tapa).
      useRootNavigator: true,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (BuildContext context) => const _JoinSheet(),
    );

class _JoinSheet extends StatefulWidget {
  const _JoinSheet();

  @override
  State<_JoinSheet> createState() => _JoinSheetState();
}

class _JoinSheetState extends State<_JoinSheet> {
  late final AppServices _services = ServicesScope.of(context);
  final TextEditingController _code = TextEditingController();
  late final TextEditingController _name = TextEditingController(
    text: _services.prefs.readGroupName() ?? '',
  );
  String? _problem;
  bool _busy = false;

  @override
  void dispose() {
    _code.dispose();
    _name.dispose();
    super.dispose();
  }

  Future<void> _join() async {
    final AppLocalizations t = AppLocalizations.of(context);
    final String code = _code.text.trim();
    if (code.isEmpty) {
      setState(() => _problem = t.groupRequired);
      return;
    }
    final String name = _name.text.trim();
    setState(() {
      _busy = true;
      _problem = null;
    });
    try {
      final GroupTrip trip = await _services.group.join(
        code,
        myName: name.isEmpty ? null : name,
      );
      if (name.isNotEmpty) await _services.prefs.writeGroupName(name);
      if (mounted) Navigator.of(context).pop(trip);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _problem = switch (e.error) {
          ApiError.notFound || ApiError.invalidInput => t.groupJoinNotFound,
          ApiError.conflict => t.groupJoinClosed,
          ApiError.network => t.errorNetwork,
          ApiError.signedOut => t.groupSignIn,
          _ => t.errorUnavailable,
        };
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    return Padding(
      // Sube con el teclado para que no tape el botón.
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
          Text(t.groupJoinTitle, style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 16),
          TextField(
            controller: _code,
            autofocus: true,
            textCapitalization: TextCapitalization.characters,
            maxLength: 12,
            decoration: InputDecoration(
              labelText: t.groupJoinCodeLabel,
              hintText: t.groupJoinHint,
              errorText: _problem,
              counterText: '',
            ),
            onSubmitted: (_) => unawaited(_join()),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _name,
            maxLength: maxName,
            decoration: InputDecoration(
              labelText: t.groupYourName,
              helperText: t.groupYourNameHelp,
              helperMaxLines: 2,
            ),
          ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: _busy ? null : _join,
            child: _busy
                ? const SizedBox.square(
                    dimension: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Text(t.groupJoinAction),
          ),
        ],
      ),
    );
  }
}
