//! Tests de seguridad del gRPC (mTLS + TLS 1.3 + lista de clientes).
//!
//! Crean en memoria una autoridad certificadora (CA) de mentira, emiten
//! certificados con ella y comprueban QUIÉN puede llamar al servicio:
//! es la prueba de que el "zero trust" funciona de verdad.

use std::net::SocketAddr;
use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;

use geo_engine::cache::MemoryStore;
use geo_engine::config::GrpcTlsFiles;
use geo_engine::grpc::{GeoServiceImpl, RouteSettings};
use geo_engine::proto::geo as pb;
use geo_engine::proto::geo::geo_service_client::GeoServiceClient;
use geo_engine::proto::geo::geo_service_server::GeoServiceServer;
use geo_engine::snapshot::SnapshotHandle;
use geo_engine::spatial::{AirportRecord, GeoSnapshot, LatLng};
use geo_engine::tls::{self, ClientAllowlist};
use hyper_util::rt::TokioIo;
use rcgen::{BasicConstraints, CertificateParams, DnType, ExtendedKeyUsagePurpose, IsCa, Issuer, KeyPair};
use rustls::RootCertStore;
use rustls_pki_types::pem::PemObject;
use rustls_pki_types::{CertificateDer, PrivateKeyDer, ServerName};
use tokio::net::{TcpListener, TcpStream};
use tokio_rustls::TlsConnector;
use tonic::transport::{Endpoint, Server, Uri};

type TestResult = Result<(), Box<dyn std::error::Error>>;

/// Una CA de pruebas capaz de emitir certificados.
struct TestCa {
    issuer: Issuer<'static, KeyPair>,
    pem: String,
}

impl TestCa {
    fn new(name: &str) -> Result<Self, rcgen::Error> {
        let key = KeyPair::generate()?;
        let mut params = CertificateParams::new(Vec::<String>::new())?;
        params.is_ca = IsCa::Ca(BasicConstraints::Unconstrained);
        params.distinguished_name.push(DnType::CommonName, name);
        let cert = params.self_signed(&key)?;
        Ok(Self { pem: cert.pem(), issuer: Issuer::new(params, key) })
    }

    /// Emite un certificado (PEM) y su clave para `name`.
    fn issue(&self, name: &str, purpose: ExtendedKeyUsagePurpose) -> Result<(String, String), rcgen::Error> {
        let key = KeyPair::generate()?;
        let mut params = CertificateParams::new(vec![name.to_owned()])?;
        params.distinguished_name.push(DnType::CommonName, name);
        params.extended_key_usages = vec![purpose];
        let cert = params.signed_by(&key, &self.issuer)?;
        Ok((cert.pem(), key.serialize_pem()))
    }
}

fn write(dir: &tempfile::TempDir, name: &str, content: &str) -> std::io::Result<PathBuf> {
    let path = dir.path().join(name);
    std::fs::write(&path, content)?;
    Ok(path)
}

/// Arranca el gRPC con mTLS en un puerto libre y devuelve su dirección y la CA.
async fn start_server(allowed: Vec<String>) -> Result<(SocketAddr, TestCa, tempfile::TempDir), Box<dyn std::error::Error>> {
    let _ = rustls::crypto::ring::default_provider().install_default();
    let ca = TestCa::new("nomadiq-test-ca")?;
    let dir = tempfile::tempdir()?;
    let (cert, key) = ca.issue("localhost", ExtendedKeyUsagePurpose::ServerAuth)?;
    let files = GrpcTlsFiles {
        cert_file: write(&dir, "server.pem", &cert)?,
        key_file: write(&dir, "server-key.pem", &key)?,
        client_ca_file: write(&dir, "ca.pem", &ca.pem)?,
    };
    let snapshots = SnapshotHandle::new();
    let airport = AirportRecord {
        iata_code: "MAD".into(),
        icao_code: "LEMD".into(),
        name: "Madrid-Barajas".into(),
        city: "Madrid".into(),
        country_code: "ES".into(),
        location: LatLng::new(40.493407, -3.572249)?,
    };
    snapshots.publish(GeoSnapshot::build(1, vec![airport], vec![]));
    let settings = RouteSettings {
        max_stops: 10,
        exact_max_stops: 10,
        cache_ttl: Duration::from_secs(60),
        max_concurrency: 1,
        queue_timeout: Duration::from_secs(1),
    };
    let service = GeoServiceImpl::new(snapshots, Arc::new(MemoryStore::default()), settings);
    let listener = TcpListener::bind("127.0.0.1:0").await?;
    let addr = listener.local_addr()?;
    let incoming = tls::verified_incoming(listener, tls::server_config(&files)?, ClientAllowlist::new(allowed));
    tokio::spawn(Server::builder().add_service(GeoServiceServer::new(service)).serve_with_incoming(incoming));
    Ok((addr, ca, dir))
}

/// Cliente gRPC que usa rustls con la configuración indicada.
async fn call(addr: SocketAddr, tls_config: rustls::ClientConfig) -> Result<pb::FindNearestAirportsResponse, Box<dyn std::error::Error>> {
    let connector = TlsConnector::from(Arc::new(tls_config));
    let channel = Endpoint::try_from(format!("http://{addr}"))?
        .connect_timeout(Duration::from_secs(2))
        .connect_with_connector(tower::service_fn(move |_: Uri| {
            let connector = connector.clone();
            async move {
                let tcp = TcpStream::connect(addr).await?;
                let server_name = ServerName::try_from("localhost").map_err(std::io::Error::other)?;
                let tls = connector.connect(server_name, tcp).await?;
                Ok::<_, std::io::Error>(TokioIo::new(tls))
            }
        }))
        .await?;
    let request = pb::FindNearestAirportsRequest { point: Some(pb::LatLng { latitude: 40.4168, longitude: -3.7038 }), limit: 1, max_distance_meters: 0.0 };
    let response = tokio::time::timeout(Duration::from_secs(5), GeoServiceClient::new(channel).find_nearest_airports(request)).await??;
    Ok(response.into_inner())
}

fn roots(ca: &TestCa) -> Result<RootCertStore, Box<dyn std::error::Error>> {
    let mut roots = RootCertStore::empty();
    roots.add(CertificateDer::from_pem_slice(ca.pem.as_bytes())?)?;
    Ok(roots)
}

fn client_config(
    ca: &TestCa,
    identity: Option<(&str, &str)>,
    versions: &[&'static rustls::SupportedProtocolVersion],
) -> Result<rustls::ClientConfig, Box<dyn std::error::Error>> {
    let builder = rustls::ClientConfig::builder_with_provider(tls::crypto_provider())
        .with_protocol_versions(versions)?
        .with_root_certificates(roots(ca)?);
    let mut config = match identity {
        Some((cert, key)) => {
            let certs = vec![CertificateDer::from_pem_slice(cert.as_bytes())?];
            builder.with_client_auth_cert(certs, PrivateKeyDer::from_pem_slice(key.as_bytes())?)?
        }
        None => builder.with_no_client_auth(),
    };
    config.alpn_protocols = vec![b"h2".to_vec()];
    Ok(config)
}

#[tokio::test]
async fn cliente_con_certificado_de_la_ca_puede_llamar() -> TestResult {
    let (addr, ca, _dir) = start_server(vec![]).await?;
    let (cert, key) = ca.issue("ai-orchestrator", ExtendedKeyUsagePurpose::ClientAuth)?;
    let response = call(addr, client_config(&ca, Some((&cert, &key)), &[&rustls::version::TLS13])?).await?;
    assert_eq!(response.airports.first().and_then(|a| a.airport.as_ref()).map(|a| a.iata_code.as_str()), Some("MAD"));
    Ok(())
}

#[tokio::test]
async fn cliente_sin_certificado_es_rechazado() -> TestResult {
    let (addr, ca, _dir) = start_server(vec![]).await?;
    assert!(call(addr, client_config(&ca, None, &[&rustls::version::TLS13])?).await.is_err());
    Ok(())
}

#[tokio::test]
async fn certificado_de_otra_ca_es_rechazado() -> TestResult {
    let (addr, ca, _dir) = start_server(vec![]).await?;
    let impostor_ca = TestCa::new("ca-del-atacante")?;
    let (cert, key) = impostor_ca.issue("ai-orchestrator", ExtendedKeyUsagePurpose::ClientAuth)?;
    assert!(call(addr, client_config(&ca, Some((&cert, &key)), &[&rustls::version::TLS13])?).await.is_err());
    Ok(())
}

#[tokio::test]
async fn solo_entran_los_clientes_de_la_lista() -> TestResult {
    let (addr, ca, _dir) = start_server(vec!["auth-gateway".into()]).await?;
    let (cert, key) = ca.issue("flight-ingestor", ExtendedKeyUsagePurpose::ClientAuth)?;
    assert!(call(addr, client_config(&ca, Some((&cert, &key)), &[&rustls::version::TLS13])?).await.is_err());
    let (cert, key) = ca.issue("auth-gateway", ExtendedKeyUsagePurpose::ClientAuth)?;
    assert!(call(addr, client_config(&ca, Some((&cert, &key)), &[&rustls::version::TLS13])?).await.is_ok());
    Ok(())
}

#[tokio::test]
async fn tls_1_2_es_rechazado() -> TestResult {
    let (addr, ca, _dir) = start_server(vec![]).await?;
    let (cert, key) = ca.issue("ai-orchestrator", ExtendedKeyUsagePurpose::ClientAuth)?;
    assert!(call(addr, client_config(&ca, Some((&cert, &key)), &[&rustls::version::TLS12])?).await.is_err());
    Ok(())
}
