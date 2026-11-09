# Página de Vuelos (maqueta "Cazador de vuelos")

- `build_page.py` crea `assets/flights/vuelos.html` a partir de la maqueta
  (`Vuelos.dc.html`) y su motor (`support.js`). Quita los datos de ejemplo,
  las notas para DARIO, el botón "PROBAR AVISO" y la barra de abajo.
- `logic.js` es la lógica de la página: la de la maqueta, pero con tus datos
  (los pone `lib/features/flights/flights_page.dart`).
- `icono-que-pasa.png`: el icono del cuadrado "Qué pasa" (los otros cuatro
  son los de `assets/inicio`). Licencia: **SIN COMPROBAR**, como los de Inicio.

Para volver a crearla:

    python3 tool/vuelos/build_page.py Vuelos.dc.html support.js assets/flights/vuelos.html
