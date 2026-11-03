// El SOS de Inicio (maqueta: "cuarto de acero" con el poste de emergencia).
//
// Cómo funciona:
//   1. Mantienes pulsada la seta roja 2 segundos (una barra se va llenando;
//      si sueltas antes, no pasa nada).
//   2. El cuarto se pone en ALARMA (luz roja que parpadea) y sale una cuenta
//      atrás de 5 segundos con un botón grande CANCELAR.
//   3. Al llegar a 0 se abre la pantalla SOS ya activada: llamar al número
//      de emergencias de donde estás y mandar tu ubicación a tus contactos.
//
// Debajo, tus contactos de emergencia (los de verdad, guardados en el móvil).
// El dibujo del cuarto es el mismo de la maqueta (assets/inicio/sos_cuarto.svg).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:go_router/go_router.dart';

import '../../core/router.dart';
import '../../core/services.dart';
import '../../core/theme.dart';
import '../../l10n/generated/app_localizations.dart';
import '../sos/sos_store.dart';

/// Cuánto hay que mantener la seta.
const Duration homeSosHold = Duration(seconds: 2);

/// Segundos de la cuenta atrás antes de avisar.
const int homeSosCountdown = 5;

class HomeSos extends StatefulWidget {
  const HomeSos({super.key});

  @override
  State<HomeSos> createState() => _HomeSosState();
}

class _HomeSosState extends State<HomeSos> with TickerProviderStateMixin {
  late final AnimationController _hold = AnimationController(
    vsync: this,
    duration: homeSosHold,
  )..addStatusListener(_onHold);

  // La luz de alarma: parpadea mientras dura la cuenta atrás.
  late final AnimationController _alarm = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 600),
  );
  Timer? _tick;
  int? _left;

  @override
  void dispose() {
    _tick?.cancel();
    _hold.dispose();
    _alarm.dispose();
    super.dispose();
  }

  void _onHold(AnimationStatus s) {
    if (s != AnimationStatus.completed) return;
    unawaited(HapticFeedback.heavyImpact());
    setState(() => _left = homeSosCountdown);
    if (!MediaQuery.disableAnimationsOf(context)) {
      // 5 s de parpadeo (no infinito).
      unawaited(_alarm.repeat(reverse: true, count: homeSosCountdown * 2));
    }
    _tick = Timer.periodic(const Duration(seconds: 1), (Timer t) {
      if (!mounted) return t.cancel();
      final int left = (_left ?? 1) - 1;
      if (left <= 0) {
        t.cancel();
        _reset();
        unawaited(context.push(Routes.sosArmed));
      } else {
        setState(() => _left = left);
      }
    });
  }

  void _reset() {
    _tick?.cancel();
    _alarm.stop();
    _alarm.value = 0;
    _hold.value = 0;
    setState(() => _left = null);
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    final AppServices services = ServicesScope.of(context);
    final List<SosContact> contacts = loadContacts(services.prefs);
    final int? left = _left;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        ClipRRect(
          borderRadius: BorderRadius.circular(22),
          child: AspectRatio(
            aspectRatio: 360 / 440,
            child: Stack(
              fit: StackFit.expand,
              children: <Widget>[
                SvgPicture.asset(
                  'assets/inicio/sos_cuarto.svg',
                  fit: BoxFit.cover,
                  excludeFromSemantics: true,
                ),
                // La alarma: el cuarto se tiñe de rojo y parpadea.
                IgnorePointer(
                  child: AnimatedBuilder(
                    animation: _alarm,
                    builder: (BuildContext context, Widget? _) => ColoredBox(
                      color: const Color(0xFFFF1A1A).withValues(
                        alpha: left == null ? 0 : 0.15 + 0.35 * _alarm.value,
                      ),
                    ),
                  ),
                ),
                // La zona que se pulsa: encima de la seta del poste.
                Align(
                  alignment: const Alignment(0, 0.11),
                  child: FractionallySizedBox(
                    widthFactor: 0.62,
                    heightFactor: 0.5,
                    child: Semantics(
                      key: const ValueKey<String>('homeSosHold'),
                      button: true,
                      label: t.homeSosHold,
                      // Listener (y no GestureDetector): así el dedo
                      // puede quedarse quieto los 2 s sin que otro gesto
                      // "gane" y lo cancele a medias.
                      child: Listener(
                        behavior: HitTestBehavior.opaque,
                        onPointerDown: (_) {
                          if (left == null) unawaited(_hold.forward());
                        },
                        onPointerUp: (_) => _letGo(),
                        onPointerCancel: (_) => _letGo(),
                      ),
                    ),
                  ),
                ),
                // La barra que se llena mientras mantienes.
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  height: 5,
                  child: AnimatedBuilder(
                    animation: _hold,
                    builder: (BuildContext context, Widget? _) =>
                        LinearProgressIndicator(
                          value: _hold.value,
                          backgroundColor: const Color(0xFF0A1015),
                          color: const Color(0xFFFF3B30),
                        ),
                  ),
                ),
                if (left != null)
                  _Countdown(
                    left: left,
                    hint: t.homeSosCancelHint,
                    title: t.homeSosIn,
                    cancel: t.homeSosCancel,
                    onCancel: _reset,
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 10),
        Text(
          t.homeSosHold,
          textAlign: TextAlign.center,
          style: const TextStyle(
            color: Color(0xFFFF8A65),
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          t.homeSosWarn,
          textAlign: TextAlign.center,
          style: const TextStyle(color: NomadColors.textMuted, fontSize: 12),
        ),
        const SizedBox(height: 16),
        _Contacts(
          title: t.homeSosContacts,
          more: t.homeSosMore,
          empty: t.sosNoContacts,
          contacts: contacts,
          onMore: () => context.push(Routes.sos),
        ),
      ],
    );
  }

  void _letGo() {
    // Soltar antes de tiempo: la barra vuelve a cero y no pasa nada.
    if (_hold.status != AnimationStatus.completed) unawaited(_hold.reverse());
  }
}

/// "Si no es una emergencia real, cancela · Avisando en 5 · CANCELAR".
class _Countdown extends StatelessWidget {
  const _Countdown({
    required this.left,
    required this.hint,
    required this.title,
    required this.cancel,
    required this.onCancel,
  });

  final int left;
  final String hint;
  final String title;
  final String cancel;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: const Color(0xCC1A0505),
    child: Semantics(
      liveRegion: true,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: <Widget>[
          Text(hint, style: const TextStyle(color: Colors.white70)),
          const SizedBox(height: 8),
          Text(
            title,
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
          ),
          Text(
            '$left',
            style: const TextStyle(
              fontSize: 72,
              fontWeight: FontWeight.w800,
              color: Color(0xFFFF5A4A),
            ),
          ),
          const SizedBox(height: 8),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Colors.white,
              foregroundColor: const Color(0xFFB3260E),
              padding: const EdgeInsets.symmetric(horizontal: 36, vertical: 16),
            ),
            onPressed: onCancel,
            child: Text(
              cancel,
              style: const TextStyle(fontWeight: FontWeight.w800),
            ),
          ),
        ],
      ),
    ),
  );
}

/// Tus contactos de emergencia (hasta 3 a la vista) y "Más contactos".
class _Contacts extends StatelessWidget {
  const _Contacts({
    required this.title,
    required this.more,
    required this.empty,
    required this.contacts,
    required this.onMore,
  });

  final String title;
  final String more;
  final String empty;
  final List<SosContact> contacts;
  final VoidCallback onMore;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: const Color(0xFFF4F8F6),
      borderRadius: BorderRadius.circular(24),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Text(
          title,
          style: const TextStyle(
            color: Color(0xFF12212B),
            fontSize: 19,
            fontWeight: FontWeight.w800,
          ),
        ),
        const SizedBox(height: 10),
        if (contacts.isEmpty)
          Text(empty, style: const TextStyle(color: Color(0xFF5A6D75)))
        else
          for (final SosContact c in contacts.take(3))
            Container(
              margin: const EdgeInsets.only(bottom: 8),
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: const Color(0xFFDBE5E2)),
              ),
              child: Row(
                children: <Widget>[
                  // Su inicial (la app no tiene fotos de tus contactos).
                  CircleAvatar(
                    radius: 22,
                    backgroundColor: const Color(0xFF3DDC97),
                    foregroundColor: const Color(0xFF0B1217),
                    child: Text(
                      c.name.isEmpty ? '?' : c.name[0].toUpperCase(),
                      style: const TextStyle(fontWeight: FontWeight.w800),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          c.name,
                          style: const TextStyle(
                            color: Color(0xFF12212B),
                            fontWeight: FontWeight.w700,
                            fontSize: 16,
                          ),
                        ),
                        Text(
                          c.phone,
                          style: const TextStyle(
                            color: Color(0xFF5A6D75),
                            fontSize: 13,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
        const SizedBox(height: 4),
        OutlinedButton(
          style: OutlinedButton.styleFrom(
            foregroundColor: const Color(0xFF44565F),
            side: const BorderSide(color: Color(0xFFB9C6C2)),
          ),
          onPressed: onMore,
          child: Text(more),
        ),
      ],
    ),
  );
}
