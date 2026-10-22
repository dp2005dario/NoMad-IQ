-- Zonas de DEMOSTRACIÓN para probar el geofencing en local y en la CI.
-- Solo se cargan si el geo-engine arranca con SEED_DEMO_ZONES=true.
-- Los contornos son aproximados (rectángulos y polígonos sencillos): sirven
-- para ver el sistema funcionando, no para producción.
--
-- Recuerda: en WKT el orden es "longitud latitud" (X Y) y el primer punto de
-- cada anillo se repite al final para cerrarlo.
INSERT INTO geo.zones (slug, name, kind, geom) VALUES
  ('madrid-centro', 'Madrid · Centro (Sol, Gran Vía, Plaza Mayor)', 'CITY_CENTER',
   ST_Multi(ST_GeomFromText('POLYGON((-3.7140 40.4110, -3.6930 40.4110, -3.6930 40.4250, -3.7040 40.4265, -3.7140 40.4250, -3.7140 40.4110))', 4326))),
  ('madrid-barajas', 'Aeropuerto Adolfo Suárez Madrid-Barajas', 'AIRPORT',
   ST_Multi(ST_GeomFromText('POLYGON((-3.6000 40.4600, -3.5300 40.4600, -3.5300 40.5300, -3.6000 40.5300, -3.6000 40.4600))', 4326))),
  -- Un MultiPolygon de verdad: dos museos separados forman UNA zona.
  ('madrid-museos', 'Madrid · Prado y Reina Sofía', 'TOURIST_AREA',
   ST_GeomFromText('MULTIPOLYGON(((-3.6940 40.4125, -3.6900 40.4125, -3.6900 40.4150, -3.6940 40.4150, -3.6940 40.4125)),((-3.6960 40.4075, -3.6925 40.4075, -3.6925 40.4095, -3.6960 40.4095, -3.6960 40.4075)))', 4326)),
  ('barcelona-sagrada-familia', 'Barcelona · Sagrada Família', 'TOURIST_AREA',
   ST_Multi(ST_GeomFromText('POLYGON((2.1715 41.4015, 2.1775 41.4015, 2.1775 41.4057, 2.1715 41.4057, 2.1715 41.4015))', 4326))),
  ('paris-louvre', 'París · Museo del Louvre', 'TOURIST_AREA',
   ST_Multi(ST_GeomFromText('POLYGON((2.3315 48.8590, 2.3400 48.8590, 2.3400 48.8625, 2.3315 48.8625, 2.3315 48.8590))', 4326))),
  ('tokio-shibuya', 'Tokio · Shibuya', 'CITY_CENTER',
   ST_Multi(ST_GeomFromText('POLYGON((139.6950 35.6540, 139.7080 35.6540, 139.7080 35.6620, 139.6950 35.6620, 139.6950 35.6540))', 4326)))
ON CONFLICT (slug) DO NOTHING;
