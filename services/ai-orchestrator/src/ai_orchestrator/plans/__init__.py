"""Elegid planes: el grupo vota planes deslizando tarjetas.

Qué hace:
    - Cualquier miembro de un viaje en grupo añade planes: los suyos ("Fado
      en Alfama, esta noche, 25 €") o atracciones de la ciudad que la app
      saca de la ficha de la ciudad (GET /v1/places/{IATA}, Wikidata).
    - Cada uno vota sí o no a cada plan, desde su móvil.
    - Un plan es "match" cuando TODOS los miembros han dicho que sí.

Coste 0 €: solo PostgreSQL, con topes (60 planes por viaje, 15 por persona).
Nadie ve quién votó qué: solo cuántos sí y cuántos han votado.
"""
