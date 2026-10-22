//! Lectura y escritura de geometrías en WKB (Well-Known Binary).
//!
//! WKB es el "idioma binario" estándar de las geometrías: PostGIS lo produce
//! con `ST_AsBinary`, lo entienden QGIS, GDAL, las librerías de mapas de
//! Android/iOS... Lo usamos de extremo a extremo (PostGIS → Rust → gRPC → app)
//! para no convertir polígonos campo a campo en cada salto.
//!
//! Todo lo que llega de fuera se valida aquí: tipo de geometría, tamaño
//! máximo, coordenadas finitas y en rango, y polígonos bien formados.

use bytes::Bytes;
use geo::{BoundingRect, Validation};
use geo_traits::to_geo::ToGeoGeometry;
use geo_types::{Geometry, LineString, MultiPolygon};
use thiserror::Error;
use wkb::Endianness;
use wkb::writer::WriteOptions;

/// Tamaño máximo aceptado para un WKB (8 MiB): protege la memoria frente a
/// geometrías gigantes por error o con mala intención.
pub const MAX_WKB_BYTES: usize = 8 * 1024 * 1024;

/// Errores al leer o escribir WKB.
#[derive(Debug, Error)]
pub enum WkbError {
    /// Bytes vacíos.
    #[error("WKB vacío")]
    Empty,
    /// Más grande que [`MAX_WKB_BYTES`].
    #[error("WKB demasiado grande: {0} bytes (máximo {MAX_WKB_BYTES})")]
    TooLarge(usize),
    /// Los bytes no son WKB válido (truncado, tipo desconocido...).
    #[error("WKB mal formado: {0}")]
    Malformed(String),
    /// Es WKB válido pero de otro tipo (por ejemplo, un punto en vez de un polígono).
    #[error("se esperaba {expected}, se recibió otro tipo de geometría")]
    WrongType {
        /// Tipo esperado.
        expected: &'static str,
    },
    /// Alguna coordenada es NaN/infinita o está fuera de rango.
    #[error("coordenadas fuera del rango de WGS84 o no numéricas")]
    OutOfRange,
    /// El polígono es geométricamente inválido (se cruza consigo mismo, etc.).
    #[error("polígono inválido: {0}")]
    InvalidPolygon(String),
    /// El polígono cruza el antimeridiano (±180°): debe partirse en dos.
    #[error("la geometría cruza el antimeridiano; pártela en dos polígonos")]
    CrossesAntimeridian,
    /// Error al escribir (no debería ocurrir al escribir en memoria).
    #[error("no se pudo escribir WKB: {0}")]
    Write(String),
}

/// Lee un WKB que debe ser `Polygon` o `MultiPolygon` y lo devuelve siempre
/// como `MultiPolygon` validado (un polígono suelto es un MultiPolygon de uno:
/// así el resto del código trata un único tipo).
pub fn decode_multipolygon(buf: &[u8]) -> Result<MultiPolygon<f64>, WkbError> {
    if buf.is_empty() {
        return Err(WkbError::Empty);
    }
    if buf.len() > MAX_WKB_BYTES {
        return Err(WkbError::TooLarge(buf.len()));
    }
    let parsed = wkb::reader::read_wkb(buf).map_err(|e| WkbError::Malformed(e.to_string()))?;
    // try_to_geometry devuelve None con geometrías vacías raras (un punto sin
    // coordenadas): lo tratamos como mal formado.
    let geometry = parsed.try_to_geometry().ok_or_else(|| WkbError::Malformed("geometría vacía o no soportada".into()))?;
    let multi = match geometry {
        Geometry::Polygon(p) => MultiPolygon::new(vec![p]),
        Geometry::MultiPolygon(mp) => mp,
        _ => return Err(WkbError::WrongType { expected: "Polygon o MultiPolygon" }),
    };
    if multi.0.is_empty() {
        return Err(WkbError::Malformed("MultiPolygon sin polígonos".into()));
    }
    validate_multipolygon(&multi)?;
    Ok(multi)
}

/// Comprueba rango, validez geométrica y antimeridiano.
fn validate_multipolygon(multi: &MultiPolygon<f64>) -> Result<(), WkbError> {
    let in_range = multi.0.iter().all(|polygon| {
        std::iter::once(polygon.exterior())
            .chain(polygon.interiors())
            .flat_map(|ring| ring.coords())
            .all(|c| c.x.is_finite() && c.y.is_finite() && (-180.0..=180.0).contains(&c.x) && (-90.0..=90.0).contains(&c.y))
    });
    if !in_range {
        return Err(WkbError::OutOfRange);
    }
    if let Err(e) = multi.check_validation() {
        return Err(WkbError::InvalidPolygon(e.to_string()));
    }
    // Un polígono que "da la vuelta" por el antimeridiano aparece, en grados,
    // como uno enorme que ocupa más de media Tierra de ancho. Ninguna zona
    // turística mide eso: es casi seguro que está mal dibujado.
    let rect = multi.bounding_rect().ok_or(WkbError::Malformed("sin extensión".into()))?;
    if rect.width() > 180.0 {
        return Err(WkbError::CrossesAntimeridian);
    }
    Ok(())
}

/// Escribe un `MultiPolygon` como WKB (little-endian, el orden de los
/// procesadores x86 y ARM: se lee sin dar la vuelta a los bytes).
pub fn encode_multipolygon(multi: &MultiPolygon<f64>) -> Result<Bytes, WkbError> {
    let mut out = Vec::with_capacity(wkb::writer::multi_polygon_wkb_size(multi));
    wkb::writer::write_multi_polygon(&mut out, multi, &options()).map_err(|e| WkbError::Write(e.to_string()))?;
    Ok(Bytes::from(out))
}

/// Escribe un `LineString` (un recorrido) como WKB.
pub fn encode_line_string(line: &LineString<f64>) -> Result<Bytes, WkbError> {
    let mut out = Vec::with_capacity(wkb::writer::line_string_wkb_size(line));
    wkb::writer::write_line_string(&mut out, line, &options()).map_err(|e| WkbError::Write(e.to_string()))?;
    Ok(Bytes::from(out))
}

fn options() -> WriteOptions {
    WriteOptions { endianness: Endianness::LittleEndian }
}

#[cfg(test)]
mod tests {
    use super::*;
    use geo_types::{coord, polygon};

    fn square(x: f64, y: f64, size: f64) -> geo_types::Polygon<f64> {
        polygon![
            (x: x, y: y),
            (x: x + size, y: y),
            (x: x + size, y: y + size),
            (x: x, y: y + size),
            (x: x, y: y),
        ]
    }

    #[test]
    fn ida_y_vuelta_multipolygon() -> Result<(), WkbError> {
        let original = MultiPolygon::new(vec![square(-3.71, 40.41, 0.01), square(-3.69, 40.40, 0.005)]);
        let bytes = encode_multipolygon(&original)?;
        // Cabecera WKB: 1 byte de orden (1 = little-endian) + tipo 6 (MultiPolygon).
        assert_eq!(&bytes[..5], &[1, 6, 0, 0, 0]);
        assert_eq!(decode_multipolygon(&bytes)?, original);
        Ok(())
    }

    #[test]
    fn un_polygon_suelto_se_convierte_en_multipolygon() -> Result<(), WkbError> {
        let poly = square(2.33, 48.85, 0.01);
        let mut buf = Vec::new();
        wkb::writer::write_polygon(&mut buf, &poly, &options()).map_err(|e| WkbError::Write(e.to_string()))?;
        assert_eq!(decode_multipolygon(&buf)?, MultiPolygon::new(vec![poly]));
        Ok(())
    }

    #[test]
    fn rechaza_basura_tipos_y_rangos() {
        assert!(matches!(decode_multipolygon(&[]), Err(WkbError::Empty)));
        assert!(matches!(decode_multipolygon(&[1, 6, 0]), Err(WkbError::Malformed(_))));

        // Un punto no es un polígono.
        let mut point = Vec::new();
        let p = geo_types::Point::new(1.0, 2.0);
        assert!(wkb::writer::write_point(&mut point, &p, &options()).is_ok());
        assert!(matches!(decode_multipolygon(&point), Err(WkbError::WrongType { .. })));

        // Latitud 95: imposible.
        let bad = MultiPolygon::new(vec![square(10.0, 89.0, 6.0)]);
        let bytes = encode_multipolygon(&bad);
        assert!(matches!(bytes.map(|b| decode_multipolygon(&b)), Ok(Err(WkbError::OutOfRange))));
    }

    #[test]
    fn rechaza_poligono_que_se_cruza() {
        // Una "pajarita": los lados se cruzan en el centro.
        let bowtie = MultiPolygon::new(vec![polygon![
            (x: 0.0, y: 0.0), (x: 1.0, y: 1.0), (x: 1.0, y: 0.0), (x: 0.0, y: 1.0), (x: 0.0, y: 0.0),
        ]]);
        let result = encode_multipolygon(&bowtie).map(|b| decode_multipolygon(&b));
        assert!(matches!(result, Ok(Err(WkbError::InvalidPolygon(_)))));
    }

    #[test]
    fn rechaza_poligono_que_da_la_vuelta_al_mundo() {
        let wide = MultiPolygon::new(vec![polygon![
            (x: -179.0, y: -17.0), (x: 179.0, y: -17.0), (x: 179.0, y: -16.0), (x: -179.0, y: -16.0), (x: -179.0, y: -17.0),
        ]]);
        let result = encode_multipolygon(&wide).map(|b| decode_multipolygon(&b));
        assert!(matches!(result, Ok(Err(WkbError::CrossesAntimeridian))));
    }

    #[test]
    fn linestring_ida_y_vuelta() -> Result<(), WkbError> {
        let line = LineString::new(vec![coord! { x: -3.70, y: 40.41 }, coord! { x: 2.17, y: 41.38 }]);
        let bytes = encode_line_string(&line)?;
        let parsed = wkb::reader::read_wkb(&bytes).map_err(|e| WkbError::Malformed(e.to_string()))?;
        assert_eq!(parsed.try_to_geometry(), Some(Geometry::LineString(line)));
        Ok(())
    }
}
