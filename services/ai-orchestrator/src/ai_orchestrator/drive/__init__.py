"""Modo coche: gasolineras, aparcamientos, cargadores eléctricos y zonas de
bajas emisiones (ZTL, ZBE...) alrededor de la carretera.

Todo sale de OpenStreetMap (Overpass), gratis y sin clave, igual que "Cerca
de ti", pero con casillas más grandes (~5 km): en coche se recorren muchas
casillas pequeñas en pocos minutos y llenaríamos Overpass de preguntas.

Lo que NO hay (y por qué):
- Precios de la gasolina: solo algunos países los publican gratis, cada uno
  con su formato. Se deja para la v2, país a país.
- Navegación giro a giro: la hace Google Maps (un enlace); hacerla nosotros
  costaría un servidor de rutas y licencias de tráfico.
- Plazas libres en tiempo real: no hay datos abiertos fiables en el mundo.
"""
