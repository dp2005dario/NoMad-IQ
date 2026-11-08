// La mini Flyra de la esquina (como en la maqueta de Inicio): una bolita con
// Flyra abajo a la derecha de TODAS las pantallas que flota un poco y, cuando
// pasa algo de verdad, saca un bocadillo con el aviso durante 4 segundos.
//
// Solo avisos REALES, nunca de ejemplo:
// - se va o vuelve la conexión a internet (AppServices.onlineChanges);
// - llega un aviso push con la app abierta (firebase_push.dart);
// - una pantalla avisa de un error con FlyraNotes.instance.say(...).
//
// Tocar la bolita repite el último aviso (o abre la pantalla del aviso, si
// tiene una). Si aún no hubo ninguno, abre el chat con Flyra.
import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../core/motion.dart';
import '../../core/services.dart';
import '../../l10n/generated/app_localizations.dart';
import '../../widgets/flyra_avatar.dart';

/// Si hay internet, cada vez que cambia (la del móvil).
Stream<bool> deviceOnlineChanges() => Connectivity().onConnectivityChanged
    .map(
      (List<ConnectivityResult> r) =>
          r.any((ConnectivityResult c) => c != ConnectivityResult.none),
    )
    .distinct();

/// Sin datos de conexión (pruebas): nunca avisa.
Stream<bool> noOnlineChanges() => const Stream<bool>.empty();

/// Pantallas con su propia Flyra: ahí no sale la bolita de la esquina.
const Set<String> _ownFlyra = <String>{
  '/flyra',
  '/map',
  '/camera',
  '/airport',
  '/assistant',
};

/// De qué tipo es el aviso (cambia el color del puntito y del borde).
enum FlyraNoteKind { ok, warn, tip, error }

class FlyraNote {
  const FlyraNote(this.kind, this.text, {this.route});

  final FlyraNoteKind kind;
  final String text;

  /// A qué pantalla lleva tocar la bolita mientras se ve (opcional).
  final String? route;

  Color get color => switch (kind) {
    FlyraNoteKind.ok => const Color(0xFF3DDC97),
    FlyraNoteKind.warn => const Color(0xFFFFB066),
    FlyraNoteKind.tip => const Color(0xFF9B7BFF),
    FlyraNoteKind.error => const Color(0xFFFF6B6B),
  };
}

/// El "buzón" de avisos de la mini Flyra: quien quiera avisar llama a [say].
class FlyraNotes extends ChangeNotifier {
  FlyraNotes._();

  /// Uno para toda la app.
  static final FlyraNotes instance = FlyraNotes._();

  FlyraNote? _last;
  int _count = 0;

  /// El último aviso (null = aún ninguno).
  FlyraNote? get last => _last;

  /// Cuántos avisos van (para saber si hay uno nuevo).
  int get count => _count;

  void say(FlyraNote note) {
    _last = note;
    _count++;
    notifyListeners();
  }

  /// Para las pruebas: vuelve a empezar sin avisos.
  @visibleForTesting
  void reset() {
    _last = null;
    _count = 0;
  }
}

/// Pone la mini Flyra encima de [child] (toda la app).
class FlyraMini extends StatefulWidget {
  const FlyraMini({
    super.key,
    required this.child,
    required this.onOpen,
    this.location,
  });

  final Widget child;

  /// Abrir una pantalla (la del aviso, o el chat si [route] es null).
  final void Function(String? route) onOpen;

  /// Dónde está el usuario (la ruta, "/flyra"...). En el chat con Flyra no
  /// hace falta la mini Flyra (y taparía el botón de enviar).
  final ValueListenable<String>? location;

  /// Para encontrar la bolita (pruebas).
  static const Key orbKey = ValueKey<String>('flyra-mini');

  @override
  State<FlyraMini> createState() => _FlyraMiniState();
}

class _FlyraMiniState extends State<FlyraMini> with TickerProviderStateMixin {
  final FlyraNotes _notes = FlyraNotes.instance;

  // Flota arriba y abajo (4,5 s), sin fin.
  late final AnimationController _float = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2250),
  );
  bool _started = false;
  bool _showing = false;
  Timer? _hide;
  StreamSubscription<bool>? _net;
  bool? _online;

  @override
  void initState() {
    super.initState();
    _notes.addListener(_onNote);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _net ??= ServicesScope.of(context).onlineChanges().listen(_onNet);
    if (_started || MediaQuery.disableAnimationsOf(context)) return;
    _started = true;
    Motion.loop(_float, reverse: true);
  }

  /// Se fue o volvió internet. Al abrir la app solo avisa si NO hay.
  void _onNet(bool online) {
    final bool? before = _online;
    _online = online;
    if (before == online || (before == null && online)) return;
    final AppLocalizations t = AppLocalizations.of(context);
    _notes.say(
      online
          ? FlyraNote(FlyraNoteKind.ok, t.flyraOnline)
          : FlyraNote(FlyraNoteKind.warn, t.flyraOffline),
    );
  }

  @override
  void dispose() {
    _notes.removeListener(_onNote);
    unawaited(_net?.cancel());
    _hide?.cancel();
    _float.dispose();
    super.dispose();
  }

  void _onNote() => _show();

  /// Saca el bocadillo 4 segundos.
  void _show() {
    _hide?.cancel();
    setState(() => _showing = true);
    _hide = Timer(const Duration(seconds: 4), () {
      if (mounted) setState(() => _showing = false);
    });
  }

  void _tap() {
    final FlyraNote? note = _notes.last;
    if (note == null) {
      widget.onOpen(null);
    } else if (_showing && note.route != null) {
      widget.onOpen(note.route);
    } else {
      _show();
    }
  }

  @override
  Widget build(BuildContext context) {
    final ValueListenable<String>? location = widget.location;
    if (location == null) return _layout(context, '');
    return ValueListenableBuilder<String>(
      valueListenable: location,
      builder: (BuildContext context, String path, Widget? _) =>
          _layout(context, path),
    );
  }

  Widget _layout(BuildContext context, String path) {
    final FlyraNote? note = _notes.last;
    final MediaQueryData media = MediaQuery.of(context);
    // Se esconde en el chat con Flyra y con el teclado abierto (no tapa lo
    // que escribes ni el botón de enviar). Y en las pantallas que, como en
    // sus maquetas, ya traen su propia Flyra (Mapa, Cámara, Aeropuerto y Asistente).
    final bool hidden = _ownFlyra.contains(path) || media.viewInsets.bottom > 0;
    final double bottom = media.padding.bottom;
    return Stack(
      children: <Widget>[
        widget.child,
        if (!hidden)
          Positioned(
            right: 16,
            // Por encima de la barra de abajo de la app.
            bottom: bottom + 84,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                if (note != null)
                  IgnorePointer(
                    child: AnimatedOpacity(
                      opacity: _showing ? 1 : 0,
                      duration: const Duration(milliseconds: 300),
                      child: AnimatedScale(
                        scale: _showing ? 1 : 0.9,
                        alignment: Alignment.bottomRight,
                        duration: const Duration(milliseconds: 350),
                        curve: Curves.easeOutBack,
                        child: _Bubble(note: note, visible: _showing),
                      ),
                    ),
                  ),
                const SizedBox(width: 8),
                AnimatedBuilder(
                  animation: _float,
                  builder: (BuildContext context, Widget? child) =>
                      Transform.translate(
                        offset: Offset(
                          0,
                          -6 * Curves.easeInOut.transform(_float.value),
                        ),
                        child: child,
                      ),
                  child: Semantics(
                    button: true,
                    label: AppLocalizations.of(context).flyraMiniLabel,
                    excludeSemantics: true,
                    child: GestureDetector(
                      key: FlyraMini.orbKey,
                      onTap: _tap,
                      child: Container(
                        width: 44,
                        height: 44,
                        padding: const EdgeInsets.all(4),
                        decoration: const BoxDecoration(
                          shape: BoxShape.circle,
                          gradient: RadialGradient(
                            center: Alignment(-0.3, -0.4),
                            colors: <Color>[
                              Color(0xFF7CF0BC),
                              Color(0xFF3DDC97),
                              Color(0xFF5A5BD9),
                              Color(0xFF9B7BFF),
                            ],
                            stops: <double>[0, 0.4, 0.85, 1],
                          ),
                          boxShadow: <BoxShadow>[
                            BoxShadow(color: Color(0x99000000), blurRadius: 18),
                            BoxShadow(color: Color(0x883DDC97), blurRadius: 22),
                            BoxShadow(color: Color(0x559B7BFF), blurRadius: 34),
                          ],
                        ),
                        child: const FlyraAvatar(size: 36),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// El bocadillo: puntito de color y el texto del aviso.
class _Bubble extends StatelessWidget {
  const _Bubble({required this.note, required this.visible});

  final FlyraNote note;
  final bool visible;

  @override
  Widget build(BuildContext context) {
    // Material: va encima de toda la app, fuera de las pantallas, y sin él
    // el texto saldría subrayado en amarillo.
    return Material(type: MaterialType.transparency, child: _box());
  }

  Widget _box() {
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      constraints: const BoxConstraints(maxWidth: 232),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xF2101A21),
        border: Border.all(color: note.color.withValues(alpha: 0.4)),
        borderRadius: const BorderRadius.only(
          topLeft: Radius.circular(16),
          topRight: Radius.circular(16),
          bottomLeft: Radius.circular(16),
          bottomRight: Radius.circular(4),
        ),
        boxShadow: const <BoxShadow>[
          BoxShadow(color: Color(0xAA000000), blurRadius: 24),
        ],
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Container(
            width: 8,
            height: 8,
            margin: const EdgeInsets.only(top: 5, right: 8),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: note.color,
              boxShadow: <BoxShadow>[
                BoxShadow(color: note.color, blurRadius: 8),
              ],
            ),
          ),
          Flexible(
            // Que los lectores de pantalla lo lean al salir.
            child: Semantics(
              liveRegion: visible,
              child: Text(
                note.text,
                style: const TextStyle(
                  fontSize: 12.5,
                  height: 1.35,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFFE8F1EE),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
