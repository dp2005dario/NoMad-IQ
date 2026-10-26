# PostgreSQL 17 + PostGIS para el servidor de producción.
#
# ¿Por qué no usamos la imagen "postgis/postgis" como en desarrollo? Porque
# solo se publica para procesadores Intel/AMD, y el servidor gratis de Oracle
# (Ampere A1) es ARM. La imagen oficial de PostgreSQL sí existe para ARM y ya
# trae configurado el repositorio oficial de paquetes de PostgreSQL (PGDG),
# que tiene PostGIS para ARM. Así que partimos de ella y añadimos PostGIS.
#
# deploy.sh la construye en el propio servidor (no hace falta registro de
# imágenes, que costaría dinero o habría que mantener).
FROM postgres:17-bookworm

RUN apt-get update \
 && apt-get install -y --no-install-recommends postgresql-17-postgis-3 \
 && rm -rf /var/lib/apt/lists/*
