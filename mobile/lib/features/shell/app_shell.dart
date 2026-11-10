// El "marco" que rodea las pestañas principales: la barra de abajo de las
// maquetas, con Inicio, Mapa, la CÁMARA en grande en el centro (un círculo
// verde que sobresale), Vuelos y Grupo.
//
// Como en la maqueta, Ajustes no está en la barra: se abre tocando tu foto
// arriba en el Mapa. Y la Cámara ocupa toda la pantalla (sin barra): se
// cierra con la X de arriba.
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:go_router/go_router.dart';

import '../../l10n/generated/app_localizations.dart';

class AppShell extends StatelessWidget {
  const AppShell({super.key, required this.shell});

  /// Sabe qué pestaña está abierta y cómo cambiar a otra.
  final StatefulNavigationShell shell;

  // Posiciones de las pestañas (mismo orden que las ramas en router.dart).
  static const int _home = 0;
  static const int _map = 1;
  static const int camera = 2;
  static const int _flights = 3;
  static const int _group = 4;

  /// La pestaña en la que estabas antes de abrir la Cámara (la X vuelve).
  static int lastTab = _map;

  void _go(int index) {
    if (shell.currentIndex != camera) lastTab = shell.currentIndex;
    shell.goBranch(
      index,
      // Pulsar la pestaña en la que ya estás vuelve a su pantalla inicial.
      initialLocation: index == shell.currentIndex,
    );
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    // La Cámara va a pantalla completa, sin la barra.
    if (shell.currentIndex == camera) {
      return Scaffold(backgroundColor: Colors.black, body: shell);
    }
    final int now = shell.currentIndex;
    return Scaffold(
      backgroundColor: const Color(0xFF0B1217),
      body: shell,
      floatingActionButtonLocation: const _CameraSpot(),
      floatingActionButton: _CameraButton(
        label: t.navCamera,
        onTap: () => _go(camera),
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 14),
          child: Container(
            height: 68,
            decoration: BoxDecoration(
              color: const Color(0xFF141E25),
              borderRadius: BorderRadius.circular(24),
              border: Border.all(color: const Color(0xFF26363F)),
            ),
            child: Row(
              children: <Widget>[
                _Tab(_homeIcon, t.navHome, _home, now, _go),
                _Tab(_mapIcon, t.navMap, _map, now, _go),
                // El hueco de la cámara (el botón va por encima).
                const Expanded(child: SizedBox()),
                _Tab(_flightsIcon, t.navFlights, _flights, now, _go),
                _Tab(_groupIcon, t.navGroup, _group, now, _go),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// Los dibujos de la barra (las mismas líneas que la maqueta, de 24×24).
const String _homeIcon =
    '<path d="M3 11l9-7 9 7v9a1 1 0 0 1-1 1h-5v-6h-6v6H4a1 1 0 0 1-1-1z"/>';
const String _mapIcon =
    '<path d="M9 4L3 6v14l6-2 6 2 6-2V4l-6 2z"/><path d="M9 4v14M15 6v14"/>';
const String _flightsIcon =
    '<path d="M2 16l20-6-2-3-7 2-5-5-2 1 3 5-5 1.5-2-1.5-1.5.5z"/>'
    '<path d="M3 21h18"/>';
const String _groupIcon =
    '<circle cx="9" cy="8" r="3.5"/><path d="M2.5 20a6.5 6.5 0 0 1 13 0"/>'
    '<circle cx="17" cy="9" r="2.5"/><path d="M17 14a5 5 0 0 1 5 5"/>';

/// El botón de la cámara se pone centrado y sobresale 12 px por encima de
/// la barra, como en la maqueta.
class _CameraSpot extends FloatingActionButtonLocation {
  const _CameraSpot();

  @override
  Offset getOffset(ScaffoldPrelayoutGeometry g) {
    final double x =
        (g.scaffoldSize.width - g.floatingActionButtonSize.width) / 2;
    // contentBottom = donde empieza la barra de abajo.
    return Offset(x, g.contentBottom - 12);
  }
}

/// El círculo verde de la cámara (degradado, borde oscuro y brillo).
class _CameraButton extends StatelessWidget {
  const _CameraButton({
    required this.label,
    required this.onTap,
    this.tooltip = true,
  });

  final String label;
  final VoidCallback onTap;

  /// Fuera del navegador (la barra de las pantallas de encima) no hay sitio
  /// donde flotar el globito, así que allí va sin él.
  final bool tooltip;

  @override
  Widget build(BuildContext context) {
    final Widget button = Semantics(
      button: true,
      label: label,
      excludeSemantics: true,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          width: 62,
          height: 62,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: const LinearGradient(
              // 140° en CSS: de arriba a la izquierda hacia abajo a la derecha.
              begin: Alignment(-0.64, -0.77),
              end: Alignment(0.64, 0.77),
              colors: <Color>[
                Color(0xFF7FF0BF),
                Color(0xFF3DDC97),
                Color(0xFF1FA971),
              ],
              stops: <double>[0, 0.45, 1],
            ),
            border: Border.all(color: const Color(0xFF0B1217), width: 4),
            boxShadow: const <BoxShadow>[
              BoxShadow(
                color: Color(0x733DDC97),
                blurRadius: 24,
                offset: Offset(0, 10),
              ),
            ],
          ),
          child: SvgPicture.string(
            '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" '
            'fill="none" stroke="#0B1217" stroke-width="2.2" '
            'stroke-linecap="round" stroke-linejoin="round">'
            '<path d="M4 8h3l2-3h6l2 3h3a1 1 0 0 1 1 1v10a1 1 0 0 1-1 1H4a1 1 '
            '0 0 1-1-1V9a1 1 0 0 1 1-1z"/>'
            '<circle cx="12" cy="13.5" r="3.6"/></svg>',
            width: 28,
            height: 28,
          ),
        ),
      ),
    );
    return tooltip ? Tooltip(message: label, child: button) : button;
  }
}

class _Tab extends StatelessWidget {
  const _Tab(this.icon, this.label, this.index, this.current, this.onTap);

  final String icon;
  final String label;
  final int index;
  final int current;
  final void Function(int) onTap;

  @override
  Widget build(BuildContext context) {
    final bool selected = index == current;
    final Color color = selected
        ? const Color(0xFF3DDC97)
        : const Color(0xFF9FB0B8);
    final String hex = (color.toARGB32() & 0xFFFFFF)
        .toRadixString(16)
        .padLeft(6, '0');
    return Expanded(
      child: Semantics(
        selected: selected,
        button: true,
        child: InkResponse(
          onTap: () => onTap(index),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              SvgPicture.string(
                '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" '
                'fill="none" stroke="#$hex" stroke-width="2" '
                'stroke-linecap="round" stroke-linejoin="round">$icon</svg>',
                width: 22,
                height: 22,
              ),
              const SizedBox(height: 3),
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis, // por si el idioma es largo
                style: TextStyle(
                  fontFamily: 'Manrope',
                  color: color,
                  fontSize: 11,
                  fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// La misma barra de abajo, para las pantallas que se abren ENCIMA de las
/// pestañas (Hoteles, Bóveda, Radar...). Antes esas pantallas no tenían
/// barra y solo se podía salir con "atrás". Ninguna pestaña sale marcada
/// (no estás en ninguna) y tocar una te lleva directamente a ella.
class ShellTabBar extends StatelessWidget {
  const ShellTabBar({super.key, required this.onTab});

  /// Se llama con la posición de la pestaña (0 Inicio ... 4 Grupo).
  final void Function(int index) onTab;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    return Material(
      type: MaterialType.transparency,
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 82,
          child: Stack(
            clipBehavior: Clip.none,
            alignment: Alignment.bottomCenter,
            children: <Widget>[
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 14),
                child: Container(
                  height: 68,
                  decoration: BoxDecoration(
                    color: const Color(0xFF141E25),
                    borderRadius: BorderRadius.circular(24),
                    border: Border.all(color: const Color(0xFF26363F)),
                  ),
                  child: Row(
                    children: <Widget>[
                      _Tab(_homeIcon, t.navHome, AppShell._home, -1, onTab),
                      _Tab(_mapIcon, t.navMap, AppShell._map, -1, onTab),
                      const Expanded(child: SizedBox()),
                      _Tab(
                        _flightsIcon,
                        t.navFlights,
                        AppShell._flights,
                        -1,
                        onTab,
                      ),
                      _Tab(_groupIcon, t.navGroup, AppShell._group, -1, onTab),
                    ],
                  ),
                ),
              ),
              // El botón de la cámara sobresale por arriba, como en las pestañas.
              Positioned(
                top: -6,
                child: _CameraButton(
                  label: t.navCamera,
                  onTap: () => onTab(AppShell.camera),
                  tooltip: false,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
