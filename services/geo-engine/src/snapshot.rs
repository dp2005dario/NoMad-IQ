//! Mantiene al día la foto en memoria ([`GeoSnapshot`]) sin bloquear lecturas.
//!
//! ## El problema (riesgo 3 del análisis: contención de cerrojos)
//! Miles de peticiones por segundo leen el índice; de vez en cuando hay que
//! sustituirlo por uno nuevo. Con un `RwLock` (muchos lectores O un escritor)
//! cada lectura pagaría un contador atómico compartido entre todos los núcleos
//! y, mientras se escribe, TODAS las lecturas esperan.
//!
//! ## La solución: "copiar y cambiar el puntero" (`ArcSwap`)
//! Analogía: en vez de borrar y reescribir la pizarra mientras la gente la lee,
//! preparamos una pizarra nueva en otra sala y, cuando está lista, cambiamos
//! el cartel de la puerta de golpe. Quien estaba leyendo la vieja termina
//! tranquilo; quien llega después ya ve la nueva. Nadie espera nunca.
//!
//! - Lectura: `load()` devuelve un `Arc` (puntero compartido) a la foto
//!   actual, sin cerrojo.
//! - Escritura: se construye la foto nueva aparte (en un hilo de cálculo para
//!   no frenar a Tokio) y `store()` la publica de forma atómica.
//! - Coste: durante el cambio conviven dos fotos en memoria (la vieja se
//!   libera sola cuando su último lector termina).

use std::sync::Arc;
use std::sync::atomic::{AtomicU64, AtomicUsize, Ordering};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use arc_swap::ArcSwapOption;
use tokio_util::sync::CancellationToken;

use crate::spatial::wkb::decode_multipolygon;
use crate::spatial::{AirportRecord, GeoSnapshot, LatLng, ZoneKind, ZoneRecord};
use crate::store::{Dataset, Store, StoreError};

/// Puntero compartido a la foto actual + contadores para /readyz.
#[derive(Debug, Clone, Default)]
pub struct SnapshotHandle {
    inner: Arc<Inner>,
}

#[derive(Debug, Default)]
struct Inner {
    current: ArcSwapOption<GeoSnapshot>,
    rejected_rows: AtomicUsize,
    last_success_unix: AtomicU64,
}

impl SnapshotHandle {
    /// Crea un puntero vacío (sin foto todavía).
    pub fn new() -> Self {
        Self::default()
    }

    /// Foto actual, o None si aún no se ha cargado ninguna. Sin cerrojos.
    pub fn load(&self) -> Option<Arc<GeoSnapshot>> {
        self.inner.current.load_full()
    }

    /// Publica una foto nueva de forma atómica.
    pub fn publish(&self, snapshot: GeoSnapshot) {
        self.inner.current.store(Some(Arc::new(snapshot)));
    }

    /// Filas descartadas (inválidas) en la última carga.
    pub fn rejected_rows(&self) -> usize {
        self.inner.rejected_rows.load(Ordering::Relaxed)
    }

    /// Segundos desde la última comprobación correcta contra PostgreSQL.
    pub fn seconds_since_last_sync(&self) -> Option<u64> {
        let last = self.inner.last_success_unix.load(Ordering::Relaxed);
        (last > 0).then(|| unix_now().saturating_sub(last))
    }

    fn mark_synced(&self) {
        self.inner.last_success_unix.store(unix_now(), Ordering::Relaxed);
    }
}

fn unix_now() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or_default()
}

/// Convierte las filas de la base de datos en una foto validada.
///
/// Una fila mala (un polígono roto, un tipo desconocido) se descarta y se
/// registra, pero no impide cargar las demás: una zona mal dada de alta no
/// debe dejar sin servicio al resto del mundo.
pub fn build_snapshot(dataset: Dataset) -> (GeoSnapshot, usize) {
    let mut rejected = 0;
    let mut airports = Vec::with_capacity(dataset.airports.len());
    for row in dataset.airports {
        match LatLng::new(row.latitude, row.longitude) {
            Ok(location) => airports.push(AirportRecord {
                iata_code: row.iata_code,
                icao_code: row.icao_code,
                name: row.name,
                city: row.city,
                country_code: row.country_code,
                location,
            }),
            Err(e) => {
                rejected += 1;
                tracing::warn!(iata = %row.iata_code, error = %e, "aeropuerto descartado");
            }
        }
    }
    let mut zones = Vec::with_capacity(dataset.zones.len());
    for row in dataset.zones {
        let Some(kind) = ZoneKind::from_db(&row.kind) else {
            rejected += 1;
            tracing::warn!(slug = %row.slug, kind = %row.kind, "zona descartada: tipo desconocido");
            continue;
        };
        match decode_multipolygon(&row.wkb) {
            Ok(geometry) => zones.push(ZoneRecord { id: row.zone_id, slug: row.slug, name: row.name, kind, geometry, wkb: row.wkb.into() }),
            Err(e) => {
                rejected += 1;
                tracing::warn!(slug = %row.slug, error = %e, "zona descartada: geometría inválida");
            }
        }
    }
    (GeoSnapshot::build(dataset.version, airports, zones), rejected)
}

/// Comprueba la versión y, si cambió, recarga y publica una foto nueva.
/// Devuelve true si publicó una foto nueva.
pub async fn refresh_once(store: &mut Store, handle: &SnapshotHandle) -> Result<bool, StoreError> {
    let version = store.dataset_version().await?;
    if handle.load().is_some_and(|current| current.version() == version) {
        handle.mark_synced();
        return Ok(false);
    }
    let dataset = store.load_dataset().await?;
    // Construir los R-tree es trabajo de CPU: se hace en el grupo de hilos de
    // cálculo ("blocking") para no frenar las tareas de red de Tokio.
    let (snapshot, rejected) = tokio::task::spawn_blocking(move || build_snapshot(dataset))
        .await
        .map_err(|e| StoreError::Unexpected(format!("la construcción del índice falló: {e}")))?;
    tracing::info!(
        version = snapshot.version(),
        airports = snapshot.airport_count(),
        zones = snapshot.zone_count(),
        rejected,
        "foto geoespacial publicada"
    );
    handle.inner.rejected_rows.store(rejected, Ordering::Relaxed);
    handle.publish(snapshot);
    handle.mark_synced();
    Ok(true)
}

/// Bucle de refresco: hasta tener la primera foto reintenta con espera
/// creciente (1 s, 2 s, 4 s... hasta `interval`); después comprueba cada `interval`.
/// Si PostgreSQL se cae, se sigue sirviendo la última foto buena.
pub async fn run_refresher(mut store: Store, handle: SnapshotHandle, interval: Duration, shutdown: CancellationToken) {
    let mut backoff = Duration::from_secs(1);
    loop {
        let wait = match refresh_once(&mut store, &handle).await {
            Ok(_) => {
                backoff = Duration::from_secs(1);
                interval
            }
            Err(e) => {
                tracing::warn!(error = %e, "no se pudo refrescar la foto geoespacial (se mantiene la anterior)");
                if handle.load().is_none() {
                    let wait = backoff;
                    backoff = (backoff * 2).min(interval.max(Duration::from_secs(1)));
                    wait
                } else {
                    interval
                }
            }
        };
        tokio::select! {
            () = shutdown.cancelled() => break,
            () = tokio::time::sleep(wait) => {}
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::spatial::index::tests::rect_zone;
    use crate::store::{AirportRow, ZoneRow};

    #[test]
    fn descarta_filas_malas_y_conserva_las_buenas() {
        let good_zone = rect_zone(1, "buena", 0.0, 0.0, 1.0, 1.0);
        let dataset = Dataset {
            version: 3,
            airports: vec![
                AirportRow {
                    iata_code: "MAD".into(),
                    icao_code: "LEMD".into(),
                    name: "Barajas".into(),
                    city: "Madrid".into(),
                    country_code: "ES".into(),
                    latitude: 40.49,
                    longitude: -3.57,
                },
                AirportRow {
                    iata_code: "XXX".into(),
                    icao_code: String::new(),
                    name: "Roto".into(),
                    city: String::new(),
                    country_code: "ES".into(),
                    latitude: 123.0,
                    longitude: 0.0,
                },
            ],
            zones: vec![
                ZoneRow {
                    zone_id: good_zone.id,
                    slug: "buena".into(),
                    name: "Buena".into(),
                    kind: "CITY_CENTER".into(),
                    wkb: good_zone.wkb.to_vec(),
                },
                ZoneRow {
                    zone_id: uuid::Uuid::from_u128(2),
                    slug: "tipo-raro".into(),
                    name: "X".into(),
                    kind: "VOLCAN".into(),
                    wkb: good_zone.wkb.to_vec(),
                },
                ZoneRow {
                    zone_id: uuid::Uuid::from_u128(3),
                    slug: "basura".into(),
                    name: "X".into(),
                    kind: "CITY_CENTER".into(),
                    wkb: vec![1, 2, 3],
                },
            ],
        };
        let (snapshot, rejected) = build_snapshot(dataset);
        assert_eq!(rejected, 3);
        assert_eq!(snapshot.version(), 3);
        assert_eq!(snapshot.airport_count(), 1);
        assert_eq!(snapshot.zone_count(), 1);
    }

    #[test]
    fn publicar_es_atomico_y_los_lectores_conservan_su_foto() {
        let handle = SnapshotHandle::new();
        assert!(handle.load().is_none());
        handle.publish(GeoSnapshot::build(1, vec![], vec![]));
        let reader = handle.load();
        handle.publish(GeoSnapshot::build(2, vec![], vec![]));
        // Quien empezó a leer la versión 1 la sigue teniendo intacta...
        assert_eq!(reader.map(|s| s.version()), Some(1));
        // ...y quien llega ahora ve la 2.
        assert_eq!(handle.load().map(|s| s.version()), Some(2));
    }
}
