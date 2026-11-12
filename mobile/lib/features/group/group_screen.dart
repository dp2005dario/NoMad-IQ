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
import '../reels/reels.dart';
import 'group_api.dart';
import 'group_extras.dart';
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
      body: DecoratedBox(
        // Un cielo violeta arriba, como la tarjeta de Flyra.
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            stops: <double>[0, 0.45],
            colors: <Color>[Color(0xFF1D1638), NomadColors.background],
          ),
        ),
        child: SafeArea(
          child: RefreshIndicator(
            onRefresh: _load,
            child: ListView(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 120),
              children: <Widget>[
                Text(
                  t.groupTitle,
                  style: text.headlineMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 14),
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
                  Row(
                    children: <Widget>[
                      Expanded(
                        child: _BigAction(
                          icon: Icons.add_rounded,
                          label: t.groupNew,
                          filled: true,
                          onTap: _create,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: _BigAction(
                          icon: Icons.vpn_key_rounded,
                          label: t.groupJoin,
                          filled: false,
                          onTap: _join,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 22),
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
                    for (int i = 0; i < trips.length; i++) ...<Widget>[
                      _Appear(
                        delay: i,
                        child: _TripCard(
                          trip: trips[i],
                          onTap: () => _open(trips[i].id),
                        ),
                      ),
                      const SizedBox(height: 12),
                    ],
                  const SizedBox(height: 10),
                  // "¿No se te ocurren planes?": vídeos cortos de viajes.
                  Row(
                    children: <Widget>[
                      const Text('🎬', style: TextStyle(fontSize: 20)),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          t.groupPlansTitle,
                          style: const TextStyle(
                            fontFamily: NomadFonts.display,
                            fontWeight: FontWeight.w800,
                            fontSize: 18,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  PlanReels(
                    place: trips != null && trips.isNotEmpty
                        ? _destination(trips.first)
                        : '',
                  ),
                  const SizedBox(height: 22),
                  _TrailerBox(
                    title: t.groupTrailerTitle,
                    text: t.groupTrailerSoon,
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A dónde va un viaje: la opción elegida o, mientras se decide, su nombre.
String _destination(GroupTrip trip) =>
    trip.option(trip.result?.chosenOptionId)?.label ?? trip.title;

/// Entra deslizándose un poco (cada tarjeta un pelín después que la anterior).
class _Appear extends StatelessWidget {
  const _Appear({required this.delay, required this.child});

  final int delay;
  final Widget child;

  @override
  Widget build(BuildContext context) => TweenAnimationBuilder<double>(
    tween: Tween<double>(begin: 0, end: 1),
    duration: MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : Duration(milliseconds: 420 + 90 * delay.clamp(0, 6)),
    curve: Curves.easeOutCubic,
    builder: (BuildContext context, double v, Widget? c) => Opacity(
      opacity: v,
      child: Transform.translate(offset: Offset(0, 18 * (1 - v)), child: c),
    ),
    child: child,
  );
}

/// Los dos botones grandes: "Nuevo viaje" (lleno) y "Unirme" (con borde).
class _BigAction extends StatelessWidget {
  const _BigAction({
    required this.icon,
    required this.label,
    required this.filled,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool filled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    child: Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(22),
        onTap: onTap,
        child: Ink(
          height: 92,
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(22),
            gradient: filled
                ? const LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: <Color>[Color(0xFF8A5CF6), Color(0xFFB69CFF)],
                  )
                : null,
            color: filled ? null : const Color(0xFF17142A),
            border: filled ? null : Border.all(color: const Color(0xFF3E3163)),
            boxShadow: filled
                ? const <BoxShadow>[
                    BoxShadow(
                      color: Color(0x558A5CF6),
                      blurRadius: 18,
                      offset: Offset(0, 8),
                    ),
                  ]
                : null,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: <Widget>[
              Icon(
                icon,
                color: filled ? const Color(0xFF120C24) : NomadColors.group,
              ),
              Text(
                label,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize: 14.5,
                  height: 1.15,
                  color: filled ? const Color(0xFF120C24) : NomadColors.text,
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

/// La tarjeta violeta de Flyra que explica la idea en dos líneas.
class _Intro extends StatelessWidget {
  const _Intro({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      gradient: const LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: <Color>[Color(0xFF2A1F52), Color(0xFF1A1530)],
      ),
      borderRadius: BorderRadius.circular(24),
      border: Border.all(color: const Color(0xFF4A3B80)),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        const FlyraAvatar(size: 46),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            text,
            style: const TextStyle(color: Color(0xFFE6DEFF), height: 1.45),
          ),
        ),
      ],
    ),
  );
}

/// La tarjeta de un viaje, con la foto del destino de fondo (Wikipedia) y
/// las caras del grupo encima.
class _TripCard extends StatefulWidget {
  const _TripCard({required this.trip, required this.onTap});

  final GroupTrip trip;
  final VoidCallback onTap;

  @override
  State<_TripCard> createState() => _TripCardState();
}

class _TripCardState extends State<_TripCard> {
  Uri? _photo;
  String? _asked;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    unawaited(_loadPhoto());
  }

  @override
  void didUpdateWidget(_TripCard old) {
    super.didUpdateWidget(old);
    unawaited(_loadPhoto());
  }

  Future<void> _loadPhoto() async {
    final String place = _destination(widget.trip);
    if (_asked == place) return;
    _asked = place;
    final Uri? photo = await ServicesScope.of(context).reels
        .photo(place, Localizations.localeOf(context).languageCode);
    if (mounted && _asked == place) setState(() => _photo = photo);
  }

  @override
  Widget build(BuildContext context) {
    final GroupTrip trip = widget.trip;
    final VoidCallback onTap = widget.onTap;
    final Uri? photo = _photo;
    final TextTheme text = Theme.of(context).textTheme;
    final TripOption? chosen = trip.option(trip.result?.chosenOptionId);
    final int total = trip.members.length;
    // Cuántos han mandado sus gustos (si vas solo, con Flyra ya estáis).
    final double progress = total == 0 ? 0 : trip.ready / total;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(24),
        onTap: onTap,
        child: Ink(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(24),
            gradient: const LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: <Color>[Color(0xFF1F1A36), Color(0xFF141E25)],
            ),
            // La foto del destino, oscurecida para que se lea el texto.
            image: photo == null
                ? null
                : DecorationImage(
                    image: NetworkImage(photo.toString()),
                    fit: BoxFit.cover,
                    onError: (Object _, StackTrace? _) {},
                    colorFilter: const ColorFilter.mode(
                      Color(0xAA0D0A1A),
                      BlendMode.darken,
                    ),
                  ),
            border: Border.all(color: const Color(0xFF332A55)),
          ),
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Container(
                    width: 42,
                    height: 42,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(14),
                      color: NomadColors.group.withValues(alpha: 0.16),
                    ),
                    child: const Icon(
                      Icons.luggage_rounded,
                      color: NomadColors.group,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          trip.title,
                          style: text.titleLarge?.copyWith(
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        if (chosen != null)
                          Text(
                            chosen.label,
                            style: const TextStyle(
                              color: NomadColors.group,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                      ],
                    ),
                  ),
                  const Icon(Icons.chevron_right_rounded),
                ],
              ),
              const SizedBox(height: 14),
              Row(
                children: <Widget>[
                  MemberFaces(members: trip.members, size: 34),
                  const Spacer(),
                  TripStatusChip(trip: trip),
                ],
              ),
              if (trip.status == TripStatus.collecting &&
                  total > 1) ...<Widget>[
                const SizedBox(height: 12),
                PlaneProgress(value: progress),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// El hueco del tráiler del viaje (el vídeo llegará más adelante).
class _TrailerBox extends StatelessWidget {
  const _TrailerBox({required this.title, required this.text});

  final String title;
  final String text;

  @override
  Widget build(BuildContext context) => AspectRatio(
    aspectRatio: 16 / 9,
    child: Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(24),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: <Color>[Color(0xFF3A2470), Color(0xFF0F2A44)],
        ),
        border: Border.all(color: const Color(0xFF4A3B80)),
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            title,
            style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 17),
          ),
          const Spacer(),
          Center(
            child: Container(
              width: 58,
              height: 58,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.white.withValues(alpha: 0.14),
                border: Border.all(color: Colors.white54, width: 2),
              ),
              child: const Icon(
                Icons.play_arrow_rounded,
                size: 34,
                color: Colors.white,
              ),
            ),
          ),
          const Spacer(),
          Text(
            text,
            style: const TextStyle(color: Color(0xFFD6CCF5), fontSize: 12.5),
          ),
        ],
      ),
    ),
  );
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
