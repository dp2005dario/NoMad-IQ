//! La "foto" en memoria de aeropuertos y zonas, con sus índices R-tree.
//!
//! ## ¿Qué es un R-tree?
//! Analogía: para encontrar una calle no lees el callejero entero; vas al
//! índice, miras en qué cuadrícula está y solo revisas esa página. Un R-tree
//! agrupa los objetos cercanos en "cajas" y las cajas en cajas más grandes.
//! Buscar "qué hay cerca de aquí" descarta de golpe todas las cajas lejanas,
//! así que cuesta del orden de log(n) en vez de mirar uno por uno.
//!
//! ## ¿Por qué una foto inmutable?
//! Un [`GeoSnapshot`] nunca cambia después de construirse. Muchas peticiones
//! pueden leerlo a la vez sin cerrojos (nadie escribe). Cuando PostGIS tiene
//! datos nuevos se construye una foto NUEVA aparte y se cambia el puntero de
//! golpe (ver `crate::snapshot`). Es la forma de evitar la contención de
//! cerrojos que advertía el análisis de riesgos.

use std::collections::HashMap;
use std::time::SystemTime;

use bytes::Bytes;
use geo::{BoundingRect, Closest, ClosestPoint, Intersects};
use geo_types::MultiPolygon;
use rstar::primitives::GeomWithData;
use rstar::{AABB, RTree, RTreeObject};
use uuid::Uuid;

use super::coord::{LatLng, surface_distance_for_chord};

/// Margen entre la distancia sobre una esfera perfecta (lo que ordena el
/// índice) y la distancia real sobre el elipsoide WGS84 (la Tierra está algo
/// achatada). La diferencia real es < 0,5 %; usamos 1 % para ir sobrados.
const ELLIPSOID_TOLERANCE: f64 = 0.01;

/// Tipo de zona (versión de dominio, independiente de protobuf y de SQL).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum ZoneKind {
    /// Centro de una ciudad.
    CityCenter,
    /// Zona turística.
    TouristArea,
    /// Recinto de aeropuerto.
    Airport,
    /// Zona restringida o a evitar.
    Restricted,
}

impl ZoneKind {
    /// Convierte el texto guardado en PostgreSQL (columna `geo.zones.kind`).
    pub fn from_db(value: &str) -> Option<Self> {
        match value {
            "CITY_CENTER" => Some(Self::CityCenter),
            "TOURIST_AREA" => Some(Self::TouristArea),
            "AIRPORT" => Some(Self::Airport),
            "RESTRICTED" => Some(Self::Restricted),
            _ => None,
        }
    }

    /// Texto equivalente en PostgreSQL (y en el estado de presencia de Redis).
    pub fn as_db(self) -> &'static str {
        match self {
            Self::CityCenter => "CITY_CENTER",
            Self::TouristArea => "TOURIST_AREA",
            Self::Airport => "AIRPORT",
            Self::Restricted => "RESTRICTED",
        }
    }
}

/// Un aeropuerto cargado en memoria.
#[derive(Debug, Clone, PartialEq)]
pub struct AirportRecord {
    /// Código IATA ("MAD").
    pub iata_code: String,
    /// Código OACI ("LEMD"), vacío si no se conoce.
    pub icao_code: String,
    /// Nombre oficial.
    pub name: String,
    /// Ciudad a la que sirve.
    pub city: String,
    /// País ISO 3166-1 alfa-2.
    pub country_code: String,
    /// Posición.
    pub location: LatLng,
}

/// Una zona (geofence) cargada en memoria.
#[derive(Debug, Clone)]
pub struct ZoneRecord {
    /// Identificador estable.
    pub id: Uuid,
    /// Nombre corto único ("madrid-centro").
    pub slug: String,
    /// Nombre legible.
    pub name: String,
    /// Tipo de zona.
    pub kind: ZoneKind,
    /// Geometría ya validada, para los cálculos.
    pub geometry: MultiPolygon<f64>,
    /// La misma geometría en WKB, tal y como llegó de PostGIS, para enviarla
    /// por gRPC sin volver a serializarla (`Bytes` se comparte sin copiar).
    pub wkb: Bytes,
}

impl ZoneRecord {
    /// Distancia en metros desde `point` hasta la zona (0 si está dentro o en el borde).
    ///
    /// La usa la histéresis del geofencing: "¿se ha alejado lo bastante del
    /// borde como para dar por buena la salida?".
    ///
    /// Cómo: `closest_point` busca el punto del contorno más cercano (en el
    /// plano longitud/latitud) y luego medimos la distancia geodésica real
    /// hasta él. Para márgenes de decenas o cientos de metros el error de usar
    /// el plano para ELEGIR el punto es despreciable (centímetros).
    pub fn distance_m(&self, point: LatLng) -> f64 {
        let geo_point = point.to_point();
        if self.geometry.intersects(&geo_point) {
            return 0.0;
        }
        match self.geometry.closest_point(&geo_point) {
            Closest::Intersection(_) => 0.0,
            Closest::SinglePoint(nearest) => {
                // geo usa X = longitud, Y = latitud. Si por algún motivo el
                // punto no fuese válido, "infinito" = claramente fuera.
                LatLng::new(nearest.y(), nearest.x()).map_or(f64::INFINITY, |n| point.geodesic_distance_m(n))
            }
            // Geometría vacía o degenerada: no hay borde al que acercarse.
            Closest::Indeterminate => f64::INFINITY,
        }
    }
}

/// Entrada del índice de zonas: la caja que envuelve la zona + su posición
/// en el vector de zonas. El índice guarda cajas (baratas de comparar); la
/// comprobación exacta con el polígono se hace después, solo con las candidatas.
#[derive(Debug, Clone)]
struct ZoneEnvelope {
    envelope: AABB<[f64; 2]>,
    index: usize,
}

impl RTreeObject for ZoneEnvelope {
    type Envelope = AABB<[f64; 2]>;

    fn envelope(&self) -> Self::Envelope {
        self.envelope
    }
}

/// Foto inmutable de los datos geoespaciales.
#[derive(Debug)]
pub struct GeoSnapshot {
    version: i64,
    built_at: SystemTime,
    airports: Vec<AirportRecord>,
    /// Puntos 3D (vector unitario) con el índice del aeropuerto como dato.
    airport_index: RTree<GeomWithData<[f64; 3], usize>>,
    zones: Vec<ZoneRecord>,
    zone_index: RTree<ZoneEnvelope>,
    zones_by_id: HashMap<Uuid, usize>,
}

impl GeoSnapshot {
    /// Construye la foto y sus índices. `version` es la versión del conjunto
    /// de datos en PostgreSQL (`geo.dataset_version`).
    ///
    /// `bulk_load` construye el R-tree de una vez, más rápido y mejor
    /// equilibrado que insertar uno a uno.
    pub fn build(version: i64, airports: Vec<AirportRecord>, zones: Vec<ZoneRecord>) -> Self {
        let airport_points = airports.iter().enumerate().map(|(i, a)| GeomWithData::new(a.location.to_unit_vector(), i)).collect();

        // Si por error llegasen dos zonas con el mismo id, nos quedamos con la
        // primera: un id debe identificar una sola zona.
        let mut zones_by_id = HashMap::with_capacity(zones.len());
        let mut unique_zones = Vec::with_capacity(zones.len());
        for zone in zones {
            if let std::collections::hash_map::Entry::Vacant(slot) = zones_by_id.entry(zone.id) {
                slot.insert(unique_zones.len());
                unique_zones.push(zone);
            }
        }
        let zone_envelopes = unique_zones
            .iter()
            .enumerate()
            .filter_map(|(index, zone)| {
                zone.geometry.bounding_rect().map(|rect| ZoneEnvelope {
                    envelope: AABB::from_corners([rect.min().x, rect.min().y], [rect.max().x, rect.max().y]),
                    index,
                })
            })
            .collect();

        Self {
            version,
            built_at: SystemTime::now(),
            airports,
            airport_index: RTree::bulk_load(airport_points),
            zones: unique_zones,
            zone_index: RTree::bulk_load(zone_envelopes),
            zones_by_id,
        }
    }

    /// Versión de los datos de PostgreSQL con la que se construyó.
    pub fn version(&self) -> i64 {
        self.version
    }

    /// Momento de construcción.
    pub fn built_at(&self) -> SystemTime {
        self.built_at
    }

    /// Número de aeropuertos cargados.
    pub fn airport_count(&self) -> usize {
        self.airports.len()
    }

    /// Número de zonas cargadas.
    pub fn zone_count(&self) -> usize {
        self.zones.len()
    }

    /// Los `limit` aeropuertos más cercanos a `point`, ordenados por distancia
    /// geodésica real. `max_distance_m` (opcional) limita el radio.
    ///
    /// Cómo funciona: el R-tree devuelve candidatos de cerca a lejos según la
    /// distancia sobre una esfera. Para cada uno calculamos la distancia real
    /// sobre el elipsoide. Paramos cuando el siguiente candidato, incluso con
    /// el margen de error de la esfera, ya no puede mejorar a los que tenemos.
    /// Así el resultado es exacto sin calcular la distancia a los 1.000+ aeropuertos.
    pub fn nearest_airports(&self, point: LatLng, limit: usize, max_distance_m: Option<f64>) -> Vec<(&AirportRecord, f64)> {
        if limit == 0 {
            return Vec::new();
        }
        let query = point.to_unit_vector();
        let mut best: Vec<(&AirportRecord, f64)> = Vec::with_capacity(limit + 1);
        for (candidate, chord_squared) in self.airport_index.nearest_neighbor_iter_with_distance_2(&query) {
            let lower_bound = surface_distance_for_chord(chord_squared.sqrt()) * (1.0 - ELLIPSOID_TOLERANCE);
            if max_distance_m.is_some_and(|max| lower_bound > max) {
                break;
            }
            if best.len() == limit && best.last().is_some_and(|(_, worst)| lower_bound > *worst) {
                break;
            }
            let Some(airport) = self.airports.get(candidate.data) else { continue };
            let distance = point.geodesic_distance_m(airport.location);
            if max_distance_m.is_some_and(|max| distance > max) {
                continue;
            }
            best.push((airport, distance));
            // Orden estable y determinista: por distancia y, si empatan, por código.
            best.sort_by(|a, b| a.1.total_cmp(&b.1).then_with(|| a.0.iata_code.cmp(&b.0.iata_code)));
            best.truncate(limit);
        }
        best
    }

    /// Zonas que contienen `point` (el borde cuenta como dentro), ordenadas
    /// por slug para que la respuesta sea siempre la misma.
    pub fn zones_containing(&self, point: LatLng) -> Vec<&ZoneRecord> {
        let probe = AABB::from_point([point.lon(), point.lat()]);
        let geo_point = point.to_point();
        let mut found: Vec<&ZoneRecord> = self
            .zone_index
            .locate_in_envelope_intersecting(&probe)
            .filter_map(|entry| self.zones.get(entry.index))
            .filter(|zone| zone.geometry.intersects(&geo_point))
            .collect();
        found.sort_by(|a, b| a.slug.cmp(&b.slug));
        found
    }

    /// Zonas cuya caja toca el rectángulo `[min, max]` (longitud, latitud),
    /// ordenadas por slug. Es lo que pinta el mapa de la app: todas las zonas
    /// visibles en pantalla. Basta con la caja (no el polígono exacto): una
    /// zona que asoma por la esquina también debe dibujarse.
    pub fn zones_in_box(&self, min: [f64; 2], max: [f64; 2]) -> Vec<&ZoneRecord> {
        let area = AABB::from_corners(min, max);
        let mut found: Vec<&ZoneRecord> =
            self.zone_index.locate_in_envelope_intersecting(&area).filter_map(|entry| self.zones.get(entry.index)).collect();
        found.sort_by(|a, b| a.slug.cmp(&b.slug));
        found
    }

    /// Busca una zona por id.
    pub fn zone(&self, id: &Uuid) -> Option<&ZoneRecord> {
        self.zones_by_id.get(id).and_then(|&i| self.zones.get(i))
    }
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use crate::spatial::wkb::encode_multipolygon;
    use geo_types::polygon;

    pub(crate) fn ll(lat: f64, lon: f64) -> LatLng {
        match LatLng::new(lat, lon) {
            Ok(p) => p,
            Err(e) => unreachable!("coordenada de test inválida: {e}"),
        }
    }

    pub(crate) fn airport(iata: &str, lat: f64, lon: f64) -> AirportRecord {
        AirportRecord {
            iata_code: iata.into(),
            icao_code: String::new(),
            name: format!("Aeropuerto {iata}"),
            city: String::new(),
            country_code: "ES".into(),
            location: ll(lat, lon),
        }
    }

    /// Zona rectangular de prueba.
    pub(crate) fn rect_zone(id: u128, slug: &str, min_lon: f64, min_lat: f64, max_lon: f64, max_lat: f64) -> ZoneRecord {
        let geometry = MultiPolygon::new(vec![polygon![
            (x: min_lon, y: min_lat), (x: max_lon, y: min_lat), (x: max_lon, y: max_lat),
            (x: min_lon, y: max_lat), (x: min_lon, y: min_lat),
        ]]);
        let wkb = encode_multipolygon(&geometry).unwrap_or_default();
        ZoneRecord { id: Uuid::from_u128(id), slug: slug.into(), name: slug.into(), kind: ZoneKind::TouristArea, geometry, wkb }
    }

    /// Foto con aeropuertos reales (coordenadas de OurAirports) y dos zonas en Madrid.
    pub(crate) fn sample_snapshot() -> GeoSnapshot {
        GeoSnapshot::build(
            7,
            vec![
                airport("MAD", 40.493407, -3.572249),
                airport("BCN", 41.2971, 2.07846),
                airport("CDG", 49.009724, 2.547778),
                airport("NRT", 35.76858, 140.388714),
                airport("SUV", -18.043301, 178.559998), // Suva (Fiyi), junto al antimeridiano
            ],
            vec![
                rect_zone(1, "madrid-centro", -3.714, 40.411, -3.693, 40.425),
                rect_zone(2, "madrid-sol", -3.706, 40.415, -3.701, 40.418),
                rect_zone(3, "paris-louvre", 2.3315, 48.859, 2.34, 48.8625),
            ],
        )
    }

    #[test]
    fn aeropuerto_mas_cercano_a_sol_es_barajas() {
        let snap = sample_snapshot();
        let result = snap.nearest_airports(ll(40.4168, -3.7038), 2, None);
        let codes: Vec<_> = result.iter().map(|(a, _)| a.iata_code.as_str()).collect();
        assert_eq!(codes, ["MAD", "BCN"]);
        // Sol → Barajas: ~13 km.
        assert!((result[0].1 - 13_000.0).abs() < 1_500.0, "{}", result[0].1);
    }

    #[test]
    fn el_radio_maximo_filtra() {
        let snap = sample_snapshot();
        assert_eq!(snap.nearest_airports(ll(40.4168, -3.7038), 5, Some(20_000.0)).len(), 1);
        assert!(snap.nearest_airports(ll(0.0, -30.0), 5, Some(100_000.0)).is_empty());
    }

    #[test]
    fn cerca_del_antimeridiano_encuentra_fiyi() {
        // Un punto en longitud -179,9 está a ~170 km de Suva (178,56 E).
        let snap = sample_snapshot();
        let result = snap.nearest_airports(ll(-17.5, -179.9), 1, None);
        assert_eq!(result.first().map(|(a, _)| a.iata_code.as_str()), Some("SUV"));
    }

    #[test]
    fn coincide_con_la_fuerza_bruta() {
        // El atajo del R-tree debe dar EXACTAMENTE lo mismo que medir todo.
        let snap = sample_snapshot();
        for (lat, lon) in [(40.0, -3.0), (45.0, 2.4), (-20.0, 179.0), (60.0, 100.0), (-89.0, 0.0)] {
            let p = ll(lat, lon);
            let mut brute: Vec<_> = snap.airports.iter().map(|a| (a.iata_code.clone(), p.geodesic_distance_m(a.location))).collect();
            brute.sort_by(|a, b| a.1.total_cmp(&b.1));
            let fast: Vec<_> = snap.nearest_airports(p, 3, None).into_iter().map(|(a, d)| (a.iata_code.clone(), d)).collect();
            assert_eq!(fast, brute[..3].to_vec(), "punto {lat},{lon}");
        }
    }

    #[test]
    fn distancia_a_una_zona() {
        let snap = sample_snapshot();
        let Some(sol) = snap.zone(&Uuid::from_u128(2)) else { unreachable!("la zona 2 existe") };
        // Dentro (y en el borde) la distancia es 0.
        assert_eq!(sol.distance_m(ll(40.4165, -3.7035)), 0.0);
        assert_eq!(sol.distance_m(ll(40.418, -3.703)), 0.0);
        // 0,0005° de latitud al norte del borde ≈ 55,5 m.
        let d = sol.distance_m(ll(40.4185, -3.703));
        assert!((d - 55.5).abs() < 1.0, "{d}");
    }

    #[test]
    fn zonas_que_contienen_un_punto() {
        let snap = sample_snapshot();
        let slugs = |p| snap.zones_containing(p).iter().map(|z| z.slug.clone()).collect::<Vec<_>>();
        assert_eq!(slugs(ll(40.4168, -3.7038)), ["madrid-centro", "madrid-sol"]);
        assert_eq!(slugs(ll(40.4200, -3.7100)), ["madrid-centro"]);
        assert!(slugs(ll(41.38, 2.17)).is_empty());
        // El borde cuenta como dentro.
        assert_eq!(slugs(ll(40.411, -3.70)), ["madrid-centro"]);
    }

    #[test]
    fn zonas_visibles_en_un_rectangulo() {
        let snap = sample_snapshot();
        let slugs = |min, max| snap.zones_in_box(min, max).iter().map(|z| z.slug.clone()).collect::<Vec<_>>();
        // Un rectángulo sobre el centro de Madrid ve las dos zonas de Madrid.
        assert_eq!(slugs([-3.72, 40.40], [-3.69, 40.43]), ["madrid-centro", "madrid-sol"]);
        // En mitad del Atlántico, nada.
        assert!(slugs([-30.0, 30.0], [-29.0, 31.0]).is_empty());
    }

    #[test]
    fn busca_zona_por_id_e_ignora_duplicados() {
        let mut zones = vec![rect_zone(9, "a", 0.0, 0.0, 1.0, 1.0)];
        zones.push(rect_zone(9, "b", 5.0, 5.0, 6.0, 6.0));
        let snap = GeoSnapshot::build(1, vec![], zones);
        assert_eq!(snap.zone_count(), 1);
        assert_eq!(snap.zone(&Uuid::from_u128(9)).map(|z| z.slug.as_str()), Some("a"));
        assert!(snap.zone(&Uuid::from_u128(10)).is_none());
    }
}
