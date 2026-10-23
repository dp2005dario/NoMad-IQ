//! API HTTP pública que usa la app móvil (siempre a través del proxy de borde).
//!
//! - `GET  /v1/zones?bbox=minLon,minLat,maxLon,maxLat` → zonas visibles en el
//!   mapa, en GeoJSON (el formato que MapLibre dibuja directamente).
//! - `POST /v1/positions` → la app manda un lote de posiciones GPS; cada una se
//!   publica en Kafka (`geo.user-positions.v1`) y el geofencing hace el resto.
//!
//! ¿Quién es el usuario? El proxy de borde ya comprobó su token con el
//! auth-gateway y nos pasa `X-User-ID` y `X-User-Roles`. Nos fiamos de esas
//! cabeceras SOLO porque a este puerto únicamente se llega con un certificado
//! de cliente (mTLS) del proxy: alguien de dentro de la red sin certificado no
//! puede inventárselas. (En local, con GRPC_INSECURE_DEV, no hay mTLS.)
//!
//! Privacidad: las posiciones no se guardan aquí; solo se reenvían a Kafka con
//! la clave `user_id` (todas las de una persona, en orden, al mismo consumidor).

use std::sync::Arc;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use axum::extract::rejection::{JsonRejection, QueryRejection};
use axum::extract::{DefaultBodyLimit, Query, State};
use axum::http::{HeaderMap, HeaderValue, StatusCode, header};
use axum::response::{IntoResponse, Response};
use axum::routing::{get, post};
use axum::{Json, Router};
use prost::Message;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use uuid::Uuid;

use crate::proto::common;
use crate::proto::geo as pb;
use crate::snapshot::SnapshotHandle;
use crate::spatial::coord::LatLng;
use crate::spatial::index::{ZoneKind, ZoneRecord};
use crate::stream::processor::{CONTENT_TYPE_PROTOBUF, EventSink, OutboundRecord, PRODUCER};

/// Cabeceras de identidad que pone el proxy de borde (las mismas que en el
/// ai-orchestrator y el notifier).
pub const HEADER_USER_ID: &str = "x-user-id";
pub const HEADER_USER_ROLES: &str = "x-user-roles";
const HEADER_REQUEST_ID: &str = "x-request-id";
/// Rol mínimo para usar la API (el auth-gateway emite USER y ADMIN).
const REQUIRED_ROLE: &str = "USER";
/// Nombre del mensaje publicado (cabecera `ce_type`).
pub const TYPE_USER_POSITION_REPORTED: &str = "nomadiq.geo.v1.UserPositionReported";

/// Lado máximo del rectángulo pedido, en grados (~220 km en el ecuador).
/// Un mapa con más zoom-out no enseña zonas turísticas útiles y una petición
/// de "el mundo entero" sería una forma barata de cargar el servidor.
pub const MAX_BBOX_SPAN_DEG: f64 = 2.0;
/// Zonas máximas por respuesta. Si hay más, se avisa con `truncated: true`.
pub const MAX_ZONES: usize = 300;
/// Posiciones máximas por lote (la app las agrupa para ahorrar batería).
pub const MAX_POSITIONS: usize = 50;
/// Tamaño máximo del cuerpo de una petición (50 posiciones caben de sobra).
const MAX_BODY_BYTES: usize = 16 * 1024;
/// Antigüedad máxima de una posición: más vieja ya no sirve para el geofencing.
const MAX_POSITION_AGE: Duration = Duration::from_secs(24 * 3600);
/// Margen para relojes de móvil adelantados.
const MAX_CLOCK_SKEW: Duration = Duration::from_secs(120);
/// Precisión máxima aceptada (m). Peor que esto no es una posición, es una conjetura.
const MAX_ACCURACY_M: f64 = 10_000.0;

/// Adónde se publican las posiciones.
#[derive(Debug)]
pub struct PositionsTarget<S> {
    /// Publicador (Kafka en producción, un vector en los tests).
    pub sink: Arc<S>,
    /// Topic de posiciones.
    pub topic: String,
}

/// Estado compartido por todas las peticiones.
#[derive(Debug)]
pub struct ApiState<S> {
    /// Foto geoespacial en memoria (zonas).
    pub snapshots: SnapshotHandle,
    /// None si el geofencing está desactivado: entonces no se aceptan posiciones.
    pub positions: Option<PositionsTarget<S>>,
}

/// Construye el router de la API.
pub fn router<S: EventSink>(state: ApiState<S>) -> Router {
    Router::new()
        .route("/v1/zones", get(zones::<S>))
        .route("/v1/positions", post(positions::<S>))
        .layer(DefaultBodyLimit::max(MAX_BODY_BYTES))
        .with_state(Arc::new(state))
}

// ---------------------------------------------------------------------------
// Errores: siempre en formato "problem+json" (RFC 9457), como el resto de servicios.

/// Error de la API con su código HTTP.
#[derive(Debug)]
pub struct ApiError {
    status: StatusCode,
    detail: String,
}

impl ApiError {
    fn new(status: StatusCode, detail: impl Into<String>) -> Self {
        Self { status, detail: detail.into() }
    }

    fn bad_request(detail: impl Into<String>) -> Self {
        Self::new(StatusCode::BAD_REQUEST, detail)
    }
}

impl IntoResponse for ApiError {
    fn into_response(self) -> Response {
        let body = json!({
            "type": "about:blank",
            "title": self.status.canonical_reason().unwrap_or("Error"),
            "status": self.status.as_u16(),
            "detail": self.detail,
        });
        let mut response = (self.status, Json(body)).into_response();
        response.headers_mut().insert(header::CONTENT_TYPE, HeaderValue::from_static("application/problem+json"));
        response
    }
}

// ---------------------------------------------------------------------------
// Identidad

/// Lee y valida la identidad que puso el proxy de borde.
fn principal(headers: &HeaderMap) -> Result<String, ApiError> {
    let user_id = headers.get(HEADER_USER_ID).and_then(|v| v.to_str().ok()).unwrap_or_default();
    if !valid_user_id(user_id) {
        return Err(ApiError::new(StatusCode::UNAUTHORIZED, "identidad ausente o inválida"));
    }
    let roles = headers.get(HEADER_USER_ROLES).and_then(|v| v.to_str().ok()).unwrap_or_default();
    let roles: Vec<&str> = roles.split(',').map(str::trim).filter(|r| !r.is_empty()).collect();
    if roles.iter().any(|r| r.len() > 32 || !r.bytes().all(|b| b.is_ascii_uppercase() || b == b'_')) {
        return Err(ApiError::new(StatusCode::UNAUTHORIZED, "roles inválidos"));
    }
    if !roles.contains(&REQUIRED_ROLE) {
        return Err(ApiError::new(StatusCode::FORBIDDEN, "se necesita el rol USER"));
    }
    Ok(user_id.to_owned())
}

/// Mismo formato que acepta el ai-orchestrator: `[A-Za-z0-9._:@-]{1,128}`.
fn valid_user_id(id: &str) -> bool {
    (1..=128).contains(&id.len()) && id.bytes().all(|b| b.is_ascii_alphanumeric() || matches!(b, b'.' | b'_' | b':' | b'@' | b'-'))
}

// ---------------------------------------------------------------------------
// GET /v1/zones

#[derive(Debug, Deserialize)]
struct ZonesQuery {
    /// "minLon,minLat,maxLon,maxLat" (el orden de GeoJSON y MapLibre).
    bbox: String,
}

/// Rectángulo validado.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct BoundingBox {
    /// Esquina suroeste [longitud, latitud].
    pub min: [f64; 2],
    /// Esquina noreste [longitud, latitud].
    pub max: [f64; 2],
}

impl BoundingBox {
    /// Lee "minLon,minLat,maxLon,maxLat" y comprueba que tenga sentido.
    pub fn parse(raw: &str) -> Result<Self, String> {
        let numbers: Vec<f64> = raw
            .split(',')
            .map(|p| p.trim().parse::<f64>())
            .collect::<Result<_, _>>()
            .map_err(|_| "bbox debe ser 4 números: minLon,minLat,maxLon,maxLat".to_owned())?;
        let [min_lon, min_lat, max_lon, max_lat] = numbers[..] else {
            return Err("bbox debe ser 4 números: minLon,minLat,maxLon,maxLat".into());
        };
        // LatLng::new rechaza NaN, infinitos y valores fuera del planeta.
        LatLng::new(min_lat, min_lon).map_err(|e| format!("bbox: esquina suroeste inválida ({e})"))?;
        LatLng::new(max_lat, max_lon).map_err(|e| format!("bbox: esquina noreste inválida ({e})"))?;
        if min_lon >= max_lon || min_lat >= max_lat {
            // (Un rectángulo que cruce el meridiano 180 llegaría con min > max:
            // la app lo parte en dos peticiones; aquí no se admite.)
            return Err("bbox: el mínimo debe ser menor que el máximo".into());
        }
        if max_lon - min_lon > MAX_BBOX_SPAN_DEG || max_lat - min_lat > MAX_BBOX_SPAN_DEG {
            return Err(format!("bbox demasiado grande: como mucho {MAX_BBOX_SPAN_DEG}° por lado (acerca el mapa)"));
        }
        Ok(Self { min: [min_lon, min_lat], max: [max_lon, max_lat] })
    }
}

async fn zones<S: EventSink>(
    State(state): State<Arc<ApiState<S>>>,
    headers: HeaderMap,
    query: Result<Query<ZonesQuery>, QueryRejection>,
) -> Result<Response, ApiError> {
    principal(&headers)?;
    let Query(query) = query.map_err(|_| ApiError::bad_request("falta el parámetro bbox"))?;
    let bbox = BoundingBox::parse(&query.bbox).map_err(ApiError::bad_request)?;
    let Some(snapshot) = state.snapshots.load() else {
        return Err(ApiError::new(StatusCode::SERVICE_UNAVAILABLE, "datos geoespaciales aún no cargados"));
    };
    let found = snapshot.zones_in_box(bbox.min, bbox.max);
    let truncated = found.len() > MAX_ZONES;
    let features: Vec<Value> = found.iter().take(MAX_ZONES).map(|zone| zone_feature(zone)).collect();
    let body = json!({
        "type": "FeatureCollection",
        "features": features,
        "truncated": truncated,
        // La app puede guardar la respuesta y no volver a dibujar si no cambió.
        "dataset_version": snapshot.version(),
    });
    let mut response = Json(body).into_response();
    // "private": no la guarda ningún proxy intermedio. Las zonas cambian poco.
    response.headers_mut().insert(header::CACHE_CONTROL, HeaderValue::from_static("private, max-age=60"));
    Ok(response)
}

/// Una zona como "Feature" de GeoJSON. Coordenadas con 6 decimales (~10 cm):
/// más precisión solo haría la respuesta más pesada.
fn zone_feature(zone: &ZoneRecord) -> Value {
    let round = |v: f64| (v * 1e6).round() / 1e6;
    let polygons: Vec<Value> = zone
        .geometry
        .0
        .iter()
        .map(|polygon| {
            let rings: Vec<Value> = std::iter::once(polygon.exterior())
                .chain(polygon.interiors())
                .map(|ring| Value::Array(ring.0.iter().map(|c| json!([round(c.x), round(c.y)])).collect()))
                .collect();
            Value::Array(rings)
        })
        .collect();
    json!({
        "type": "Feature",
        "id": zone.id.to_string(),
        "geometry": { "type": "MultiPolygon", "coordinates": polygons },
        "properties": {
            "slug": zone.slug,
            "name": zone.name,
            "kind": kind_name(zone.kind),
        },
    })
}

fn kind_name(kind: ZoneKind) -> &'static str {
    match kind {
        ZoneKind::CityCenter => "city_center",
        ZoneKind::TouristArea => "tourist_area",
        ZoneKind::Airport => "airport",
        ZoneKind::Restricted => "restricted",
    }
}

// ---------------------------------------------------------------------------
// POST /v1/positions

/// Lote de posiciones que manda la app.
#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct PositionBatch {
    /// Idioma de la app (BCP 47, "es-ES"), para las audioguías. Opcional.
    #[serde(default)]
    pub language: String,
    /// Posiciones, en cualquier orden (se ordenan aquí).
    pub positions: Vec<PositionIn>,
}

/// Una posición GPS.
#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct PositionIn {
    /// Latitud.
    pub lat: f64,
    /// Longitud.
    pub lon: f64,
    /// Precisión horizontal en metros (radio de incertidumbre).
    pub accuracy_m: f64,
    /// Cuándo la tomó el GPS (milisegundos desde 1970).
    pub recorded_at_ms: i64,
}

#[derive(Debug, Serialize)]
struct Accepted {
    accepted: usize,
}

async fn positions<S: EventSink>(
    State(state): State<Arc<ApiState<S>>>,
    headers: HeaderMap,
    body: Result<Json<PositionBatch>, JsonRejection>,
) -> Result<Response, ApiError> {
    let user_id = principal(&headers)?;
    let Some(target) = state.positions.as_ref() else {
        return Err(ApiError::new(StatusCode::SERVICE_UNAVAILABLE, "el geofencing está desactivado"));
    };
    let Json(batch) = body.map_err(|e| ApiError::bad_request(format!("cuerpo inválido: {}", e.body_text())))?;
    let now_ms = now_ms();
    let positions = validate_batch(&batch, now_ms).map_err(ApiError::bad_request)?;
    let language = clean_language(&batch.language);
    let correlation_id = headers
        .get(HEADER_REQUEST_ID)
        .and_then(|v| v.to_str().ok())
        .filter(|v| v.len() <= 64 && v.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-'))
        .unwrap_or_default()
        .to_owned();

    // En orden de tiempo y una detrás de otra: así llegan a Kafka (y al
    // geofencing) en el mismo orden en que ocurrieron.
    for position in &positions {
        let event_id = Uuid::new_v4();
        let event = pb::UserPositionReported {
            metadata: Some(common::EventMetadata {
                event_id: event_id.to_string(),
                occurred_at: Some(prost_types::Timestamp {
                    seconds: position.recorded_at_ms.div_euclid(1000),
                    nanos: i32::try_from(position.recorded_at_ms.rem_euclid(1000) * 1_000_000).unwrap_or(0),
                }),
                producer: PRODUCER.to_owned(),
                correlation_id: correlation_id.clone(),
            }),
            user_id: user_id.clone(),
            position: Some(pb::LatLng { latitude: position.lat, longitude: position.lon }),
            horizontal_accuracy_meters: position.accuracy_m,
            preferred_language: language.clone(),
        };
        let record = OutboundRecord {
            topic: target.topic.clone(),
            key: user_id.as_bytes().to_vec(),
            payload: event.encode_to_vec(),
            headers: vec![
                ("content-type".into(), CONTENT_TYPE_PROTOBUF.into()),
                ("ce_specversion".into(), b"1.0".to_vec()),
                ("ce_id".into(), event_id.to_string().into_bytes()),
                ("ce_type".into(), TYPE_USER_POSITION_REPORTED.into()),
                ("ce_source".into(), PRODUCER.into()),
                ("ce_time".into(), humantime::format_rfc3339_millis(SystemTime::now()).to_string().into_bytes()),
            ],
        };
        if let Err(e) = target.sink.send(record).await {
            // Nunca se registra la posición (dato personal), solo el fallo.
            tracing::warn!(error = %e, "no se pudo publicar una posición");
            return Err(ApiError::new(StatusCode::SERVICE_UNAVAILABLE, "no se pudo registrar la posición; reinténtalo"));
        }
    }
    let mut response = (StatusCode::ACCEPTED, Json(Accepted { accepted: positions.len() })).into_response();
    response.headers_mut().insert(header::CACHE_CONTROL, HeaderValue::from_static("no-store"));
    Ok(response)
}

/// Comprueba el lote entero (o todo o nada) y lo devuelve ordenado por tiempo.
pub fn validate_batch(batch: &PositionBatch, now_ms: i64) -> Result<Vec<PositionIn>, String> {
    if batch.positions.is_empty() {
        return Err("positions está vacío".into());
    }
    if batch.positions.len() > MAX_POSITIONS {
        return Err(format!("como mucho {MAX_POSITIONS} posiciones por lote"));
    }
    let oldest = now_ms - millis(MAX_POSITION_AGE);
    let newest = now_ms + millis(MAX_CLOCK_SKEW);
    for (i, p) in batch.positions.iter().enumerate() {
        LatLng::new(p.lat, p.lon).map_err(|e| format!("positions[{i}]: coordenadas inválidas ({e})"))?;
        if !p.accuracy_m.is_finite() || p.accuracy_m < 0.0 || p.accuracy_m > MAX_ACCURACY_M {
            return Err(format!("positions[{i}]: accuracy_m debe estar entre 0 y {MAX_ACCURACY_M}"));
        }
        if p.recorded_at_ms < oldest || p.recorded_at_ms > newest {
            return Err(format!("positions[{i}]: recorded_at_ms fuera de las últimas 24 h"));
        }
    }
    let mut sorted = batch.positions.clone();
    sorted.sort_by_key(|p| p.recorded_at_ms);
    Ok(sorted)
}

/// Idioma con forma BCP 47 sencilla ("es", "pt-BR") o vacío. El geofencing
/// se queda luego solo con la parte principal.
pub fn clean_language(raw: &str) -> String {
    let raw = raw.trim();
    let mut parts = raw.split('-');
    let primary_ok = parts.next().is_some_and(|p| (2..=3).contains(&p.len()) && p.bytes().all(|b| b.is_ascii_alphabetic()));
    let rest_ok = parts.all(|p| (1..=8).contains(&p.len()) && p.bytes().all(|b| b.is_ascii_alphanumeric()));
    if raw.len() <= 35 && primary_ok && rest_ok { raw.to_owned() } else { String::new() }
}

fn millis(d: Duration) -> i64 {
    i64::try_from(d.as_millis()).unwrap_or(i64::MAX)
}

fn now_ms() -> i64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| i64::try_from(d.as_millis()).unwrap_or(i64::MAX)).unwrap_or_default()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn bbox_rules() -> Result<(), String> {
        let ok = BoundingBox::parse("-3.75,40.38,-3.65,40.45")?;
        assert_eq!(ok.min, [-3.75, 40.38]);
        assert!(BoundingBox::parse("1,2,3").is_err());
        assert!(BoundingBox::parse("a,b,c,d").is_err());
        assert!(BoundingBox::parse("0,0,0,0").is_err(), "vacío");
        assert!(BoundingBox::parse("10,0,0,1").is_err(), "invertido");
        assert!(BoundingBox::parse("0,0,5,1").is_err(), "demasiado grande");
        assert!(BoundingBox::parse("0,95,1,96").is_err(), "fuera del planeta");
        assert!(BoundingBox::parse("NaN,0,1,1").is_err());
        Ok(())
    }

    fn batch(points: Vec<(f64, f64, f64, i64)>) -> PositionBatch {
        PositionBatch {
            language: "es".into(),
            positions: points
                .into_iter()
                .map(|(lat, lon, accuracy_m, recorded_at_ms)| PositionIn { lat, lon, accuracy_m, recorded_at_ms })
                .collect(),
        }
    }

    #[test]
    fn batch_rules() -> Result<(), String> {
        let now = 1_800_000_000_000;
        let sorted = validate_batch(&batch(vec![(40.4, -3.7, 10.0, now - 1000), (40.4, -3.7, 10.0, now - 5000)]), now)?;
        assert!(sorted[0].recorded_at_ms < sorted[1].recorded_at_ms, "se ordenan por tiempo");
        assert!(validate_batch(&batch(vec![]), now).is_err());
        assert!(validate_batch(&batch(vec![(91.0, 0.0, 5.0, now)]), now).is_err());
        assert!(validate_batch(&batch(vec![(0.0, 0.0, -1.0, now)]), now).is_err());
        assert!(validate_batch(&batch(vec![(0.0, 0.0, f64::NAN, now)]), now).is_err());
        assert!(validate_batch(&batch(vec![(0.0, 0.0, 5.0, now - 25 * 3_600_000)]), now).is_err(), "demasiado vieja");
        assert!(validate_batch(&batch(vec![(0.0, 0.0, 5.0, now + 600_000)]), now).is_err(), "del futuro");
        assert!(validate_batch(&batch(vec![(0.0, 0.0, 5.0, now); MAX_POSITIONS + 1]), now).is_err());
        Ok(())
    }

    #[test]
    fn languages() {
        assert_eq!(clean_language("es"), "es");
        assert_eq!(clean_language(" pt-BR "), "pt-BR");
        assert_eq!(clean_language("zh-Hant-TW"), "zh-Hant-TW");
        assert_eq!(clean_language("español"), "");
        assert_eq!(clean_language("e"), "");
        assert_eq!(clean_language("en--GB"), "");
    }

    fn status(headers: &HeaderMap) -> Option<StatusCode> {
        principal(headers).err().map(|e| e.status)
    }

    #[test]
    fn identity_rules() {
        let mut h = HeaderMap::new();
        assert_eq!(status(&h), Some(StatusCode::UNAUTHORIZED));
        h.insert(HEADER_USER_ID, HeaderValue::from_static("6f9619ff-8b86-d011-b42d-00c04fc964ff"));
        assert_eq!(status(&h), Some(StatusCode::FORBIDDEN));
        h.insert(HEADER_USER_ROLES, HeaderValue::from_static("USER,ADMIN"));
        assert_eq!(principal(&h).ok().as_deref(), Some("6f9619ff-8b86-d011-b42d-00c04fc964ff"));
        h.insert(HEADER_USER_ROLES, HeaderValue::from_static("user"));
        assert_eq!(status(&h), Some(StatusCode::UNAUTHORIZED));
        h.insert(HEADER_USER_ID, HeaderValue::from_static("a b"));
        assert_eq!(status(&h), Some(StatusCode::UNAUTHORIZED));
    }

    // --- Pruebas de la API completa (rutas, cabeceras y Kafka simulado).

    use std::sync::Mutex;

    use axum::body::{Body, to_bytes};
    use axum::http::Request;
    use tower::ServiceExt;

    use crate::spatial::index::tests::sample_snapshot;
    use crate::stream::processor::SinkError;

    #[derive(Debug, Default)]
    struct VecSink {
        sent: Mutex<Vec<OutboundRecord>>,
    }

    impl EventSink for VecSink {
        async fn send(&self, record: OutboundRecord) -> Result<(), SinkError> {
            if let Ok(mut sent) = self.sent.lock() {
                sent.push(record);
            }
            Ok(())
        }
    }

    fn app(sink: Option<Arc<VecSink>>) -> Router {
        let snapshots = SnapshotHandle::new();
        snapshots.publish(sample_snapshot());
        router(ApiState { snapshots, positions: sink.map(|sink| PositionsTarget { sink, topic: "geo.user-positions.v1".into() }) })
    }

    fn request(method: &str, uri: &str, body: &str, user: bool) -> Result<Request<Body>, String> {
        let mut builder = Request::builder().method(method).uri(uri).header(header::CONTENT_TYPE, "application/json");
        if user {
            builder = builder.header(HEADER_USER_ID, "ana").header(HEADER_USER_ROLES, "USER");
        }
        builder.body(Body::from(body.to_owned())).map_err(|e| e.to_string())
    }

    async fn call(app: Router, req: Request<Body>) -> Result<(StatusCode, Value), String> {
        let response = app.oneshot(req).await.map_err(|e| e.to_string())?;
        let status = response.status();
        let bytes = to_bytes(response.into_body(), 1 << 20).await.map_err(|e| e.to_string())?;
        Ok((status, serde_json::from_slice(&bytes).unwrap_or(Value::Null)))
    }

    #[tokio::test]
    async fn zonas_en_geojson() -> Result<(), String> {
        let (status, body) = call(app(None), request("GET", "/v1/zones?bbox=-3.72,40.40,-3.69,40.43", "", true)?).await?;
        assert_eq!(status, StatusCode::OK);
        assert_eq!(body["type"], "FeatureCollection");
        assert_eq!(body["features"].as_array().map(Vec::len), Some(2));
        assert_eq!(body["features"][0]["geometry"]["type"], "MultiPolygon");
        assert_eq!(body["truncated"], false);

        let (status, _) = call(app(None), request("GET", "/v1/zones?bbox=-3.72,40.40,-3.69,40.43", "", false)?).await?;
        assert_eq!(status, StatusCode::UNAUTHORIZED, "sin identidad del proxy no se entra");
        let (status, body) = call(app(None), request("GET", "/v1/zones?bbox=0,0,10,10", "", true)?).await?;
        assert_eq!(status, StatusCode::BAD_REQUEST);
        assert_eq!(body["status"], 400);
        Ok(())
    }

    #[tokio::test]
    async fn posiciones_a_kafka_en_orden() -> Result<(), String> {
        let sink = Arc::new(VecSink::default());
        let now = now_ms();
        let body = json!({
            "language": "es-ES",
            "positions": [
                {"lat": 40.4168, "lon": -3.7038, "accuracy_m": 8.0, "recorded_at_ms": now - 1_000},
                {"lat": 40.4170, "lon": -3.7040, "accuracy_m": 9.0, "recorded_at_ms": now - 9_000},
            ]
        })
        .to_string();
        let (status, reply) = call(app(Some(sink.clone())), request("POST", "/v1/positions", &body, true)?).await?;
        assert_eq!(status, StatusCode::ACCEPTED);
        assert_eq!(reply["accepted"], 2);

        let sent = sink.sent.lock().map(|v| v.len()).unwrap_or_default();
        assert_eq!(sent, 2);
        let first = sink.sent.lock().ok().and_then(|v| v.first().map(|r| (r.key.clone(), r.payload.clone()))).ok_or("vacío")?;
        assert_eq!(first.0, b"ana");
        let event = pb::UserPositionReported::decode(first.1.as_slice()).map_err(|e| e.to_string())?;
        // La más antigua va primero, aunque llegase la segunda.
        assert_eq!(event.horizontal_accuracy_meters, 9.0);
        assert_eq!(event.user_id, "ana");
        assert_eq!(event.preferred_language, "es-ES");
        Ok(())
    }

    #[tokio::test]
    async fn posiciones_rechazadas() -> Result<(), String> {
        let sink = Arc::new(VecSink::default());
        let now = now_ms();
        let bad = json!({"positions": [{"lat": 99.0, "lon": 0.0, "accuracy_m": 5.0, "recorded_at_ms": now}]}).to_string();
        let (status, _) = call(app(Some(sink.clone())), request("POST", "/v1/positions", &bad, true)?).await?;
        assert_eq!(status, StatusCode::BAD_REQUEST);
        let extra = json!({"positions": [], "user_id": "otra"}).to_string();
        let (status, _) = call(app(Some(sink.clone())), request("POST", "/v1/positions", &extra, true)?).await?;
        assert_eq!(status, StatusCode::BAD_REQUEST, "campos desconocidos (p. ej. suplantar user_id) se rechazan");
        let ok = json!({"positions": [{"lat": 1.0, "lon": 1.0, "accuracy_m": 5.0, "recorded_at_ms": now}]}).to_string();
        let (status, _) = call(app(None), request("POST", "/v1/positions", &ok, true)?).await?;
        assert_eq!(status, StatusCode::SERVICE_UNAVAILABLE, "sin Kafka no se aceptan posiciones");
        assert!(sink.sent.lock().map(|v| v.is_empty()).unwrap_or(false));
        Ok(())
    }
}
