// Extras de los viajes en grupo (ideas elegidas por DARIO):
//
//   - TripTasks: "Reparto de tareas" (quién reserva qué).
//   - InviteActions: invitar por WhatsApp o enseñando un QR.
//   - Celebration: confeti cuando ya estáis todos.
//   - BigScreen: el viaje en grande, para enseñarlo en la tele.
//   - PlaneProgress: la barra de "quién está listo" con un avioncito.
//   - RulesChips: las reglas del organizador.
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../core/api_client.dart';
import '../../core/money.dart';
import '../../core/services.dart';
import '../../core/theme.dart';
import '../../l10n/generated/app_localizations.dart';
import 'group_api.dart';
import 'group_widgets.dart';

const Color _lilac = Color(0xFFB69CFF);

/// La barra de progreso con un avión que avanza hasta el final.
class PlaneProgress extends StatelessWidget {
  const PlaneProgress({super.key, required this.value, this.height = 26});

  final double value;
  final double height;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: height,
    child: LayoutBuilder(
      builder: (BuildContext context, BoxConstraints box) =>
          TweenAnimationBuilder<double>(
            tween: Tween<double>(end: value.clamp(0, 1)),
            duration: const Duration(milliseconds: 700),
            curve: Curves.easeOutCubic,
            builder: (BuildContext context, double v, Widget? _) {
              final double plane = 22;
              final double x = (box.maxWidth - plane) * v;
              return Stack(
                alignment: Alignment.centerLeft,
                children: <Widget>[
                  // La pista, con rayitas como una pista de aterrizaje.
                  Container(
                    height: 6,
                    decoration: BoxDecoration(
                      color: const Color(0xFF2A2440),
                      borderRadius: BorderRadius.circular(3),
                    ),
                  ),
                  Container(
                    width: x + plane / 2,
                    height: 6,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(3),
                      gradient: const LinearGradient(
                        colors: <Color>[Color(0xFF8A5CF6), Color(0xFFFFB86B)],
                      ),
                    ),
                  ),
                  PositionedDirectional(
                    start: x,
                    // El icono mira hacia arriba: se gira para que vuele.
                    child: Transform.rotate(
                      angle: math.pi / 2,
                      child: const Icon(
                        Icons.flight_rounded,
                        size: 22,
                        color: Color(0xFFFFB86B),
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
    ),
  );
}

/// Las reglas del organizador, en fichas.
class RulesChips extends StatelessWidget {
  const RulesChips({super.key, required this.rules, required this.currency});

  final TripRules rules;
  final String currency;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    final String locale = Localizations.localeOf(context).toLanguageTag();
    final int? max = rules.maxPriceMinor;
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: <Widget>[
        const Icon(Icons.gavel_rounded, size: 16, color: Color(0xFFFFB86B)),
        if (max != null)
          _chip(
            t.groupRulesMaxShown(
              formatMoney(max, currency, locale, compact: true),
            ),
          ),
        for (final String a in rules.avoid) _chip('🚫 ${tagLabel(t, a)}'),
      ],
    );
  }

  Widget _chip(String text) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
    decoration: BoxDecoration(
      color: const Color(0x22FFB86B),
      borderRadius: BorderRadius.circular(20),
      border: Border.all(color: const Color(0x66FFB86B)),
    ),
    child: Text(
      text,
      style: const TextStyle(
        fontSize: 12.5,
        fontWeight: FontWeight.w700,
        color: Color(0xFFFFD9A8),
      ),
    ),
  );
}

/// Invitar: por WhatsApp (con el código ya escrito) o enseñando un QR.
class InviteActions extends StatelessWidget {
  const InviteActions({super.key, required this.code});

  final String code;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    final AppServices services = ServicesScope.of(context);
    final String nice = formatInviteCode(code);
    return Row(
      children: <Widget>[
        Expanded(
          child: FilledButton.icon(
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFF25D366),
              foregroundColor: const Color(0xFF06210F),
            ),
            onPressed: () => services.openLink(
              Uri.https('wa.me', '/', <String, String>{
                'text': t.groupInviteMessage(nice),
              }),
            ),
            icon: const Icon(Icons.chat_rounded),
            label: Text(t.groupInviteWhatsApp),
          ),
        ),
        const SizedBox(width: 10),
        // El tema da a los botones todo el ancho: aquí cada uno su mitad.
        Expanded(
          child: OutlinedButton.icon(
            onPressed: () => showDialog<void>(
              context: context,
              builder: (BuildContext context) => AlertDialog(
                backgroundColor: Colors.white,
                content: SizedBox(
                  width: 240,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      QrImageView(
                        data: nice,
                        size: 220,
                        backgroundColor: Colors.white,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        nice,
                        style: const TextStyle(
                          color: Colors.black,
                          fontSize: 26,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 2,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            icon: const Icon(Icons.qr_code_2_rounded),
            label: Text(t.groupInviteQr),
          ),
        ),
      ],
    );
  }
}

/// Confeti que cae una vez (cuando ya estáis todos).
class Celebration extends StatefulWidget {
  const Celebration({super.key, required this.text});

  final String text;

  @override
  State<Celebration> createState() => _CelebrationState();
}

class _CelebrationState extends State<Celebration>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2600),
  );
  final List<_Bit> _bits = List<_Bit>.generate(60, _Bit.random);

  @override
  void initState() {
    super.initState();
    unawaited(_c.forward());
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: AnimatedBuilder(
      animation: _c,
      builder: (BuildContext context, Widget? _) {
        if (_c.isCompleted) return const SizedBox.shrink();
        final double fade = _c.value < 0.8 ? 1 : (1 - _c.value) / 0.2;
        return Opacity(
          opacity: fade.clamp(0, 1),
          child: Stack(
            children: <Widget>[
              Positioned.fill(
                child: CustomPaint(painter: _Confetti(_bits, _c.value)),
              ),
              Align(
                alignment: const Alignment(0, -0.35),
                child: Transform.scale(
                  scale: Curves.elasticOut.transform(
                    (_c.value * 2.5).clamp(0, 1),
                  ),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 22,
                      vertical: 12,
                    ),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(30),
                      gradient: const LinearGradient(
                        colors: <Color>[Color(0xFF8A5CF6), Color(0xFFFF8FD8)],
                      ),
                      boxShadow: const <BoxShadow>[
                        BoxShadow(color: Color(0x668A5CF6), blurRadius: 24),
                      ],
                    ),
                    child: Text(
                      '🎉 ${widget.text}',
                      style: const TextStyle(
                        fontFamily: NomadFonts.display,
                        fontWeight: FontWeight.w800,
                        fontSize: 20,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    ),
  );
}

class _Bit {
  _Bit(this.x, this.delay, this.speed, this.spin, this.color, this.size);

  factory _Bit.random(int i) {
    final math.Random r = math.Random(i * 7919);
    const List<Color> colors = <Color>[
      Color(0xFF8A5CF6),
      Color(0xFFB69CFF),
      Color(0xFFFFB86B),
      Color(0xFF3DDC97),
      Color(0xFFFF8FD8),
      Color(0xFF6CA8FF),
    ];
    return _Bit(
      r.nextDouble(),
      r.nextDouble() * 0.3,
      0.7 + r.nextDouble() * 0.6,
      (r.nextDouble() - 0.5) * 12,
      colors[i % colors.length],
      5 + r.nextDouble() * 6,
    );
  }

  final double x, delay, speed, spin, size;
  final Color color;
}

class _Confetti extends CustomPainter {
  _Confetti(this.bits, this.t);

  final List<_Bit> bits;
  final double t;

  @override
  void paint(Canvas canvas, Size size) {
    final Paint p = Paint();
    for (final _Bit b in bits) {
      final double k = ((t - b.delay) / (1 - b.delay)).clamp(0, 1);
      if (k <= 0) continue;
      final double y = -20 + (size.height + 40) * k * b.speed;
      final double x = size.width * b.x + math.sin(k * 9 + b.x * 6) * 18;
      canvas
        ..save()
        ..translate(x, y)
        ..rotate(b.spin * k);
      p.color = b.color;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromCenter(
            center: Offset.zero,
            width: b.size,
            height: b.size * 0.5,
          ),
          const Radius.circular(1.5),
        ),
        p,
      );
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(_Confetti old) => old.t != t;
}

/// "Pantalla grande": el viaje en grande, para enseñarlo en la tele.
class BigScreen extends StatelessWidget {
  const BigScreen({super.key, required this.trip});

  final GroupTrip trip;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    final String locale = Localizations.localeOf(context).toLanguageTag();
    final int total = trip.members.length;
    return Scaffold(
      backgroundColor: const Color(0xFF0D0A1A),
      body: SafeArea(
        child: Stack(
          children: <Widget>[
            const Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: RadialGradient(
                    center: Alignment(0, -0.6),
                    radius: 1.2,
                    colors: <Color>[Color(0xFF3A2470), Color(0xFF0D0A1A)],
                  ),
                ),
              ),
            ),
            ListView(
              padding: const EdgeInsets.fromLTRB(28, 56, 28, 28),
              children: <Widget>[
                Text(
                  trip.title,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontFamily: NomadFonts.display,
                    fontWeight: FontWeight.w800,
                    fontSize: 40,
                    height: 1.1,
                  ),
                ),
                const SizedBox(height: 24),
                Center(child: MemberFaces(members: trip.members, size: 64)),
                const SizedBox(height: 18),
                Text(
                  t.groupMembersReady(trip.ready, total),
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 20, color: _lilac),
                ),
                const SizedBox(height: 12),
                PlaneProgress(value: total == 0 ? 0 : trip.ready / total),
                const SizedBox(height: 28),
                for (final TripOption o in trip.options)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Container(
                      padding: const EdgeInsets.all(18),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(22),
                        color: const Color(0x221D1638),
                        border: Border.all(color: const Color(0xFF4A3B80)),
                      ),
                      child: Row(
                        children: <Widget>[
                          Expanded(
                            child: Text(
                              o.label,
                              style: const TextStyle(
                                fontSize: 24,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ),
                          Text(
                            formatMoney(
                              o.priceMinor,
                              trip.currency,
                              locale,
                              compact: true,
                            ),
                            style: const TextStyle(
                              fontSize: 22,
                              fontWeight: FontWeight.w800,
                              color: Color(0xFFFFB86B),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                const SizedBox(height: 16),
                Text(
                  t.groupBigScreenHint,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: NomadColors.textMuted),
                ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.all(8),
              child: IconButton.filledTonal(
                tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
                onPressed: () => Navigator.of(context).maybePop(),
                icon: const Icon(Icons.close_rounded),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// "Reparto de tareas": añadir, "me encargo yo", hecha y quitar.
class TripTasks extends StatefulWidget {
  const TripTasks({super.key, required this.tripId, required this.organizer});

  final String tripId;
  final bool organizer;

  @override
  State<TripTasks> createState() => _TripTasksState();
}

class _TripTasksState extends State<TripTasks> {
  late final AppServices _services = ServicesScope.of(context);
  final TextEditingController _label = TextEditingController();
  List<TripTask>? _tasks;
  bool _busy = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_tasks == null && !_busy) {
      unawaited(_run(() => _services.group.tasks(widget.tripId)));
    }
  }

  @override
  void dispose() {
    _label.dispose();
    super.dispose();
  }

  Future<void> _run(Future<List<TripTask>> Function() call) async {
    if (_busy) return;
    // Sin setState aquí: también se llama al abrir la pantalla.
    _busy = true;
    try {
      final List<TripTask> tasks = await call();
      if (mounted) setState(() => _tasks = tasks);
    } on ApiException catch (e) {
      if (!mounted) return;
      final AppLocalizations t = AppLocalizations.of(context);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            e.error == ApiError.network ? t.errorNetwork : t.errorUnavailable,
          ),
        ),
      );
      _tasks ??= const <TripTask>[];
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _add() async {
    final String label = _label.text.trim();
    if (label.isEmpty) return;
    _label.clear();
    FocusScope.of(context).unfocus();
    await _run(() => _services.group.addTask(widget.tripId, label));
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    final List<TripTask>? tasks = _tasks;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: const Color(0xFF332A55)),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: <Color>[Color(0xFF1F1A36), Color(0xFF15182A)],
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              const Text('📋', style: TextStyle(fontSize: 22)),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  t.groupTasksTitle,
                  style: const TextStyle(
                    fontFamily: NomadFonts.display,
                    fontWeight: FontWeight.w800,
                    fontSize: 18,
                  ),
                ),
              ),
              if (tasks != null && tasks.isNotEmpty)
                Text(
                  '${tasks.where((TripTask x) => x.done).length}/${tasks.length}',
                  style: const TextStyle(
                    color: _lilac,
                    fontWeight: FontWeight.w800,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 10),
          if (tasks == null)
            const Center(
              child: Padding(
                padding: EdgeInsets.all(8),
                child: CircularProgressIndicator(),
              ),
            )
          else if (tasks.isEmpty)
            Text(
              t.groupTasksEmpty,
              style: const TextStyle(color: NomadColors.textMuted),
            )
          else
            for (final TripTask task in tasks) _row(t, task),
          const SizedBox(height: 10),
          TextField(
            controller: _label,
            maxLength: 80,
            textCapitalization: TextCapitalization.sentences,
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => _add(),
            decoration: InputDecoration(
              hintText: t.groupTasksHint,
              counterText: '',
              filled: true,
              fillColor: const Color(0xFF120E1E),
              suffixIcon: IconButton(
                tooltip: t.groupTasksHint,
                onPressed: _busy ? null : _add,
                icon: const Icon(Icons.add_circle_rounded, color: _lilac),
              ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: BorderSide.none,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _row(AppLocalizations t, TripTask task) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Row(
      children: <Widget>[
        Checkbox(
          value: task.done,
          activeColor: NomadColors.mint,
          onChanged: _busy
              ? null
              : (bool? v) => _run(
                  () => _services.group.doneTask(
                    widget.tripId,
                    task.id,
                    v ?? false,
                  ),
                ),
        ),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                task.label,
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  decoration: task.done ? TextDecoration.lineThrough : null,
                  color: task.done ? NomadColors.textMuted : NomadColors.text,
                ),
              ),
              if (task.owner != null)
                Text(
                  task.mine
                      ? '✓ ${t.groupTaskTake}'
                      : t.groupTaskOwner(task.owner!),
                  style: const TextStyle(color: _lilac, fontSize: 12.5),
                ),
            ],
          ),
        ),
        // "Me encargo yo" (otra vez = la sueltas).
        IconButton(
          tooltip: t.groupTaskTake,
          onPressed: _busy
              ? null
              : () => _run(
                  () => _services.group.takeTask(widget.tripId, task.id),
                ),
          icon: Icon(
            task.mine ? Icons.back_hand_rounded : Icons.back_hand_outlined,
            color: task.mine ? NomadColors.mint : _lilac,
          ),
        ),
        if (task.addedByMe || widget.organizer)
          IconButton(
            tooltip: MaterialLocalizations.of(context).deleteButtonTooltip,
            onPressed: _busy
                ? null
                : () => _run(
                    () => _services.group.deleteTask(widget.tripId, task.id),
                  ),
            icon: const Icon(Icons.close_rounded, size: 18),
          ),
      ],
    ),
  );
}
