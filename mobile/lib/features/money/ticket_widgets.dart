// Piezas de la pantalla de Gastos que se usan en varios sitios (maqueta 8):
//   - El aviso de Flyra ("No cuadra con el ticket").
//   - Los datos del QR VeriFactu de Hacienda.
//   - "Lo que paga cada uno", con una barra por persona.
import 'package:flutter/material.dart';

import '../../core/theme.dart';
import '../../l10n/generated/app_localizations.dart';
import '../../widgets/flyra_avatar.dart';
import 'expenses_api.dart';
import 'money_widgets.dart';
import 'receipt_parser.dart';

/// Un aviso de Flyra con su foto, un título y botones debajo.
class FlyraMoneyNote extends StatelessWidget {
  const FlyraMoneyNote({
    super.key,
    required this.title,
    required this.text,
    this.actions = const <Widget>[],
    this.color = NomadColors.money,
  });

  final String title;
  final String text;
  final List<Widget> actions;
  final Color color;

  @override
  Widget build(BuildContext context) => TweenAnimationBuilder<double>(
    // Entra creciendo un poco, para que se vea que es nuevo.
    tween: Tween<double>(begin: 0.92, end: 1),
    duration: const Duration(milliseconds: 380),
    curve: Curves.easeOutBack,
    builder: (_, double s, Widget? child) =>
        Transform.scale(scale: s, child: child),
    child: Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: <Color>[
            color.withValues(alpha: 0.18),
            NomadColors.surface.withValues(alpha: 0.9),
          ],
        ),
        border: Border.all(color: color.withValues(alpha: 0.55)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              const FlyraAvatar(size: 36),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      title,
                      style: TextStyle(
                        fontWeight: FontWeight.w800,
                        color: color,
                        fontSize: 15,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(text, style: const TextStyle(height: 1.35)),
                  ],
                ),
              ),
            ],
          ),
          if (actions.isNotEmpty) ...<Widget>[
            const SizedBox(height: 10),
            Wrap(spacing: 8, runSpacing: 8, children: actions),
          ],
        ],
      ),
    ),
  );
}

/// "Leído del QR VeriFactu": los 4 datos que trae el QR de Hacienda.
class VeriFactuCard extends StatelessWidget {
  const VeriFactuCard({super.key, required this.data, required this.onCheck});

  final VeriFactu data;

  /// Abre el enlace de Hacienda para comprobar la factura.
  final VoidCallback onCheck;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    Widget row(String label, String value) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Text(
              label,
              style: const TextStyle(color: NomadColors.textMuted),
            ),
          ),
          Text(value, style: const TextStyle(fontWeight: FontWeight.w800)),
        ],
      ),
    );
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: NomadColors.surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: NomadColors.mint.withValues(alpha: 0.5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              const Icon(Icons.qr_code_2_rounded, color: NomadColors.mint),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  t.vfTitle,
                  style: const TextStyle(
                    fontWeight: FontWeight.w800,
                    color: NomadColors.mint,
                    fontSize: 12.5,
                    letterSpacing: 0.4,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          row(t.vfNif, data.nif),
          row(t.vfNumber, data.number),
          row(
            t.vfDate,
            MaterialLocalizations.of(context).formatShortDate(data.date),
          ),
          row(t.vfTotal, money(context, data.totalMinor, 'EUR')),
          const SizedBox(height: 6),
          Text(
            t.vfHelp,
            style: const TextStyle(color: NomadColors.textMuted, fontSize: 12),
          ),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton.icon(
              style: TextButton.styleFrom(minimumSize: const Size(64, 40)),
              icon: const Icon(Icons.verified_rounded, size: 18),
              label: Text(t.vfCheck),
              onPressed: onCheck,
            ),
          ),
        ],
      ),
    );
  }
}

/// "Lo que paga cada uno": una fila por persona con una barra que crece.
class SharesBars extends StatelessWidget {
  const SharesBars({
    super.key,
    required this.group,
    required this.shares,
    this.payerSeat,
  });

  final ExpenseGroup group;
  final Map<int, int> shares;

  /// Quien pagó: a su lado se pone "pagó".
  final int? payerSeat;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    final int most = shares.values.fold(1, (int a, int b) => a > b ? a : b);
    final List<int> seats = shares.keys.toList()..sort();
    return Column(
      children: <Widget>[
        for (final int seat in seats)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 5),
            child: Row(
              children: <Widget>[
                SeatAvatar(
                  seat: seat,
                  name: personName(t, group, seat),
                  size: 32,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Row(
                        children: <Widget>[
                          Expanded(
                            child: Row(
                              children: <Widget>[
                                Flexible(
                                  child: Text(
                                    personName(t, group, seat),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontWeight: seat == group.mySeat
                                          ? FontWeight.w800
                                          : FontWeight.w600,
                                    ),
                                  ),
                                ),
                                if (seat == payerSeat)
                                  Container(
                                    margin: const EdgeInsetsDirectional.only(
                                      start: 6,
                                    ),
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 7,
                                      vertical: 1,
                                    ),
                                    decoration: BoxDecoration(
                                      color: NomadColors.money.withValues(
                                        alpha: 0.18,
                                      ),
                                      borderRadius: BorderRadius.circular(10),
                                    ),
                                    child: Text(
                                      t.paidTag,
                                      style: const TextStyle(
                                        fontSize: 10.5,
                                        fontWeight: FontWeight.w800,
                                        color: NomadColors.money,
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                          // El importe cambia con una pequeña animación.
                          AnimatedSwitcher(
                            duration: const Duration(milliseconds: 250),
                            transitionBuilder: (
                              Widget child,
                              Animation<double> a,
                            ) => ScaleTransition(scale: a, child: child),
                            child: Text(
                              money(context, shares[seat]!, group.currency),
                              key: ValueKey<int>(shares[seat]!),
                              style: TextStyle(
                                fontWeight: FontWeight.w800,
                                color: seat == group.mySeat
                                    ? NomadColors.money
                                    : NomadColors.text,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      TweenAnimationBuilder<double>(
                        tween: Tween<double>(end: shares[seat]! / most),
                        duration: const Duration(milliseconds: 450),
                        curve: Curves.easeOutCubic,
                        builder: (_, double v, _) => ClipRRect(
                          borderRadius: BorderRadius.circular(4),
                          child: LinearProgressIndicator(
                            value: v,
                            minHeight: 6,
                            color: seatColor(seat),
                            backgroundColor: NomadColors.surfaceHigh,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}
