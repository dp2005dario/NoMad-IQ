"""Fotos reales de cada tienda o sitio de "Cerca de ti" (Google Maps).

DARIO quiere que en cada tarjeta ("Café de Oriente") salgan las fotos de
ESE sitio, las de Google Maps, no un dibujo. Google cobra por cada búsqueda,
así que:
    - La clave (GOOGLE_PLACES_API_KEY) vive SOLO en el servidor. La app no
      la ve nunca: pide la foto a nosotros y nosotros a Google.
    - Cada sitio se busca una vez y la respuesta se guarda en Redis unas
      horas: todos los que miran el mismo café comparten UNA búsqueda.
    - Single flight: si muchos piden el mismo sitio a la vez, sale una sola.
    - Tope diario de búsquedas nuevas (GOOGLE_PLACES_DAILY_LIMIT). Si se
      llega, la app enseña el dibujo de siempre hasta el día siguiente:
      nunca una factura sorpresa.
    - La foto la sirve Google directamente a la app (googleusercontent.com).
"""
