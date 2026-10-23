"""Cajeros cercanos (pestaña "Tu dinero fuera → Cajeros" de la app).

De dónde salen: de OpenStreetMap (OSM), el mapa libre que hace la gente. Se
pregunta con Overpass, su buscador público y gratuito (sin clave ni cuenta).

Para que millones de usuarios no cuesten nada ni revelen dónde está nadie:
    - El mundo se divide en casillas de ~1 km. Se pregunta por la CASILLA,
      nunca por el punto exacto, y la respuesta se guarda un día en Redis:
      los cajeros no se mueven, así que un barrio entero sale de UNA
      petición.
    - "Single flight": si 1.000 turistas en Shibuya preguntan a la vez, sale
      una sola petición a Overpass.
    - Límite de peticiones por segundo hacia Overpass (su norma de uso
      justo): si se supera, la app recibe "ocupado, prueba luego".
    - Las coordenadas no se escriben en los registros (logs).
"""
