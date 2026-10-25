"""Guía del aeropuerto (maqueta "Aeropuerto"): puertas, baños, cafés...

Los sitios de dentro de cada aeropuerto salen de OpenStreetMap (Overpass),
gratis y sin clave. Un aeropuerto casi no cambia, así que cada uno se pide
una vez al mes como mucho y se guarda en Redis: miles de viajeros en Barajas
son UNA sola petición a Overpass.
"""
