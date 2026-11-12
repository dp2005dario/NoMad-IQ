"""Vídeos cortos de planes: "¿No se te ocurren planes?" (YouTube Shorts).

Escribes una ciudad o país y la app enseña un carrusel de vídeos cortos de
cosas que hacer allí. Salen de YouTube (Data API v3, gratis):
    - La clave (YOUTUBE_API_KEY) vive SOLO en el servidor.
    - Cada búsqueda cuesta 100 "unidades" de las 10 000 gratis al día: se
      guarda 7 días en Redis (todos los que buscan "Lisboa" comparten UNA) y
      hay un tope diario de búsquedas nuevas (YOUTUBE_DAILY_LIMIT).
    - TikTok e Instagram no dejan buscar vídeos desde otras apps: la app
      abre sus búsquedas con el mismo sitio.
    - Además da la foto de Wikipedia de un sitio (GET /v1/plan-videos/photo).
"""
