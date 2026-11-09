// El datáfono que "imprime" el ticket, como en la maqueta 8:
//   1. El datáfono vibra y su luz verde parpadea mientras sale el papel a
//      saltitos (2,7 s).
//   2. El papel se "arranca": baja un poco y se tuerce.
//   3. Una raya verde lo recorre de arriba abajo (Flyra leyendo).
//   4. Aparecen el recuadro de las líneas, el círculo de quién tomó cada una
//      y la etiqueta "N LÍNEAS DETECTADAS".
//
// Todo va con un solo reloj ([TicketPrinter.clock], de 0 a 1 en
// [TicketPrinter.length]): la pantalla lo vuelve a empezar con "Volver a
// imprimir".
//
// En el papel solo sale lo que de verdad sabemos del gasto: el nombre, el
// día, cuántos sois, las líneas, el pan y cubierto, el descuento y el total.
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../core/money.dart';
import '../../l10n/generated/app_localizations.dart';
import 'expenses_api.dart';
import 'gastos_art.dart';
import 'money_widgets.dart';

/// "12,00" (sin símbolo), como lo escribe una caja registradora.
String ticketNumber(BuildContext context, int minor, String currency) {
  final int digits = currencyDigits(currency);
  return NumberFormat.decimalPatternDigits(
    locale: Localizations.localeOf(context).toLanguageTag(),
    decimalDigits: digits,
  ).format(minor / math.pow(10, digits));
}

/// Cuánto vale [t] (segundos) dentro de una animación que empieza en
/// [start] y dura [length]: 0 antes, 1 después.
double _between(double t, double start, double length) =>
    ((t - start) / length).clamp(0, 1);

/// El "pop" de la maqueta: crece desde 0,4 hasta 1,08 y se queda en 1.
Widget popIn(double k, Widget child) {
  if (k <= 0) return Opacity(opacity: 0, child: child);
  final double s = k < 0.7
      ? 0.4 + (1.08 - 0.4) * Curves.ease.transform((k / 0.7).clamp(0.0, 1.0))
      : 1.08 - 0.08 * Curves.ease.transform(((k - 0.7) / 0.3).clamp(0.0, 1.0));
  return Opacity(
    opacity: (k / 0.7).clamp(0, 1),
    child: Transform.scale(scale: s, child: child),
  );
}

/// Quién tomó una línea: "Todos" o las iniciales.
class LineChip extends StatelessWidget {
  const LineChip({super.key, required this.group, required this.owners});

  final ExpenseGroup group;

  /// Vacía = todos.
  final List<int> owners;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    Widget chip(String text, Color color) => Container(
      height: 20,
      padding: const EdgeInsets.symmetric(horizontal: 7),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        text,
        style: const TextStyle(
          fontFamily: 'Manrope',
          fontSize: 10,
          fontWeight: FontWeight.w800,
          color: Color(0xFF0B1217),
          height: 1,
        ),
      ),
    );
    if (owners.isEmpty) return chip(t.moneyEveryone, const Color(0xFF3DDC97));
    return Wrap(
      spacing: 2,
      children: <Widget>[
        for (final int s in owners.take(3))
          chip(group.nameOf(s).characters.first.toUpperCase(), seatColor(s)),
      ],
    );
  }
}

class TicketPrinter extends StatelessWidget {
  const TicketPrinter({
    super.key,
    required this.clock,
    required this.group,
    required this.expense,
  });

  /// Cuánto dura todo, en segundos.
  static const double length = 5.2;

  /// De 0 a 1 en [length] segundos.
  final Animation<double> clock;
  final ExpenseGroup group;
  final Expense expense;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (BuildContext context, BoxConstraints box) {
      final double width = math.min(358, box.maxWidth);
      return AnimatedBuilder(
        animation: clock,
        builder: (BuildContext context, _) {
          final double t = clock.value * length;
          return Column(
            children: <Widget>[
              _Machine(t: t, width: width, total: expense, group: group),
              // El papel sale por debajo de la ranura (empieza 26 px más
              // arriba, escondido detrás del datáfono).
              Transform.translate(
                offset: const Offset(0, -26),
                child: ClipRect(
                  clipper: const _BelowSlot(),
                  child: _Paper(
                    t: t,
                    width: width - 32,
                    group: group,
                    expense: expense,
                  ),
                ),
              ),
            ],
          );
        },
      );
    },
  );
}

/// Recorta lo que queda por encima de la ranura (26 px) y deja sitio a
/// los lados y abajo para la sombra y la etiqueta.
class _BelowSlot extends CustomClipper<Rect> {
  const _BelowSlot();

  @override
  Rect getClip(Size size) =>
      Rect.fromLTRB(-40, 26, size.width + 40, size.height + 80);

  @override
  bool shouldReclip(_BelowSlot old) => false;
}

/// El datáfono: pantalla verde con el total, "TPV", una luz que parpadea y
/// la ranura por donde sale el papel.
class _Machine extends StatelessWidget {
  const _Machine({
    required this.t,
    required this.width,
    required this.total,
    required this.group,
  });

  final double t;
  final double width;
  final Expense total;
  final ExpenseGroup group;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l = AppLocalizations.of(context);
    // Vibra 0,6 px de un lado a otro (22 veces de 0,12 s).
    final double hum = t < 2.64
        ? 0.6 * (1 - ((t / 0.06).floor().isEven ? 1 : 0))
        : 0;
    // La luz verde parpadea 9 veces (0,3 s) y luego se queda encendida.
    final double led = t < 2.7 && ((t / 0.15).floor().isOdd) ? 0.2 : 1;
    return Transform.translate(
      offset: Offset(hum, 0),
      child: Container(
        width: width,
        height: 92,
        decoration: const BoxDecoration(
          borderRadius: BorderRadius.vertical(
            top: Radius.circular(22),
            bottom: Radius.circular(14),
          ),
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: <Color>[
              Color(0xFF3A424B),
              Color(0xFF1C2126),
              Color(0xFF121518),
            ],
            stops: <double>[0, 0.6, 1],
          ),
          boxShadow: <BoxShadow>[
            BoxShadow(
              color: Color(0x80000000),
              blurRadius: 28,
              offset: Offset(0, 14),
            ),
          ],
        ),
        foregroundDecoration: const BoxDecoration(
          borderRadius: BorderRadius.vertical(
            top: Radius.circular(22),
            bottom: Radius.circular(14),
          ),
          border: Border(top: BorderSide(color: Color(0x2EFFFFFF))),
        ),
        child: Stack(
          children: <Widget>[
            Positioned(
              left: 14,
              right: 14,
              top: 10,
              height: 34,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  gradient: const LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: <Color>[Color(0xFF2A3138), Color(0xFF20262C)],
                  ),
                ),
                child: Row(
                  children: <Widget>[
                    Container(
                      height: 22,
                      constraints: const BoxConstraints(minWidth: 96),
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      alignment: AlignmentDirectional.centerEnd,
                      decoration: BoxDecoration(
                        color: const Color(0xFF0E2A1E),
                        borderRadius: BorderRadius.circular(5),
                      ),
                      child: Text(
                        money(context, total.ticketMinor, group.currency),
                        style: const TextStyle(
                          fontFamily: 'Cousine',
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          color: Color(0xFF7DFFB9),
                          shadows: <Shadow>[
                            Shadow(color: Color(0xCC3DDC97), blurRadius: 6),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        l.ticketTpv,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 1.4,
                          color: Color(0xFF8C98A3),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Opacity(
                      opacity: led,
                      child: Container(
                        width: 9,
                        height: 9,
                        decoration: const BoxDecoration(
                          shape: BoxShape.circle,
                          color: Color(0xFF3DDC97),
                          boxShadow: <BoxShadow>[
                            BoxShadow(color: Color(0xFF3DDC97), blurRadius: 8),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Container(
                      width: 9,
                      height: 9,
                      decoration: const BoxDecoration(
                        shape: BoxShape.circle,
                        color: Color(0x59FF6B4A),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            // La ranura del papel.
            Positioned(
              left: 10,
              right: 10,
              bottom: 16,
              height: 18,
              child: Container(
                decoration: BoxDecoration(
                  color: const Color(0xFF0A0C0E),
                  borderRadius: BorderRadius.circular(9),
                ),
              ),
            ),
            Positioned(
              left: 22,
              right: 22,
              bottom: 22,
              height: 4,
              child: Opacity(
                opacity: 0.7,
                child: CustomPaint(painter: _Dots()),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Los puntitos de la ranura (rayas de 3 px cada 6 px).
class _Dots extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final Paint p = Paint()..color = const Color(0xFF6F7880);
    for (double x = 0; x < size.width; x += 6) {
      canvas.drawRect(Rect.fromLTWH(x, 0, 3, size.height), p);
    }
  }

  @override
  bool shouldRepaint(_Dots old) => false;
}

/// El borde de papel arrancado (dientes de sierra).
class _Teeth extends CustomPainter {
  const _Teeth({required this.up});

  /// true = dientes hacia arriba (borde de arriba del papel).
  final bool up;

  @override
  void paint(Canvas canvas, Size size) {
    final double w = size.width, h = size.height;
    final double step = w / 100;
    final Path p = Path();
    if (up) {
      p
        ..moveTo(0, h)
        ..lineTo(w, h)
        ..lineTo(w, h - 1);
      for (int i = 1; i <= 100; i++) {
        p.lineTo(w - step * i, i.isOdd ? 0 : h - 1);
      }
    } else {
      p
        ..moveTo(0, 0)
        ..lineTo(w, 0)
        ..lineTo(w, 1);
      for (int i = 1; i <= 100; i++) {
        p.lineTo(w - step * i, i.isOdd ? h : 1);
      }
    }
    p.close();
    canvas.drawPath(p, Paint()..color = const Color(0xFFFBF8F1));
  }

  @override
  bool shouldRepaint(_Teeth old) => old.up != up;
}

/// La raya discontinua del ticket.
class _Dashed extends StatelessWidget {
  const _Dashed();

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: SizedBox(
      height: 1,
      width: double.infinity,
      child: CustomPaint(painter: _DashPainter()),
    ),
  );
}

class _DashPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final Paint p = Paint()..color = const Color(0xFF8E8A80);
    for (double x = 0; x < size.width; x += 5) {
      canvas.drawRect(Rect.fromLTWH(x, 0, 3, 1), p);
    }
  }

  @override
  bool shouldRepaint(_DashPainter old) => false;
}

/// El recuadro verde de rayas alrededor de las líneas leídas.
class _DashedBox extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final Path box = Path()
      ..addRRect(
        RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(8)),
      );
    final Paint p = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..color = const Color(0xFF23A86F);
    for (final m in box.computeMetrics()) {
      for (double d = 0; d < m.length; d += 10) {
        canvas.drawPath(m.extractPath(d, d + 6), p);
      }
    }
  }

  @override
  bool shouldRepaint(_DashedBox old) => false;
}

/// Un código de barras de adorno, siempre igual para el mismo gasto.
class _Barcode extends CustomPainter {
  const _Barcode(this.seed);

  final int seed;

  @override
  void paint(Canvas canvas, Size size) {
    final math.Random r = math.Random(seed);
    final Paint p = Paint()..color = const Color(0xFF1E2124);
    final double k = size.width / 200;
    double x = 0;
    while (x < 198) {
      final int w = 1 + r.nextInt(3);
      canvas.drawRect(Rect.fromLTWH(x * k, 0, w * k, size.height), p);
      x += w + 1 + r.nextInt(3);
    }
  }

  @override
  bool shouldRepaint(_Barcode old) => old.seed != seed;
}

class _Paper extends StatelessWidget {
  const _Paper({
    required this.t,
    required this.width,
    required this.group,
    required this.expense,
  });

  final double t;
  final double width;
  final ExpenseGroup group;
  final Expense expense;

  static const TextStyle _ink = TextStyle(
    fontFamily: 'Cousine',
    fontSize: 12.5,
    height: 1.45,
    color: Color(0xFF1E2124),
  );

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l = AppLocalizations.of(context);
    final List<TicketItem> items = expense.items;
    // 1. Sale a saltitos (36 pasos en 2,7 s).
    final double printed = (_between(t, 0, 2.7) * 36).floor() / 36;
    // 2. Se arranca: baja 16 px torciéndose y se queda en 12 px y -1°.
    final double tear = Curves.ease.transform(_between(t, 2.8, 0.6));
    final double drop = tear < 0.35
        ? 16 * tear / 0.35
        : 16 - 4 * (tear - 0.35) / 0.65;
    final double turn = tear < 0.35
        ? -2.2 * tear / 0.35
        : -2.2 + 1.2 * (tear - 0.35) / 0.65;
    // 3. La raya verde que lo lee.
    final double scan = Curves.easeInOut.transform(_between(t, 3.2, 1.1));
    final double scanOpacity = t < 3.2 || t > 4.3
        ? 0
        : scan < 0.1
        ? scan / 0.1
        : scan > 0.9
        ? (1 - scan) / 0.1
        : 1;
    final String date = DateFormat.yMd(
      Localizations.localeOf(context).toLanguageTag(),
    ).format(expense.spentOn);
    Widget pair(String a, String b, {TextStyle style = _ink}) => Row(
      children: <Widget>[
        Expanded(child: Text(a, style: style)),
        Text(b, style: style),
      ],
    );
    final TextStyle bold = _ink.copyWith(fontWeight: FontWeight.w700);
    final Widget paper = Container(
      width: width,
      padding: const EdgeInsets.fromLTRB(18, 30, 18, 14),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          colors: <Color>[
            Color(0xFFEFEADF),
            Color(0xFFFBF8F1),
            Color(0xFFFFFDF8),
            Color(0xFFFBF8F1),
            Color(0xFFEFEADF),
          ],
          stops: <double>[0, 0.06, 0.5, 0.94, 1],
        ),
        boxShadow: <BoxShadow>[
          BoxShadow(
            color: Color(0x59000000),
            blurRadius: 22,
            offset: Offset(0, 10),
          ),
        ],
      ),
      child: DefaultTextStyle(
        style: _ink,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Center(
              child: PlaceInitial(name: expense.title, size: 58, badge: true),
            ),
            const SizedBox(height: 22),
            Text(
              expense.title.toUpperCase(),
              textAlign: TextAlign.center,
              style: bold.copyWith(fontSize: 15, letterSpacing: 1.2),
            ),
            const _Dashed(),
            pair(date, l.ticketDiners('${expense.participants.length}')),
            const _Dashed(),
            Row(
              children: <Widget>[
                SizedBox(
                  width: 26,
                  child: Text(
                    l.ticketQty,
                    style: bold,
                    softWrap: false,
                    overflow: TextOverflow.visible,
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(child: Text(l.ticketItem, style: bold)),
                const SizedBox(width: 6),
                SizedBox(
                  width: 50,
                  child: Text(
                    l.ticketPrice,
                    softWrap: false,
                    textAlign: TextAlign.right,
                    style: bold,
                  ),
                ),
                const SizedBox(width: 50),
              ],
            ),
            const SizedBox(height: 6),
            Stack(
              clipBehavior: Clip.none,
              children: <Widget>[
                Positioned.fill(
                  left: -6,
                  right: -6,
                  top: -4,
                  bottom: -4,
                  child: popIn(
                    _between(t, 4.1, 0.4),
                    CustomPaint(painter: _DashedBox()),
                  ),
                ),
                Column(
                  children: <Widget>[
                    for (int i = 0; i < items.length; i++)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 1),
                        child: Row(
                          children: <Widget>[
                            SizedBox(width: 26, child: Text('${items[i].qty}')),
                            const SizedBox(width: 6),
                            Expanded(child: Text(items[i].name)),
                            const SizedBox(width: 6),
                            SizedBox(
                              width: 50,
                              child: Text(
                                softWrap: false,
                                ticketNumber(
                                  context,
                                  items[i].priceMinor,
                                  group.currency,
                                ),
                                textAlign: TextAlign.right,
                              ),
                            ),
                            const SizedBox(width: 6),
                            SizedBox(
                              width: 44,
                              child: Align(
                                alignment: AlignmentDirectional.centerEnd,
                                child: popIn(
                                  _between(t, 4.2 + i * 0.12, 0.35),
                                  LineChip(
                                    group: group,
                                    owners: items[i].claimedBy,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 4),
            if (expense.coverMinor > 0)
              pair(
                l.ticketCover,
                '+${ticketNumber(context, expense.coverMinor, group.currency)}',
              ),
            if (expense.discountMinor > 0)
              pair(
                l.ticketDiscountLine,
                '−${ticketNumber(context, expense.discountMinor, group.currency)}',
              ),
            Container(
              height: 2,
              margin: const EdgeInsets.fromLTRB(0, 6, 0, 4),
              color: const Color(0xFF1E2124),
            ),
            pair(
              l.moneyTotal.toUpperCase(),
              '${ticketNumber(context, expense.amountMinor - expense.tipMinor, group.currency)} ${group.currency}',
              style: bold.copyWith(fontSize: 18),
            ),
            const _Dashed(),
            const SizedBox(height: 2),
            Center(
              child: SizedBox(
                width: 200,
                height: 40,
                child: CustomPaint(painter: _Barcode(expense.id.hashCode)),
              ),
            ),
          ],
        ),
      ),
    );
    return Transform.translate(
      offset: Offset(0, drop),
      child: Transform.rotate(
        angle: turn * math.pi / 180,
        alignment: Alignment.topCenter,
        child: FractionalTranslation(
          translation: Offset(0, printed - 1),
          child: Stack(
            clipBehavior: Clip.none,
            children: <Widget>[
              Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  SizedBox(
                    width: width,
                    height: 9,
                    child: const CustomPaint(painter: _Teeth(up: true)),
                  ),
                  Stack(
                    children: <Widget>[
                      paper,
                      // Un reflejo de luz por la mitad del papel.
                      Positioned(
                        left: 0,
                        right: 0,
                        top: 0,
                        bottom: 0,
                        child: IgnorePointer(
                          child: Align(
                            alignment: const Alignment(0, -0.04),
                            child: Container(
                              height: 26,
                              decoration: const BoxDecoration(
                                gradient: LinearGradient(
                                  begin: Alignment.topCenter,
                                  end: Alignment.bottomCenter,
                                  colors: <Color>[
                                    Color(0x00000000),
                                    Color(0x0D000000),
                                    Color(0x66FFFFFF),
                                    Color(0x00000000),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                      if (scanOpacity > 0)
                        Positioned.fill(
                          child: IgnorePointer(
                            child: Align(
                              alignment: Alignment(0, scan * 2 - 1),
                              child: Opacity(
                                opacity: scanOpacity,
                                child: Container(
                                  height: 4,
                                  decoration: const BoxDecoration(
                                    color: Color(0xFF3DDC97),
                                    boxShadow: <BoxShadow>[
                                      BoxShadow(
                                        color: Color(0x993DDC97),
                                        blurRadius: 18,
                                        spreadRadius: 6,
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                  SizedBox(
                    width: width,
                    height: 9,
                    child: const CustomPaint(painter: _Teeth(up: false)),
                  ),
                ],
              ),
              // "N LÍNEAS DETECTADAS", pegada arriba a la derecha.
              Positioned(
                right: -6,
                top: 23,
                child: popIn(
                  _between(t, 4.3, 0.4),
                  Container(
                    height: 26,
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: GastosColors.amber,
                      borderRadius: BorderRadius.circular(13),
                      boxShadow: const <BoxShadow>[
                        BoxShadow(
                          color: Color(0x4D000000),
                          blurRadius: 10,
                          offset: Offset(0, 4),
                        ),
                      ],
                    ),
                    child: Text(
                      l.ticketLinesFound('${items.length}'),
                      style: const TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w800,
                        color: Color(0xFF0B1217),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
