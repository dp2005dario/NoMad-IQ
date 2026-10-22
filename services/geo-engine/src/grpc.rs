//! La API gRPC `GeoService`: traduce entre protobuf y el dominio, valida todo
//! lo que entra y convierte los errores en códigos gRPC claros.
//!
//! Regla de oro: NADA de lo que llega por la red es de fiar (zero trust,
//! también entre servicios internos). Cada campo se valida antes de usarse y
//! cada petición tiene límites (paradas máximas, resultados máximos, tiempo).

use std::collections::{HashMap, HashSet};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use futures::future::{BoxFuture, FutureExt, Shared};
use geo_types::{Coord, LineString};
use prost::Message;
use tokio::sync::Semaphore;
use tonic::{Request, Response, Status};
use uuid::Uuid;

use crate::cache::{KeyValueStore, route_cache_key};
use crate::proto::geo as pb;
use crate::snapshot::SnapshotHandle;
use crate::spatial::route::{self, RouteShape};
use crate::spatial::wkb::encode_line_string;
use crate::spatial::{AirportRecord, GeoSnapshot, LatLng, ZoneKind, ZoneRecord};
use crate::tls::PeerInfo;

/// Aeropuertos devueltos si la petición no indica cuántos.
const DEFAULT_AIRPORT_LIMIT: u32 = 5;
/// Máximo de aeropuertos por petición.
const MAX_AIRPORT_LIMIT: u32 = 50;
/// Longitud máxima de un stop_id.
const MAX_STOP_ID_LEN: usize = 128;

/// Ajustes de la optimización de rutas.
#[derive(Debug, Clone)]
pub struct RouteSettings {
    /// Paradas máximas por petición.
    pub max_stops: usize,
    /// Hasta cuántas paradas se usa el algoritmo exacto.
    pub exact_max_stops: usize,
    /// Caducidad de la caché.
    pub cache_ttl: Duration,
    /// Cálculos simultáneos como máximo.
    pub max_concurrency: usize,
    /// Cuánto puede esperar una petición su turno antes de rechazarse.
    pub queue_timeout: Duration,
}

/// Fallo de un cálculo de ruta. Es `Clone` porque varias peticiones idénticas
/// simultáneas comparten el mismo cálculo (y por tanto el mismo resultado).
#[derive(Debug, Clone)]
enum RouteFailure {
    Overloaded,
    Internal(String),
}

impl From<RouteFailure> for Status {
    fn from(failure: RouteFailure) -> Self {
        match failure {
            RouteFailure::Overloaded => {
                Status::resource_exhausted("el servicio está calculando demasiadas rutas; reintenta en unos segundos")
            }
            RouteFailure::Internal(msg) => {
                tracing::error!(error = %msg, "fallo interno calculando una ruta");
                Status::internal("error interno calculando la ruta")
            }
        }
    }
}

type SharedRoute = Shared<BoxFuture<'static, Result<Arc<pb::OptimizeRouteResponse>, RouteFailure>>>;

/// Implementación del servicio. Es genérica sobre el almacén de caché `S`
/// para poder probarla con una caché en memoria.
#[derive(Debug)]
pub struct GeoServiceImpl<S> {
    snapshots: SnapshotHandle,
    cache: Arc<S>,
    settings: RouteSettings,
    /// Semáforo: como las plazas de un aparcamiento. Solo `max_concurrency`
    /// cálculos de ruta a la vez; el resto espera su turno (o se rechaza si
    /// espera demasiado). Así un pico de peticiones no ahoga la CPU.
    limiter: Arc<Semaphore>,
    /// Cálculos en curso por clave ("single flight"): si llegan 5 peticiones
    /// idénticas a la vez (reintentos), se calcula UNA vez y las 5 esperan el
    /// mismo resultado.
    in_flight: Arc<Mutex<HashMap<String, SharedRoute>>>,
}

impl<S: KeyValueStore> GeoServiceImpl<S> {
    /// Crea el servicio.
    pub fn new(snapshots: SnapshotHandle, cache: Arc<S>, settings: RouteSettings) -> Self {
        let limiter = Arc::new(Semaphore::new(settings.max_concurrency.max(1)));
        Self { snapshots, cache, settings, limiter, in_flight: Arc::new(Mutex::new(HashMap::new())) }
    }

    fn snapshot(&self) -> Result<Arc<GeoSnapshot>, Status> {
        self.snapshots
            .load()
            .ok_or_else(|| Status::unavailable("los datos geoespaciales aún no están cargados; reintenta en unos segundos"))
    }

    /// Calcula (o reutiliza un cálculo en curso de) la ruta con clave `key`.
    fn route_computation(&self, key: String, stops: Vec<(String, LatLng)>, shape: RouteShape) -> SharedRoute {
        // El candado se mantiene mientras se crea e inserta la tarea: así la
        // tarea no puede terminar y "borrarse" del mapa antes de estar en él.
        let mut in_flight = match self.in_flight.lock() {
            Ok(guard) => guard,
            // Un candado "envenenado" solo ocurre si otro hilo entró en pánico
            // con él cogido; el mapa sigue siendo coherente, así que seguimos.
            Err(poisoned) => poisoned.into_inner(),
        };
        if let Some(existing) = in_flight.get(&key) {
            return existing.clone();
        }
        let (limiter, cache, settings, registry, task_key) =
            (self.limiter.clone(), self.cache.clone(), self.settings.clone(), self.in_flight.clone(), key.clone());
        // La tarea va "suelta" (spawn): aunque el cliente cuelgue, el cálculo
        // termina y se guarda en caché, listo para su reintento.
        let task = tokio::spawn(async move {
            let result = compute_route(&limiter, &settings, stops, shape).await;
            if let Ok(response) = &result
                && let Err(e) = cache.set_ex(&task_key, response.encode_to_vec(), settings.cache_ttl).await
            {
                tracing::warn!(error = %e, "no se pudo guardar la ruta en caché (se sigue sin ella)");
            }
            match registry.lock() {
                Ok(mut map) => map.remove(&task_key),
                Err(poisoned) => poisoned.into_inner().remove(&task_key),
            };
            result
        });
        let shared = async move { task.await.unwrap_or_else(|e| Err(RouteFailure::Internal(e.to_string()))) }.boxed().shared();
        in_flight.insert(key, shared.clone());
        shared
    }
}

async fn compute_route(
    limiter: &Semaphore,
    settings: &RouteSettings,
    stops: Vec<(String, LatLng)>,
    shape: RouteShape,
) -> Result<Arc<pb::OptimizeRouteResponse>, RouteFailure> {
    let permit = tokio::time::timeout(settings.queue_timeout, limiter.acquire())
        .await
        .map_err(|_| RouteFailure::Overloaded)?
        .map_err(|_| RouteFailure::Internal("semáforo cerrado".into()))?;
    let exact_max = settings.exact_max_stops;
    // El cálculo es CPU pura: va al grupo de hilos de cálculo para no
    // bloquear las tareas de red de Tokio.
    let response = tokio::task::spawn_blocking(move || {
        let points: Vec<LatLng> = stops.iter().map(|(_, p)| *p).collect();
        let plan = route::optimize(&points, shape, exact_max);
        let mut coords: Vec<Coord<f64>> = plan.order.iter().map(|&i| Coord { x: points[i].lon(), y: points[i].lat() }).collect();
        if shape == RouteShape::RoundTrip
            && let Some(&first) = coords.first()
        {
            coords.push(first);
        }
        let path = encode_line_string(&LineString::new(coords)).map_err(|e| RouteFailure::Internal(e.to_string()))?;
        Ok::<_, RouteFailure>(pb::OptimizeRouteResponse {
            ordered_stop_ids: plan.order.iter().map(|&i| stops[i].0.clone()).collect(),
            total_distance_meters: plan.total_distance_m,
            leg_distances_meters: plan.leg_distances_m,
            path: Some(pb::Geometry { wkb: path }),
            optimal: plan.optimal,
            from_cache: false,
        })
    })
    .await
    .map_err(|e| RouteFailure::Internal(e.to_string()))??;
    drop(permit);
    Ok(Arc::new(response))
}

/// Lee un `LatLng` obligatorio de la petición.
fn required_point(value: Option<&pb::LatLng>, field: &str) -> Result<LatLng, Status> {
    let p = value.ok_or_else(|| Status::invalid_argument(format!("{field} es obligatorio")))?;
    LatLng::new(p.latitude, p.longitude).map_err(|e| Status::invalid_argument(format!("{field}: {e}")))
}

fn to_pb_point(p: LatLng) -> pb::LatLng {
    pb::LatLng { latitude: p.lat(), longitude: p.lon() }
}

fn kind_to_pb(kind: ZoneKind) -> pb::ZoneKind {
    match kind {
        ZoneKind::CityCenter => pb::ZoneKind::CityCenter,
        ZoneKind::TouristArea => pb::ZoneKind::TouristArea,
        ZoneKind::Airport => pb::ZoneKind::Airport,
        ZoneKind::Restricted => pb::ZoneKind::Restricted,
    }
}

fn airport_to_pb(a: &AirportRecord) -> pb::Airport {
    pb::Airport {
        iata_code: a.iata_code.clone(),
        icao_code: a.icao_code.clone(),
        name: a.name.clone(),
        city: a.city.clone(),
        country_code: a.country_code.clone(),
        location: Some(to_pb_point(a.location)),
    }
}

/// Convierte una zona; el WKB (lo pesado) solo si se pide. Clonar `Bytes` no
/// copia los datos: solo suma una referencia.
fn zone_to_pb(z: &ZoneRecord, include_geometry: bool) -> pb::Zone {
    pb::Zone {
        zone_id: z.id.to_string(),
        slug: z.slug.clone(),
        name: z.name.clone(),
        kind: kind_to_pb(z.kind).into(),
        geometry: include_geometry.then(|| pb::Geometry { wkb: z.wkb.clone() }),
    }
}

/// Identidad del cliente (del certificado mTLS) para los logs de auditoría.
fn caller<T>(request: &Request<T>) -> String {
    request.extensions().get::<PeerInfo>().map_or_else(|| "sin-mtls(dev)".to_owned(), |p| p.identity.clone())
}

/// Valida una petición de ruta y la convierte al dominio.
fn validate_route(req: &pb::OptimizeRouteRequest, max_stops: usize) -> Result<(Vec<(String, LatLng)>, RouteShape), Status> {
    let shape = match pb::RouteShape::try_from(req.shape) {
        Ok(pb::RouteShape::Open) => RouteShape::Open,
        Ok(pb::RouteShape::RoundTrip) => RouteShape::RoundTrip,
        _ => return Err(Status::invalid_argument("shape es obligatorio: ROUTE_SHAPE_OPEN o ROUTE_SHAPE_ROUND_TRIP")),
    };
    if req.stops.len() < 2 || req.stops.len() > max_stops {
        return Err(Status::invalid_argument(format!("se necesitan entre 2 y {max_stops} paradas (llegaron {})", req.stops.len())));
    }
    let mut seen = HashSet::with_capacity(req.stops.len());
    let mut stops = Vec::with_capacity(req.stops.len());
    for (i, stop) in req.stops.iter().enumerate() {
        if stop.stop_id.is_empty() || stop.stop_id.len() > MAX_STOP_ID_LEN || stop.stop_id.chars().any(char::is_control) {
            return Err(Status::invalid_argument(format!("stops[{i}].stop_id debe tener entre 1 y {MAX_STOP_ID_LEN} caracteres visibles")));
        }
        if !seen.insert(stop.stop_id.as_str()) {
            return Err(Status::invalid_argument(format!("stop_id repetido: {:?}", stop.stop_id)));
        }
        let point = required_point(stop.location.as_ref(), &format!("stops[{i}].location"))?;
        stops.push((stop.stop_id.clone(), point));
    }
    Ok((stops, shape))
}

#[tonic::async_trait]
impl<S: KeyValueStore> pb::geo_service_server::GeoService for GeoServiceImpl<S> {
    async fn find_nearest_airports(
        &self,
        request: Request<pb::FindNearestAirportsRequest>,
    ) -> Result<Response<pb::FindNearestAirportsResponse>, Status> {
        tracing::debug!(caller = %caller(&request), "FindNearestAirports");
        let req = request.into_inner();
        let point = required_point(req.point.as_ref(), "point")?;
        let limit = match req.limit {
            0 => DEFAULT_AIRPORT_LIMIT,
            n if n <= MAX_AIRPORT_LIMIT => n,
            n => return Err(Status::invalid_argument(format!("limit {n} supera el máximo de {MAX_AIRPORT_LIMIT}"))),
        };
        let max_distance = match req.max_distance_meters {
            0.0 => None,
            d if d.is_finite() && d > 0.0 => Some(d),
            d => return Err(Status::invalid_argument(format!("max_distance_meters inválido: {d}"))),
        };
        let snapshot = self.snapshot()?;
        let airports = snapshot
            .nearest_airports(point, limit as usize, max_distance)
            .into_iter()
            .map(|(airport, distance)| pb::AirportDistance { airport: Some(airport_to_pb(airport)), distance_meters: distance })
            .collect();
        Ok(Response::new(pb::FindNearestAirportsResponse { airports }))
    }

    async fn compute_distance(
        &self,
        request: Request<pb::ComputeDistanceRequest>,
    ) -> Result<Response<pb::ComputeDistanceResponse>, Status> {
        let req = request.into_inner();
        let from = required_point(req.from.as_ref(), "from")?;
        let to = required_point(req.to.as_ref(), "to")?;
        Ok(Response::new(pb::ComputeDistanceResponse {
            distance_meters: from.geodesic_distance_m(to),
            initial_bearing_degrees: from.initial_bearing_deg(to),
        }))
    }

    async fn optimize_route(&self, request: Request<pb::OptimizeRouteRequest>) -> Result<Response<pb::OptimizeRouteResponse>, Status> {
        tracing::debug!(caller = %caller(&request), stops = request.get_ref().stops.len(), "OptimizeRoute");
        let (stops, shape) = validate_route(request.get_ref(), self.settings.max_stops)?;
        let key = route_cache_key(&stops, shape, self.settings.exact_max_stops);

        // 1) ¿Ya está calculada? (si Redis falla, seguimos sin caché).
        match self.cache.get(&key).await {
            Ok(Some(bytes)) => match pb::OptimizeRouteResponse::decode(bytes.as_slice()) {
                Ok(mut cached) => {
                    cached.from_cache = true;
                    return Ok(Response::new(cached));
                }
                Err(e) => tracing::warn!(error = %e, "entrada de caché corrupta: se recalcula"),
            },
            Ok(None) => {}
            Err(e) => tracing::debug!(error = %e, "caché de rutas no disponible: se calcula sin ella"),
        }

        // 2) Calcular (o unirse a un cálculo idéntico en curso).
        let response = self.route_computation(key, stops, shape).await.map_err(Status::from)?;
        Ok(Response::new((*response).clone()))
    }

    async fn locate_zones(&self, request: Request<pb::LocateZonesRequest>) -> Result<Response<pb::LocateZonesResponse>, Status> {
        let req = request.into_inner();
        let point = required_point(req.point.as_ref(), "point")?;
        let snapshot = self.snapshot()?;
        let zones = snapshot.zones_containing(point).into_iter().map(|z| zone_to_pb(z, req.include_geometry)).collect();
        Ok(Response::new(pb::LocateZonesResponse { zones }))
    }

    async fn get_zone(&self, request: Request<pb::GetZoneRequest>) -> Result<Response<pb::GetZoneResponse>, Status> {
        let req = request.into_inner();
        let id = Uuid::parse_str(&req.zone_id).map_err(|_| Status::invalid_argument("zone_id debe ser un UUID"))?;
        let snapshot = self.snapshot()?;
        let zone = snapshot.zone(&id).ok_or_else(|| Status::not_found("zona no encontrada"))?;
        Ok(Response::new(pb::GetZoneResponse { zone: Some(zone_to_pb(zone, true)) }))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::cache::MemoryStore;
    use crate::proto::geo::geo_service_server::GeoService;
    use crate::spatial::index::tests::sample_snapshot;
    use geo_traits::to_geo::ToGeoGeometry;
    use std::sync::atomic::Ordering;
    use tonic::Code;

    fn settings() -> RouteSettings {
        RouteSettings {
            max_stops: 20,
            exact_max_stops: 12,
            cache_ttl: Duration::from_secs(60),
            max_concurrency: 2,
            queue_timeout: Duration::from_secs(1),
        }
    }

    fn service() -> (GeoServiceImpl<MemoryStore>, MemoryStore) {
        let handle = SnapshotHandle::new();
        handle.publish(sample_snapshot());
        let cache = MemoryStore::default();
        (GeoServiceImpl::new(handle, Arc::new(cache.clone()), settings()), cache)
    }

    fn pt(lat: f64, lon: f64) -> Option<pb::LatLng> {
        Some(pb::LatLng { latitude: lat, longitude: lon })
    }

    fn route_request() -> pb::OptimizeRouteRequest {
        let stop = |id: &str, lat, lon| pb::RouteStop { stop_id: id.into(), location: pt(lat, lon) };
        pb::OptimizeRouteRequest {
            stops: vec![
                stop("hotel", 40.4168, -3.7038),
                stop("retiro", 40.4153, -3.6845),
                stop("palacio", 40.4180, -3.7144),
                stop("prado", 40.4138, -3.6921),
            ],
            shape: pb::RouteShape::RoundTrip.into(),
        }
    }

    #[tokio::test]
    async fn aeropuertos_cercanos_y_validacion() -> Result<(), Status> {
        let (svc, _) = service();
        let resp = svc
            .find_nearest_airports(Request::new(pb::FindNearestAirportsRequest {
                point: pt(40.4168, -3.7038),
                limit: 0,
                max_distance_meters: 0.0,
            }))
            .await?
            .into_inner();
        assert_eq!(resp.airports.len(), 5);
        assert_eq!(resp.airports[0].airport.as_ref().map(|a| a.iata_code.as_str()), Some("MAD"));

        for bad in [
            pb::FindNearestAirportsRequest { point: None, limit: 1, max_distance_meters: 0.0 },
            pb::FindNearestAirportsRequest { point: pt(91.0, 0.0), limit: 1, max_distance_meters: 0.0 },
            pb::FindNearestAirportsRequest { point: pt(0.0, 0.0), limit: 51, max_distance_meters: 0.0 },
            pb::FindNearestAirportsRequest { point: pt(0.0, 0.0), limit: 1, max_distance_meters: -5.0 },
            pb::FindNearestAirportsRequest { point: pt(0.0, 0.0), limit: 1, max_distance_meters: f64::NAN },
        ] {
            let err = svc.find_nearest_airports(Request::new(bad)).await.err().map(|s| s.code());
            assert_eq!(err, Some(Code::InvalidArgument));
        }
        Ok(())
    }

    #[tokio::test]
    async fn sin_foto_cargada_responde_unavailable() {
        let svc = GeoServiceImpl::new(SnapshotHandle::new(), Arc::new(MemoryStore::default()), settings());
        let err = svc.locate_zones(Request::new(pb::LocateZonesRequest { point: pt(0.0, 0.0), include_geometry: false })).await.err();
        assert_eq!(err.map(|s| s.code()), Some(Code::Unavailable));
    }

    #[tokio::test]
    async fn ruta_se_cachea_y_el_reintento_no_recalcula() -> Result<(), Status> {
        let (svc, cache) = service();
        let first = svc.optimize_route(Request::new(route_request())).await?.into_inner();
        assert!(!first.from_cache);
        assert!(first.optimal);
        assert_eq!(first.ordered_stop_ids.first().map(String::as_str), Some("hotel"));
        assert_eq!(first.leg_distances_meters.len(), 4);
        assert_eq!(cache.len(), 1);

        let retry = svc.optimize_route(Request::new(route_request())).await?.into_inner();
        assert!(retry.from_cache);
        assert_eq!(retry.ordered_stop_ids, first.ordered_stop_ids);
        assert_eq!(retry.total_distance_meters, first.total_distance_meters);

        // El recorrido viene en WKB: un LineString cerrado (vuelve al hotel).
        let wkb = first.path.map(|g| g.wkb).unwrap_or_default();
        let geometry = wkb::reader::read_wkb(&wkb).ok().and_then(|g| g.try_to_geometry());
        let Some(geo_types::Geometry::LineString(line)) = geometry else { unreachable!("se esperaba un LineString") };
        assert_eq!(line.0.len(), 5);
        assert_eq!(line.0.first(), line.0.last());
        Ok(())
    }

    #[tokio::test]
    async fn con_redis_caido_la_ruta_se_calcula_igual() -> Result<(), Status> {
        let (svc, cache) = service();
        cache.fail.store(true, Ordering::Relaxed);
        let resp = svc.optimize_route(Request::new(route_request())).await?.into_inner();
        assert_eq!(resp.ordered_stop_ids.len(), 4);
        Ok(())
    }

    #[tokio::test]
    async fn peticiones_identicas_simultaneas_comparten_calculo() -> Result<(), Status> {
        let (svc, cache) = service();
        let svc = Arc::new(svc);
        let mut handles = Vec::new();
        for _ in 0..8 {
            let svc = svc.clone();
            handles.push(tokio::spawn(async move { svc.optimize_route(Request::new(route_request())).await }));
        }
        let mut ids = HashSet::new();
        for h in handles {
            let resp = h.await.map_err(|e| Status::internal(e.to_string()))??.into_inner();
            ids.insert(resp.ordered_stop_ids.join(","));
        }
        assert_eq!(ids.len(), 1, "todas reciben el mismo orden");
        assert_eq!(cache.len(), 1);
        // Al terminar no queda nada "en vuelo": el registro no crece sin límite.
        assert!(svc.in_flight.lock().map(|m| m.is_empty()).unwrap_or(false));
        Ok(())
    }

    #[tokio::test]
    async fn validacion_de_rutas() {
        let (svc, _) = service();
        let mut no_shape = route_request();
        no_shape.shape = 0;
        let mut one_stop = route_request();
        one_stop.stops.truncate(1);
        let mut duplicated = route_request();
        duplicated.stops[1].stop_id = "hotel".into();
        let mut bad_point = route_request();
        bad_point.stops[2].location = pt(0.0, 200.0);
        let mut empty_id = route_request();
        empty_id.stops[0].stop_id.clear();
        let mut too_many = route_request();
        too_many.stops = (0..21).map(|i| pb::RouteStop { stop_id: i.to_string(), location: pt(40.0, -3.0) }).collect();
        for bad in [no_shape, one_stop, duplicated, bad_point, empty_id, too_many] {
            let code = svc.optimize_route(Request::new(bad)).await.err().map(|s| s.code());
            assert_eq!(code, Some(Code::InvalidArgument));
        }
    }

    #[tokio::test]
    async fn zonas_y_geometria_en_wkb() -> Result<(), Status> {
        let (svc, _) = service();
        let light = svc
            .locate_zones(Request::new(pb::LocateZonesRequest { point: pt(40.4168, -3.7038), include_geometry: false }))
            .await?
            .into_inner();
        let slugs: Vec<_> = light.zones.iter().map(|z| z.slug.as_str()).collect();
        assert_eq!(slugs, ["madrid-centro", "madrid-sol"]);
        assert!(light.zones.iter().all(|z| z.geometry.is_none()));

        let zone_id = light.zones[0].zone_id.clone();
        let full = svc.get_zone(Request::new(pb::GetZoneRequest { zone_id })).await?.into_inner();
        let wkb = full.zone.and_then(|z| z.geometry).map(|g| g.wkb).unwrap_or_default();
        assert!(crate::spatial::wkb::decode_multipolygon(&wkb).is_ok());

        let not_uuid = svc.get_zone(Request::new(pb::GetZoneRequest { zone_id: "madrid".into() })).await.err();
        assert_eq!(not_uuid.map(|s| s.code()), Some(Code::InvalidArgument));
        let missing = svc.get_zone(Request::new(pb::GetZoneRequest { zone_id: Uuid::nil().to_string() })).await.err();
        assert_eq!(missing.map(|s| s.code()), Some(Code::NotFound));
        Ok(())
    }

    #[tokio::test]
    async fn distancia_y_rumbo() -> Result<(), Status> {
        let (svc, _) = service();
        let resp =
            svc.compute_distance(Request::new(pb::ComputeDistanceRequest { from: pt(0.0, 0.0), to: pt(0.0, -1.0) })).await?.into_inner();
        assert!((resp.distance_meters - 111_319.49).abs() < 1.0);
        assert!((resp.initial_bearing_degrees - 270.0).abs() < 1e-6);
        Ok(())
    }
}
