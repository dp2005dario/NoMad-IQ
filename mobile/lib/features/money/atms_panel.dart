// Cajeros cercanos (maqueta "Tu dinero fuera → Cajeros").
//
// 1. Al tocar "Buscar cajeros cerca" se pide la ubicación (solo entonces,
//    para que se entienda por qué).
// 2. Se pregunta al servidor por la zona (redondeada a ~1 km).
// 3. Aquí se ordenan por distancia con tu posición de verdad y se dibujan
//    en un "radar": tú en el centro y los cajeros alrededor.
// 4. El aviso más útil de todos: si el cajero ofrece "cobrar en tu moneda",
//    di que no (la "conversión dinámica" suele salir un 5-10 % más cara).
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/api_client.dart';
import '../../core/services.dart';
import '../../core/theme.dart';
import '../../l10n/generated/app_localizations.dart';
import '../map/geo.dart';
import '../map/location.dart';
import 'atms_api.dart';

/// Cuántos cajeros se enseñan como mucho (los más cercanos).
const int shownAtms = 15;

enum _Phase { idle, working, noLocation, failed, done }

class AtmsPanel extends StatefulWidget {
  const AtmsPanel({super.key});

  @override
  State<AtmsPanel> createState() => _AtmsPanelState();
}

class _AtmsPanelState extends State<AtmsPanel> {
  late final AppServices _services = ServicesScope.of(context);
  _Phase _phase = _Phase.idle;
  ApiError? _error;
  GeoPoint? _me;
  AtmList? _found;
  int _selected = 0;

  Future<GeoPoint?> _position() async {
    final LocationSource gps = _services.location;
    LocationAccess access = await gps.check();
    if (access == LocationAccess.denied) access = await gps.request();
    if (access != LocationAccess.granted) return null;
    try {
      final PositionFix fix = await gps.watch().first.timeout(
        const Duration(seconds: 15),
      );
      return fix.point;
    } on TimeoutException {
      return null;
    } on StateError {
      return null;
    }
  }

  Future<void> _search() async {
    setState(() => _phase = _Phase.working);
    final GeoPoint? me = await _position();
    if (!mounted) return;
    if (me == null) {
      setState(() => _phase = _Phase.noLocation);
      return;
    }
    try {
      final AtmList found = await _services.atms.near(me);
      if (!mounted) return;
      setState(() {
        _me = me;
        _found = found;
        _selected = 0;
        _phase = _Phase.done;
      });
    } on ApiException catch (e) {
      if (mounted) {
        setState(() {
          _error = e.error;
          _phase = _Phase.failed;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    final TextTheme text = Theme.of(context).textTheme;
    final GeoPoint? me = _me;
    final AtmList? found = _found;
    final List<Atm> atms = me == null || found == null
        ? const <Atm>[]
        : found.sortedFrom(me).take(shownAtms).toList();
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 40),
      children: <Widget>[
        if (_phase == _Phase.done && me != null) ...<Widget>[
          if (atms.isEmpty)
            Text(t.abroadAtmsNone, style: text.bodyLarge)
          else ...<Widget>[
            _Radar(
              me: me,
              atms: atms,
              selected: _selected,
              onPick: (int i) => setState(() => _selected = i),
            ),
            const SizedBox(height: 12),
            for (int i = 0; i < atms.length; i++)
              _AtmRow(
                atm: atms[i],
                meters: atms[i].point.distanceTo(me).round(),
                selected: i == _selected,
                onTap: () {
                  setState(() => _selected = i);
                  unawaited(_services.openBooking(atms[i].mapUrl));
                },
              ),
          ],
          const SizedBox(height: 4),
          Text(
            found!.attribution,
            style: const TextStyle(fontSize: 11, color: NomadColors.textMuted),
          ),
          const SizedBox(height: 12),
        ] else ...<Widget>[
          Text(t.abroadAtmsIntro, style: text.bodyLarge),
          const SizedBox(height: 16),
          if (_phase == _Phase.noLocation)
            _Problem(t.cameraNoLocation)
          else if (_phase == _Phase.failed)
            _Problem(
              _error == ApiError.network ? t.errorNetwork : t.errorUnavailable,
            ),
          FilledButton.icon(
            onPressed: _phase == _Phase.working ? null : _search,
            icon: _phase == _Phase.working
                ? const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.near_me_rounded),
            label: Text(t.abroadAtmsSearch),
          ),
          const SizedBox(height: 16),
        ],
        const _DccTip(),
      ],
    );
  }
}

class _Problem extends StatelessWidget {
  const _Problem(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: Text(text, style: const TextStyle(color: NomadColors.safety)),
  );
}

/// "Si el cajero te ofrece cobrar en tu moneda, di que no".
class _DccTip extends StatelessWidget {
  const _DccTip();

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF2A2418),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: NomadColors.money),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const Icon(Icons.lightbulb_rounded, color: NomadColors.money),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  t.abroadDccTitle,
                  style: const TextStyle(fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 4),
                Text(
                  t.abroadDccText,
                  style: const TextStyle(color: NomadColors.textMuted),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// El color de la comisión: verde = no cobra, amarillo = no se sabe,
/// rojo = cobra.
Color feeColor(bool? fee) => fee == false
    ? NomadColors.mint
    : fee == null
    ? const Color(0xFFFFD166)
    : NomadColors.safety;

String distanceText(AppLocalizations t, int meters) => meters < 1000
    ? t.abroadMeters(meters)
    : t.abroadKm((meters / 1000).toStringAsFixed(1));

class _AtmRow extends StatelessWidget {
  const _AtmRow({
    required this.atm,
    required this.meters,
    required this.selected,
    required this.onTap,
  });

  final Atm atm;
  final int meters;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    final List<String> meta = <String>[
      distanceText(t, meters),
      if (atm.open24h)
        t.abroadOpen24h
      else if (atm.openingHours != null)
        atm.openingHours!,
      if (atm.inBank) t.abroadInBank,
      if (atm.currencies.isNotEmpty) atm.currencies.join(' · '),
    ];
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: selected ? NomadColors.surfaceHigh : NomadColors.surface,
        borderRadius: BorderRadius.circular(18),
        child: InkWell(
          borderRadius: BorderRadius.circular(18),
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(18),
              border: Border.all(
                color: selected ? feeColor(atm.fee) : NomadColors.outline,
              ),
            ),
            child: Row(
              children: <Widget>[
                Icon(Icons.local_atm_rounded, color: feeColor(atm.fee)),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        atm.label ?? t.abroadAtmUnnamed,
                        style: const TextStyle(fontWeight: FontWeight.w800),
                      ),
                      Text(
                        meta.join(' · '),
                        style: const TextStyle(
                          fontSize: 12,
                          color: NomadColors.textMuted,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: feeColor(atm.fee),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    atm.fee == false
                        ? t.abroadFeeNo
                        : atm.fee == null
                        ? t.abroadFeeUnknown
                        : t.abroadFeeYes,
                    style: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w800,
                      color: NomadColors.background,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Tú en el centro y los cajeros alrededor, a escala (norte arriba).
class _Radar extends StatelessWidget {
  const _Radar({
    required this.me,
    required this.atms,
    required this.selected,
    required this.onPick,
  });

  final GeoPoint me;
  final List<Atm> atms;
  final int selected;
  final ValueChanged<int> onPick;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    // El más lejano marca la escala (como mínimo 300 m).
    final double range = math.max(
      300,
      atms.map((Atm a) => a.point.distanceTo(me)).reduce(math.max),
    );
    return AspectRatio(
      aspectRatio: 1.6,
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints box) {
          final double w = box.maxWidth;
          final double h = box.maxHeight;
          final double r = math.min(w, h) / 2 - 18;
          Offset at(GeoPoint p) {
            final double dy = (p.lat - me.lat) * 111320;
            final double dx =
                (p.lon - me.lon) * 111320 * math.cos(me.lat * math.pi / 180);
            return Offset(w / 2 + dx / range * r, h / 2 - dy / range * r);
          }

          return Semantics(
            label: t.abroadRadarLabel(
              atms.length,
              distanceText(t, range.round()),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(20),
              child: Stack(
                children: <Widget>[
                  Positioned.fill(
                    child: CustomPaint(painter: _RadarPainter(r)),
                  ),
                  Positioned(
                    left: w / 2 - 8,
                    top: h / 2 - 8,
                    child: Container(
                      width: 16,
                      height: 16,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: NomadColors.flights,
                        border: Border.all(color: Colors.white, width: 3),
                      ),
                    ),
                  ),
                  for (int i = atms.length - 1; i >= 0; i--)
                    Positioned(
                      left: at(atms[i].point).dx - 9,
                      top: at(atms[i].point).dy - 9,
                      child: GestureDetector(
                        onTap: () => onPick(i),
                        child: Container(
                          width: 18,
                          height: 18,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: feeColor(atms[i].fee),
                            border: Border.all(
                              color: i == selected
                                  ? Colors.white
                                  : NomadColors.background,
                              width: 2,
                            ),
                          ),
                        ),
                      ),
                    ),
                  Positioned(
                    right: 10,
                    bottom: 8,
                    child: Text(
                      distanceText(t, range.round()),
                      style: const TextStyle(
                        fontSize: 11,
                        color: NomadColors.textMuted,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

class _RadarPainter extends CustomPainter {
  _RadarPainter(this.r);

  final double r;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = const Color(0xFF101A20),
    );
    final Offset c = size.center(Offset.zero);
    final Paint ring = Paint()
      ..style = PaintingStyle.stroke
      ..color = NomadColors.outline;
    for (final double f in <double>[1 / 3, 2 / 3, 1]) {
      canvas.drawCircle(c, r * f, ring);
    }
    canvas
      ..drawLine(Offset(c.dx, c.dy - r), Offset(c.dx, c.dy + r), ring)
      ..drawLine(Offset(c.dx - r, c.dy), Offset(c.dx + r, c.dy), ring);
  }

  @override
  bool shouldRepaint(_RadarPainter old) => old.r != r;
}
