"""Fotos reales de la calle (botón "Ver la calle de verdad" del mapa).

El mapa 3D de la app es un dibujo. Para ver cómo es la calle DE VERDAD
usamos Mapillary: millones de fotos a pie de calle que hace la gente y que
se pueden reutilizar gratis (licencia CC BY-SA 4.0, citando al autor).

Para que millones de usuarios no cuesten nada ni revelen dónde está nadie:
    - El mundo se divide en casillas de ~100 m. Se pregunta por la CASILLA,
      nunca por el punto exacto, y la respuesta se guarda en Redis unas
      horas: todos los que miran la misma plaza comparten UNA petición.
    - "Single flight": si 1.000 personas miran la Puerta del Sol a la vez,
      sale una sola petición a Mapillary.
    - Límite de peticiones por segundo hacia Mapillary: si se supera, la app
      recibe "ocupado, prueba luego" (nunca una factura ni un bloqueo).
    - Las coordenadas no se escriben en los registros (logs).
    - Las fotos las sirve Mapillary directamente a la app; nosotros solo
      damos la lista.
"""
