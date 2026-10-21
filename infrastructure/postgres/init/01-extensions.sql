-- Se ejecuta UNA sola vez, cuando el volumen de datos de PostgreSQL está vacío.
-- Activa las extensiones que usarán los microservicios.

-- PostGIS: tipos y funciones geoespaciales (puntos, polígonos, distancias).
CREATE EXTENSION IF NOT EXISTS postgis;

-- pgcrypto: funciones criptográficas (gen_random_uuid, digest, etc.).
CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- Un esquema por microservicio: cada servicio solo toca sus propias tablas
-- (principio de mínimo privilegio y fronteras claras entre servicios).
CREATE SCHEMA IF NOT EXISTS flights;
CREATE SCHEMA IF NOT EXISTS geo;
CREATE SCHEMA IF NOT EXISTS identity;
