"""Cromos con amigos: ligas de amigos con los sellos del Pasaporte.

Qué hace:
    - **Liga**: cada mes gana quien más puntos saca con los cromos nuevos
      (común 10, rara 40, épica 80, legendaria 150; la rareza es la edad del
      monumento, la misma regla que la app).
    - **Cambiar**: le ofreces a un amigo un cromo tuyo que él no tiene por
      uno suyo que te falta. Si acepta, los dos recibís una copia (los
      cromos ganados de verdad siguen siendo solo vuestros: una copia no da
      puntos de liga, para que nadie gane cambiando).
    - **Dónde están**: solo si cada uno lo activa, la ciudad aproximada.

Coste 0 €: solo PostgreSQL, con topes (30 personas por liga, 1.000 cromos
por persona, 20 cambios pendientes por persona).
"""
