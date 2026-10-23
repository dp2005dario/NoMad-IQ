"""Fichas de ciudad: por qué es famosa, lo más visitado y fotos con licencia libre.

La app las enseña en la Ruta del vuelo al llegar al origen y al destino.

De dónde sale cada cosa (todo gratis y con licencia libre):
    - Wikidata: qué ciudad es, su foto, población, país, capital, moneda,
      idiomas y sus lugares más conocidos (con foto).
    - Wikipedia: el resumen de "por qué es famosa", en el idioma del usuario.
    - Wikimedia Commons: las fotos (solo admite fotos con licencia libre).

Para que millones de usuarios no cuesten nada ni molesten a Wikimedia:
    - Cada ficha se pide UNA vez por ciudad e idioma y se guarda 7 días en
      Redis. Hay ~5.500 aeropuertos x 10 idiomas: como mucho ~55.000 fichas.
    - "Single flight": si 1.000 personas abren Tokio a la vez, sale UNA
      petición.
    - Un límite de peticiones por segundo hacia Wikimedia: si se supera, la
      app recibe "ocupado, prueba luego" en vez de saturar a nadie.
"""
