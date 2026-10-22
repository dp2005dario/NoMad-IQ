//! Coordenadas validadas y medidas sobre la Tierra.
//!
//! Analogía: una dirección postal mal escrita hace que el cartero se pierda.
//! Una coordenada fuera de rango (latitud 120°) o "no numérica" (NaN) hace lo
//! mismo con los cálculos. Por eso [`LatLng`] solo se puede crear validando:
//! si tienes un `LatLng`, es correcto. El compilador lo garantiza.

use geo::{Bearing, Distance, Geodesic, Point};
use thiserror::Error;

/// Radio medio de la Tierra en metros (IUGG). Se usa para pasar de distancias
/// "en línea recta a través de la Tierra" (cuerdas) a distancias sobre la
/// superficie en el índice de aeropuertos.
pub const EARTH_MEAN_RADIUS_M: f64 = 6_371_008.8;

/// Errores al construir una coordenada.
#[derive(Debug, Clone, Copy, PartialEq, Error)]
pub enum CoordError {
    /// NaN o infinito: suele indicar un fallo en quien envía los datos.
    #[error("la coordenada no es un número finito")]
    NotFinite,
    /// La latitud va de -90 (polo sur) a 90 (polo norte).
    #[error("latitud {0} fuera del rango [-90, 90]")]
    LatitudeOutOfRange(f64),
    /// La longitud va de -180 a 180 (el meridiano de Greenwich es 0).
    #[error("longitud {0} fuera del rango [-180, 180]")]
    LongitudeOutOfRange(f64),
}

/// Un punto de la Tierra en WGS84 (el sistema del GPS), ya validado.
///
/// Los campos son privados: la única forma de crear uno es [`LatLng::new`],
/// que valida. Es el patrón "parse, don't validate": validamos en la frontera
/// y el resto del programa trabaja con datos que ya sabe correctos.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct LatLng {
    lat: f64,
    lon: f64,
}

impl LatLng {
    /// Crea una coordenada comprobando que es finita y está en rango.
    pub fn new(lat: f64, lon: f64) -> Result<Self, CoordError> {
        if !lat.is_finite() || !lon.is_finite() {
            return Err(CoordError::NotFinite);
        }
        if !(-90.0..=90.0).contains(&lat) {
            return Err(CoordError::LatitudeOutOfRange(lat));
        }
        if !(-180.0..=180.0).contains(&lon) {
            return Err(CoordError::LongitudeOutOfRange(lon));
        }
        Ok(Self { lat, lon })
    }

    /// Latitud en grados.
    pub fn lat(self) -> f64 {
        self.lat
    }

    /// Longitud en grados.
    pub fn lon(self) -> f64 {
        self.lon
    }

    /// Convierte a `geo::Point`. ¡Ojo! En geo (y en WKB) X = longitud e
    /// Y = latitud: el orden contrario al habitual "lat, lon".
    pub fn to_point(self) -> Point<f64> {
        Point::new(self.lon, self.lat)
    }

    /// Posición como vector 3D de longitud 1 (centro de la Tierra = origen).
    ///
    /// ¿Para qué? Para el índice de aeropuertos. Si buscásemos "el más cercano"
    /// comparando grados de latitud/longitud como si fueran un plano,
    /// fallaríamos cerca de los polos (allí un grado de longitud mide casi 0 m)
    /// y en el antimeridiano (Fiyi a 179,9° y Samoa a -179,9° parecerían
    /// lejísimos). En 3D, la distancia en línea recta entre dos puntos de la
    /// esfera (la "cuerda") crece siempre a la vez que la distancia sobre la
    /// superficie, en todo el planeta. Así el R-tree ordena bien en cualquier sitio.
    pub fn to_unit_vector(self) -> [f64; 3] {
        let (lat, lon) = (self.lat.to_radians(), self.lon.to_radians());
        [lat.cos() * lon.cos(), lat.cos() * lon.sin(), lat.sin()]
    }

    /// Distancia geodésica en metros sobre el elipsoide WGS84 (algoritmo de
    /// Karney, precisión milimétrica). Es la distancia "real" que recorrería
    /// un avión siguiendo la ruta más corta sobre la superficie.
    pub fn geodesic_distance_m(self, other: LatLng) -> f64 {
        Geodesic.distance(self.to_point(), other.to_point())
    }

    /// Rumbo inicial en grados [0, 360): 0 = norte, 90 = este.
    pub fn initial_bearing_deg(self, other: LatLng) -> f64 {
        let bearing = Geodesic.bearing(self.to_point(), other.to_point());
        // La librería puede devolver valores negativos (-90 = oeste):
        // los normalizamos a [0, 360).
        let normalized = bearing.rem_euclid(360.0);
        if normalized >= 360.0 { 0.0 } else { normalized }
    }
}

/// Convierte una distancia sobre la superficie (metros) en la cuerda
/// equivalente de la esfera unidad: 2·sen(θ/2), con θ el ángulo central.
pub fn chord_for_surface_distance(meters: f64) -> f64 {
    let theta = (meters / EARTH_MEAN_RADIUS_M).min(std::f64::consts::PI);
    2.0 * (theta / 2.0).sin()
}

/// Operación inversa: de cuerda (esfera unidad) a metros sobre la esfera.
pub fn surface_distance_for_chord(chord: f64) -> f64 {
    let half = (chord / 2.0).clamp(0.0, 1.0);
    2.0 * half.asin() * EARTH_MEAN_RADIUS_M
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ll(lat: f64, lon: f64) -> LatLng {
        match LatLng::new(lat, lon) {
            Ok(p) => p,
            Err(e) => unreachable!("coordenada de test inválida: {e}"),
        }
    }

    #[test]
    fn rechaza_coordenadas_invalidas() {
        assert_eq!(LatLng::new(f64::NAN, 0.0), Err(CoordError::NotFinite));
        assert_eq!(LatLng::new(0.0, f64::INFINITY), Err(CoordError::NotFinite));
        assert_eq!(LatLng::new(90.1, 0.0), Err(CoordError::LatitudeOutOfRange(90.1)));
        assert_eq!(LatLng::new(0.0, -180.5), Err(CoordError::LongitudeOutOfRange(-180.5)));
        assert!(LatLng::new(-90.0, 180.0).is_ok());
    }

    #[test]
    fn distancia_madrid_barcelona() {
        // Puerta del Sol → Plaza de Catalunya: ~505 km en línea recta.
        let d = ll(40.4168, -3.7038).geodesic_distance_m(ll(41.3874, 2.1686));
        assert!((d - 505_000.0).abs() < 3_000.0, "distancia inesperada: {d}");
    }

    #[test]
    fn rumbo_normalizado() {
        let origin = ll(0.0, 0.0);
        assert!((origin.initial_bearing_deg(ll(1.0, 0.0)) - 0.0).abs() < 1e-9);
        assert!((origin.initial_bearing_deg(ll(0.0, 1.0)) - 90.0).abs() < 1e-6);
        // Hacia el oeste: 270, nunca -90.
        assert!((origin.initial_bearing_deg(ll(0.0, -1.0)) - 270.0).abs() < 1e-6);
    }

    #[test]
    fn cuerda_y_distancia_son_inversas() {
        for meters in [0.0, 1.0, 1_000.0, 500_000.0, 10_000_000.0] {
            let back = surface_distance_for_chord(chord_for_surface_distance(meters));
            assert!((back - meters).abs() < 1e-3, "{meters} → {back}");
        }
    }

    #[test]
    fn el_antimeridiano_no_engana_al_vector_3d() {
        // 179,9° E y 179,9° O están a ~22 km, no a medio planeta.
        let a = ll(-17.0, 179.9).to_unit_vector();
        let b = ll(-17.0, -179.9).to_unit_vector();
        let chord = ((a[0] - b[0]).powi(2) + (a[1] - b[1]).powi(2) + (a[2] - b[2]).powi(2)).sqrt();
        assert!(surface_distance_for_chord(chord) < 25_000.0);
    }
}
