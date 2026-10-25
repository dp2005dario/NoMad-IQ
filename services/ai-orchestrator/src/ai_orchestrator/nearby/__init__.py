"""Cerca de ti: lo gratis de alrededor (agua, baños, wifi, enchufes) y
sitios que ver para un paseo de "tengo 2 horas".

Todo sale de OpenStreetMap (Overpass), gratis y sin clave, con la misma idea
que los cajeros: la app manda la casilla de ~1 km donde está (nunca el punto
exacto), y cada casilla se pregunta a Overpass como mucho una vez por semana
(Redis). Mil turistas en la Puerta del Sol = UNA pregunta a la semana.

Lo que NO hay: "ofertas de locales". No existe una fuente libre y fiable de
ofertas en tiempo real; se deja para cuando haya acuerdos con locales.
"""
