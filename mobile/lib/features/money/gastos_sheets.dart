// Las hojas de la pantalla de un gasto (maqueta 8):
//   - "Repartir con la mesa": el QR con el código del bote para que los
//     demás entren y marquen lo suyo, y "En vivo · quién ha marcado qué"
//     (se vuelve a preguntar al servidor cada 5 segundos mientras está
//     abierta).
//   - "Escanear QR del ticket": los 4 datos del QR de Hacienda.
//   - El aviso de Flyra que sale abajo ("No cuadra con el ticket").
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../core/motion.dart';
import '../../core/services.dart';
import '../../core/theme.dart';
import '../../l10n/generated/app_localizations.dart';
import '../../features/group/group_api.dart' show formatInviteCode;
import '../../widgets/flyra_avatar.dart';
import 'expenses_api.dart';
import 'gastos_art.dart';
import 'gastos_widgets.dart';
import 'money_widgets.dart';
import 'receipt_parser.dart';
import 'settle_sheet.dart';

const TextStyle _sheetTitle = TextStyle(
  fontFamily: NomadFonts.display,
  fontVariations: <FontVariation>[FontVariation.weight(800)],
  fontSize: 20,
  color: GastosColors.text,
);

// ---------------------------------------------------------------------------
// Repartir con la mesa
// ---------------------------------------------------------------------------

/// Abre "Repartir con la mesa". [reload] vuelve a pedir el gasto.
Future<void> showTableSheet(
  BuildContext context, {
  required ExpenseGroup group,
  required Expense expense,
  required Future<Expense> Function() reload,
}) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  backgroundColor: Colors.transparent,
  barrierColor: const Color(0xCC030608),
  builder: (BuildContext context) =>
      _TableSheet(group: group, expense: expense, reload: reload),
);

class _TableSheet extends StatefulWidget {
  const _TableSheet({
    required this.group,
    required this.expense,
    required this.reload,
  });

  final ExpenseGroup group;
  final Expense expense;
  final Future<Expense> Function() reload;

  @override
  State<_TableSheet> createState() => _TableSheetState();
}

class _TableSheetState extends State<_TableSheet> {
  late final AppServices _services = ServicesScope.of(context);
  late Expense _expense = widget.expense;
  Timer? _timer;
  bool _copied = false;

  @override
  void initState() {
    super.initState();
    // En vivo: cada 5 s se pregunta qué ha marcado cada uno. (En las
    // pruebas no, para que no se quede un reloj encendido.)
    if (Motion.forever) {
      _timer = Timer.periodic(const Duration(seconds: 5), (_) async {
        final Expense fresh = await widget.reload();
        if (mounted) setState(() => _expense = fresh);
      });
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  String get _code => formatInviteCode(widget.group.inviteCode);

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    final ExpenseGroup g = widget.group;
    final List<int> people = _expense.participants.toList()..sort();
    Widget small(
      String label,
      Color bg,
      Color fg,
      Color? border,
      VoidCallback tap,
    ) => Material(
      color: bg,
      shape: StadiumBorder(
        side: border == null ? BorderSide.none : BorderSide(color: border),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: tap,
        child: Container(
          constraints: const BoxConstraints(minHeight: 36),
          padding: const EdgeInsets.symmetric(horizontal: 12),
          alignment: Alignment.center,
          child: Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w800,
              color: fg,
            ),
          ),
        ),
      ),
    );
    return GastosSheet(
      children: <Widget>[
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(t.tableTitle, style: _sheetTitle),
            const SizedBox(height: 6),
            Text(
              t.tableSheetText,
              style: const TextStyle(
                fontSize: 12,
                height: 1.45,
                color: GastosColors.muted,
              ),
            ),
          ],
        ),
        Row(
          children: <Widget>[
            // El QR con el código del bote, con su brillo verde.
            LoopClock(
              period: const Duration(milliseconds: 2400),
              builder: (BuildContext context, double v) {
                final double k = 0.5 - 0.5 * math.cos(v * 2 * math.pi);
                return Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(16),
                    boxShadow: <BoxShadow>[
                      BoxShadow(
                        color: NomadColors.mint.withValues(
                          alpha: 0.2 + 0.13 * k,
                        ),
                        spreadRadius: 4 + 2 * k,
                      ),
                      BoxShadow(
                        color: NomadColors.mint.withValues(
                          alpha: 0.25 + 0.25 * k,
                        ),
                        blurRadius: 18 + 16 * k,
                      ),
                    ],
                  ),
                  child: QrImageView(
                    data: _code,
                    size: 118,
                    padding: EdgeInsets.zero,
                    backgroundColor: Colors.white,
                    eyeStyle: const QrEyeStyle(
                      eyeShape: QrEyeShape.square,
                      color: NomadColors.background,
                    ),
                    dataModuleStyle: const QrDataModuleStyle(
                      dataModuleShape: QrDataModuleShape.square,
                      color: NomadColors.background,
                    ),
                    semanticsLabel: _code,
                  ),
                );
              },
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Container(
                    height: 34,
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    alignment: AlignmentDirectional.centerStart,
                    decoration: BoxDecoration(
                      color: NomadColors.background,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: GastosColors.line),
                    ),
                    child: Text(
                      _code,
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w800,
                        color: Color(0xFF9CC4FF),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  small(
                    _copied ? t.settleCopied : t.tableCopyCode,
                    GastosColors.card,
                    GastosColors.text,
                    const Color(0xFF2B3D47),
                    () async {
                      await Clipboard.setData(
                        ClipboardData(text: g.inviteCode),
                      );
                      if (mounted) setState(() => _copied = true);
                    },
                  ),
                  const SizedBox(height: 8),
                  small(
                    t.tableShare,
                    const Color(0xFF25D366),
                    NomadColors.background,
                    null,
                    () => unawaited(
                      _services.share(
                        const <String>[],
                        text: t.tableShareText(_expense.title, g.title, _code),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        Row(
          children: <Widget>[
            const _LiveDot(),
            const SizedBox(width: 8),
            Text(t.tableLive, style: gastosLabel),
          ],
        ),
        Column(
          children: <Widget>[
            for (final int seat in people)
              _LiveRow(group: g, expense: _expense, seat: seat),
          ],
        ),
        GastosButton(
          label: t.tableDone,
          height: 48,
          fontSize: 14,
          background: GastosColors.text,
          border: null,
          foreground: NomadColors.background,
          onTap: () => Navigator.of(context).pop(),
        ),
      ],
    );
  }
}

/// El punto rojo de "EN VIVO", que late.
class _LiveDot extends StatelessWidget {
  const _LiveDot();

  @override
  Widget build(BuildContext context) => LoopClock(
    period: const Duration(milliseconds: 1200),
    builder: (BuildContext context, double v) => Opacity(
      opacity: 0.35 + 0.65 * (0.5 + 0.5 * math.cos(v * 2 * math.pi)),
      child: Container(
        width: 8,
        height: 8,
        decoration: const BoxDecoration(
          shape: BoxShape.circle,
          color: Color(0xFFFF6B6B),
        ),
      ),
    ),
  );
}

/// Una persona: lo que ya ha marcado (o que aún no ha marcado nada).
class _LiveRow extends StatelessWidget {
  const _LiveRow({
    required this.group,
    required this.expense,
    required this.seat,
  });

  final ExpenseGroup group;
  final Expense expense;
  final int seat;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    final List<String> mine = <String>[
      for (final TicketItem i in expense.items)
        if (i.claimedBy.contains(seat)) i.name,
    ];
    final bool me = seat == group.mySeat;
    final String status = mine.isEmpty
        ? (me ? t.tableNothingMine : t.liveNone)
        : me
        ? t.tableMine('${mine.length}')
        : '${mine.join(', ')} ✓';
    return SizedBox(
      height: 40,
      child: Row(
        children: <Widget>[
          Container(
            width: 32,
            height: 32,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: seatColor(seat),
            ),
            child: Text(
              me
                  ? t.groupYou
                  : group.nameOf(seat).characters.first.toUpperCase(),
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w800,
                color: NomadColors.background,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: <Widget>[
                Text(
                  personName(t, group, seat),
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 350),
                  child: Text(
                    status,
                    key: ValueKey<String>(status),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w800,
                      color: mine.isEmpty
                          ? const Color(0xFF7F9098)
                          : const Color(0xFF9BFFD3),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Escanear QR del ticket
// ---------------------------------------------------------------------------

/// Enseña lo leído del QR. Devuelve true con "Usar estos datos".
Future<bool> showQrSheet(
  BuildContext context, {
  required VeriFactu data,
  required String raw,
}) async =>
    await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: const Color(0xCC030608),
      builder: (BuildContext context) {
        final AppLocalizations t = AppLocalizations.of(context);
        Widget row(String label, String value) => Container(
          height: 33,
          decoration: const BoxDecoration(
            border: Border(bottom: BorderSide(color: Color(0xFF22323B))),
          ),
          child: Row(
            children: <Widget>[
              Text(
                label,
                style: const TextStyle(fontSize: 13, color: GastosColors.muted),
              ),
              const Spacer(),
              Text(
                value,
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
        );
        return GastosSheet(
          children: <Widget>[
            Text(t.gastosScanQr, style: _sheetTitle),
            // El QR que has escaneado, en su visor con esquinas verdes.
            Center(
              child: Container(
                width: 210,
                height: 210,
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: NomadColors.background,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: CustomPaint(
                  foregroundPainter: _Corners(),
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: QrImageView(
                      data: raw,
                      padding: const EdgeInsets.all(6),
                      backgroundColor: Colors.white,
                    ),
                  ),
                ),
              ),
            ),
            Text(
              t.vfTitle,
              style: const TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w800,
                letterSpacing: 0.4,
                color: NomadColors.mint,
              ),
            ),
            Column(
              children: <Widget>[
                row(t.vfNif, data.nif),
                row(t.vfNumber, data.number),
                row(
                  t.vfDate,
                  MaterialLocalizations.of(context).formatShortDate(data.date),
                ),
                row(t.vfTotal, money(context, data.totalMinor, 'EUR')),
              ],
            ),
            Text(
              t.qrSheetNote,
              style: const TextStyle(
                fontSize: 11.5,
                height: 1.45,
                color: GastosColors.muted,
              ),
            ),
            GastosButton(
              label: t.qrUse,
              height: 48,
              fontSize: 14,
              background: GastosColors.text,
              border: null,
              foreground: NomadColors.background,
              onTap: () => Navigator.of(context).pop(true),
            ),
          ],
        );
      },
    ) ??
    false;

/// Las 4 esquinas verdes del visor.
class _Corners extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final Paint p = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.round
      ..color = NomadColors.mint;
    const double l = 26;
    final double w = size.width, h = size.height;
    canvas
      ..drawPath(
        Path()
          ..moveTo(0, l)
          ..lineTo(0, 0)
          ..lineTo(l, 0),
        p,
      )
      ..drawPath(
        Path()
          ..moveTo(w - l, 0)
          ..lineTo(w, 0)
          ..lineTo(w, l),
        p,
      )
      ..drawPath(
        Path()
          ..moveTo(0, h - l)
          ..lineTo(0, h)
          ..lineTo(l, h),
        p,
      )
      ..drawPath(
        Path()
          ..moveTo(w - l, h)
          ..lineTo(w, h)
          ..lineTo(w, h - l),
        p,
      );
  }

  @override
  bool shouldRepaint(_Corners old) => false;
}

// ---------------------------------------------------------------------------
// El aviso de Flyra de abajo
// ---------------------------------------------------------------------------

class FlyraAlert extends StatelessWidget {
  const FlyraAlert({
    super.key,
    required this.title,
    required this.text,
    required this.button,
    required this.onClose,
  });

  final String title;
  final String text;
  final String button;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) => TweenAnimationBuilder<double>(
    tween: Tween<double>(begin: 0, end: 1),
    duration: const Duration(milliseconds: 500),
    curve: const Cubic(0.2, 0.9, 0.3, 1.2),
    builder: (BuildContext context, double v, Widget? child) => Opacity(
      opacity: v.clamp(0, 1),
      child: Transform.translate(
        offset: Offset(0, 24 * (1 - v)),
        child: Transform.scale(scale: 0.94 + 0.06 * v, child: child),
      ),
    ),
    child: Semantics(
      liveRegion: true,
      child: Stack(
        clipBehavior: Clip.none,
        children: <Widget>[
          Container(
            margin: const EdgeInsetsDirectional.only(end: 40),
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: GastosColors.card,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: const Color(0xFF2B3D47)),
              boxShadow: const <BoxShadow>[
                BoxShadow(
                  color: Color(0x99000000),
                  blurRadius: 30,
                  offset: Offset(0, 12),
                ),
              ],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Padding(
                      padding: const EdgeInsets.only(top: 5),
                      child: LoopClock(
                        period: const Duration(milliseconds: 1200),
                        builder: (BuildContext context, double v) => Opacity(
                          opacity:
                              0.35 +
                              0.65 * (0.5 + 0.5 * math.cos(v * 2 * math.pi)),
                          child: Container(
                            width: 10,
                            height: 10,
                            decoration: const BoxDecoration(
                              shape: BoxShape.circle,
                              color: Color(0xFFFF6B6B),
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Text(
                            title,
                            style: const TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            text,
                            style: const TextStyle(
                              fontSize: 12.5,
                              height: 1.4,
                              color: Color(0xFFCFE0E6),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                GastosButton(
                  label: button,
                  height: 40,
                  background: const Color(0xFFFF6B6B),
                  border: null,
                  foreground: NomadColors.background,
                  onTap: onClose,
                ),
              ],
            ),
          ),
          PositionedDirectional(
            end: 0,
            bottom: -6,
            child: TweenAnimationBuilder<double>(
              tween: Tween<double>(begin: 0, end: 1),
              duration: const Duration(milliseconds: 700),
              curve: Curves.easeOutBack,
              builder: (BuildContext context, double v, Widget? c) =>
                  Transform.rotate(
                    angle: (1 - v) * -0.5,
                    child: Transform.scale(scale: 0.4 + 0.6 * v, child: c),
                  ),
              child: Container(
                width: 54,
                height: 54,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: NomadColors.background,
                  border: Border.all(color: NomadColors.mint, width: 2),
                ),
                child: const ClipOval(child: FlyraAvatar(size: 50)),
              ),
            ),
          ),
        ],
      ),
    ),
  );
}
