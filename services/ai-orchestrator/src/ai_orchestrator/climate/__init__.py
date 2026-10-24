"""El clima típico de cada mes en un sitio (pantalla Explorar de la app).

De dónde sale: de NASA POWER, un servicio de la NASA con medias de 30 años
de satélite para cualquier punto del planeta. Es de dominio público, gratis
y sin clave.

Para que millones de usuarios no cuesten nada:
    - El mundo se divide en casillas de 0,5° (~50 km): el clima medio no
      cambia de una calle a otra. Se pregunta por la casilla, nunca por el
      punto exacto, y se guarda 30 días en Redis (las medias de 30 años no
      cambian de un día para otro).
    - "Single flight" y límite de peticiones por segundo hacia la NASA.
    - Las coordenadas no se escriben en los registros.
"""
