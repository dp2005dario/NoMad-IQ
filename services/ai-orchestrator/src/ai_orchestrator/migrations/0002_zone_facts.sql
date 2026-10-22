-- Migración 0002: hechos verificados de cada zona, para las audioguías.
--
-- Recordatorio: una migración publicada NUNCA se edita (el servicio guarda su
-- huella SHA-256). Para añadir o corregir hechos, crea la 0003.
--
-- ¿Por qué una tabla de hechos? El LLM solo puede REDACTAR a partir de ellos:
-- cada párrafo del guion cita los hechos que usa y una comprobación rechaza
-- cualquier cifra que no esté en ellos (ver audioguides/writer.py). Así una
-- fecha inventada nunca llega a los oídos del viajero.
--
-- Clave por slug de zona ("madrid-centro") y no por zone_id: el UUID se genera
-- al dar de alta la zona y es distinto en cada entorno; el slug es estable.
-- No hay clave foránea hacia geo.zones a propósito: esa tabla es del
-- geo-engine (cada servicio es dueño de su esquema) y podría no existir aún.

CREATE TABLE ai.zone_facts (
    zone_slug  text     NOT NULL CHECK (zone_slug ~ '^[a-z0-9]+(-[a-z0-9]+)*$' AND length(zone_slug) <= 100),
    -- Idioma ISO 639-1 en minúsculas, igual que normaliza el geo-engine.
    language   text     NOT NULL CHECK (language ~ '^[a-z]{2,3}$'),
    -- Orden de lectura dentro de la zona (1 = primero).
    position   smallint NOT NULL CHECK (position BETWEEN 1 AND 99),
    fact       text     NOT NULL CHECK (length(fact) BETWEEN 5 AND 500),
    -- De dónde sale el dato, para poder revisarlo.
    source     text     NOT NULL DEFAULT '' CHECK (length(source) <= 200),
    PRIMARY KEY (zone_slug, language, position)
);

-- Hechos de las zonas de DEMOSTRACIÓN (services/geo-engine/seeds/demo_zones.sql).
-- Son datos públicos y conocidos, redactados de forma prudente. Antes de usar
-- esto en producción, cada hecho debe revisarlo una persona con la fuente.
INSERT INTO ai.zone_facts (zone_slug, language, position, fact, source) VALUES
  ('madrid-centro', 'es', 1, 'En la Puerta del Sol está el Kilómetro Cero, el punto desde el que se miden las carreteras radiales de España.', 'Ayuntamiento de Madrid'),
  ('madrid-centro', 'es', 2, 'En la Puerta del Sol se encuentra la estatua del Oso y el Madroño, símbolo de la ciudad.', 'Ayuntamiento de Madrid'),
  ('madrid-centro', 'es', 3, 'La Plaza Mayor se terminó en 1619, durante el reinado de Felipe III.', 'Ayuntamiento de Madrid'),
  ('madrid-centro', 'es', 4, 'Las obras de la Gran Vía comenzaron en 1910.', 'Ayuntamiento de Madrid'),
  ('madrid-centro', 'en', 1, 'Puerta del Sol is home to Kilometre Zero, the point from which Spain''s radial roads are measured.', 'Madrid City Council'),
  ('madrid-centro', 'en', 2, 'Puerta del Sol has the statue of the Bear and the Strawberry Tree, the symbol of the city.', 'Madrid City Council'),
  ('madrid-centro', 'en', 3, 'Plaza Mayor was completed in 1619, during the reign of Philip III.', 'Madrid City Council'),
  ('madrid-centro', 'en', 4, 'Construction of the Gran Vía began in 1910.', 'Madrid City Council'),

  ('madrid-museos', 'es', 1, 'El Museo del Prado abrió sus puertas al público en 1819.', 'Museo Nacional del Prado'),
  ('madrid-museos', 'es', 2, 'El Prado conserva Las Meninas, de Diego Velázquez.', 'Museo Nacional del Prado'),
  ('madrid-museos', 'es', 3, 'El Museo Reina Sofía expone el Guernica de Pablo Picasso.', 'Museo Nacional Centro de Arte Reina Sofía'),
  ('madrid-museos', 'es', 4, 'El edificio principal del Reina Sofía fue el antiguo Hospital General de Madrid, del siglo XVIII.', 'Museo Nacional Centro de Arte Reina Sofía'),
  ('madrid-museos', 'en', 1, 'The Prado Museum opened to the public in 1819.', 'Museo Nacional del Prado'),
  ('madrid-museos', 'en', 2, 'The Prado holds Las Meninas, by Diego Velázquez.', 'Museo Nacional del Prado'),
  ('madrid-museos', 'en', 3, 'The Reina Sofía Museum displays Pablo Picasso''s Guernica.', 'Museo Nacional Centro de Arte Reina Sofía'),
  ('madrid-museos', 'en', 4, 'The main Reina Sofía building was once Madrid''s General Hospital, from the eighteenth century.', 'Museo Nacional Centro de Arte Reina Sofía'),

  ('barcelona-sagrada-familia', 'es', 1, 'Las obras de la Sagrada Família comenzaron en 1882.', 'Basílica de la Sagrada Família'),
  ('barcelona-sagrada-familia', 'es', 2, 'Antoni Gaudí dedicó más de cuarenta años de su vida a este templo.', 'Basílica de la Sagrada Família'),
  ('barcelona-sagrada-familia', 'es', 3, 'La fachada del Nacimiento y la cripta son Patrimonio Mundial de la UNESCO desde 2005.', 'UNESCO'),
  ('barcelona-sagrada-familia', 'es', 4, 'El papa Benedicto XVI la consagró como basílica en 2010.', 'Basílica de la Sagrada Família'),
  ('barcelona-sagrada-familia', 'en', 1, 'Construction of the Sagrada Família began in 1882.', 'Basílica de la Sagrada Família'),
  ('barcelona-sagrada-familia', 'en', 2, 'Antoni Gaudí devoted more than forty years of his life to the temple.', 'Basílica de la Sagrada Família'),
  ('barcelona-sagrada-familia', 'en', 3, 'The Nativity façade and the crypt have been UNESCO World Heritage since 2005.', 'UNESCO'),
  ('barcelona-sagrada-familia', 'en', 4, 'Pope Benedict XVI consecrated it as a basilica in 2010.', 'Basílica de la Sagrada Família'),

  ('paris-louvre', 'es', 1, 'Antes de ser museo, el Louvre fue un palacio real.', 'Musée du Louvre'),
  ('paris-louvre', 'es', 2, 'El Louvre abrió como museo en 1793.', 'Musée du Louvre'),
  ('paris-louvre', 'es', 3, 'La pirámide de cristal de la entrada, obra del arquitecto I. M. Pei, se inauguró en 1989.', 'Musée du Louvre'),
  ('paris-louvre', 'es', 4, 'En el Louvre se expone La Gioconda, de Leonardo da Vinci.', 'Musée du Louvre'),
  ('paris-louvre', 'en', 1, 'Before becoming a museum, the Louvre was a royal palace.', 'Musée du Louvre'),
  ('paris-louvre', 'en', 2, 'The Louvre opened as a museum in 1793.', 'Musée du Louvre'),
  ('paris-louvre', 'en', 3, 'The glass pyramid at the entrance, designed by architect I. M. Pei, opened in 1989.', 'Musée du Louvre'),
  ('paris-louvre', 'en', 4, 'The Louvre displays the Mona Lisa, by Leonardo da Vinci.', 'Musée du Louvre'),

  ('tokio-shibuya', 'es', 1, 'El cruce de Shibuya es uno de los pasos de peatones más concurridos del mundo.', 'Shibuya City'),
  ('tokio-shibuya', 'es', 2, 'Junto a la estación de Shibuya está la estatua de Hachikō, el perro que esperó a su dueño durante años.', 'Shibuya City'),
  ('tokio-shibuya', 'es', 3, 'La estatua actual de Hachikō se instaló en 1948.', 'Shibuya City'),
  ('tokio-shibuya', 'en', 1, 'The Shibuya Crossing is one of the busiest pedestrian crossings in the world.', 'Shibuya City'),
  ('tokio-shibuya', 'en', 2, 'Next to Shibuya Station stands the statue of Hachikō, the dog who waited for his owner for years.', 'Shibuya City'),
  ('tokio-shibuya', 'en', 3, 'The current Hachikō statue was installed in 1948.', 'Shibuya City');
