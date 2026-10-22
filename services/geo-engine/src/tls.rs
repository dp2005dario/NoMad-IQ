//! TLS 1.3 y mTLS (TLS mutuo) para el gRPC, con rustls (TLS escrito en Rust).
//!
//! ## TLS vs mTLS, con una analogía
//! - TLS normal: tú compruebas el DNI del banco (su certificado) antes de
//!   darle tus datos. El banco no sabe quién eres tú.
//! - mTLS: el banco TAMBIÉN te pide tu DNI. Aquí, el geo-engine solo acepta
//!   conexiones de servicios con un certificado firmado por la CA interna de
//!   NomadIQ. Es la base del "zero trust": estar dentro de la red no basta.
//!
//! Además, con `GRPC_ALLOWED_CLIENTS` se puede restringir QUÉ servicios
//! (por el nombre de su certificado) pueden llamar: mínimo privilegio.
//!
//! ## ¿Por qué no usamos la TLS que trae tonic?
//! Porque no permite exigir "solo TLS 1.3" ni comprobar la lista de clientes
//! permitidos. Aquí aceptamos las conexiones nosotros y se las pasamos a tonic
//! ya cifradas y verificadas.

use std::fs;
use std::io;
use std::net::SocketAddr;
use std::path::Path;
use std::pin::Pin;
use std::sync::Arc;
use std::task::{Context, Poll};
use std::time::Duration;

use rustls::RootCertStore;
use rustls::server::WebPkiClientVerifier;
use rustls_pki_types::pem::PemObject;
use rustls_pki_types::{CertificateDer, PrivateKeyDer};
use thiserror::Error;
use tokio::io::{AsyncRead, AsyncWrite, ReadBuf};
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::{Semaphore, mpsc};
use tokio_rustls::TlsAcceptor;
use tokio_rustls::server::TlsStream;
use tokio_stream::wrappers::ReceiverStream;
use tonic::transport::server::Connected;

use crate::config::GrpcTlsFiles;

/// Tiempo máximo para completar el saludo TLS: un cliente que abre la
/// conexión y no habla no puede retener recursos indefinidamente.
const HANDSHAKE_TIMEOUT: Duration = Duration::from_secs(10);
/// Saludos TLS simultáneos como máximo (protección frente a inundaciones).
const MAX_CONCURRENT_HANDSHAKES: usize = 1024;

/// Errores al preparar la configuración TLS.
#[derive(Debug, Error)]
pub enum TlsError {
    /// No se pudo leer un fichero.
    #[error("no se pudo leer {path}: {source}")]
    Read {
        /// Fichero.
        path: String,
        /// Causa.
        source: io::Error,
    },
    /// El fichero no contiene lo esperado.
    #[error("{0}")]
    Invalid(String),
    /// rustls rechazó la configuración.
    #[error("configuración TLS inválida: {0}")]
    Rustls(#[from] rustls::Error),
    /// El verificador de clientes no se pudo construir.
    #[error("verificador de clientes inválido: {0}")]
    Verifier(#[from] rustls::server::VerifierBuilderError),
}

fn read(path: &Path) -> Result<Vec<u8>, TlsError> {
    fs::read(path).map_err(|source| TlsError::Read { path: path.display().to_string(), source })
}

/// Lee todos los certificados PEM de un fichero.
pub fn load_certs(path: &Path) -> Result<Vec<CertificateDer<'static>>, TlsError> {
    let certs = CertificateDer::pem_slice_iter(&read(path)?)
        .collect::<Result<Vec<_>, _>>()
        .map_err(|e| TlsError::Invalid(format!("{}: PEM inválido: {e}", path.display())))?;
    if certs.is_empty() {
        return Err(TlsError::Invalid(format!("{}: no contiene certificados", path.display())));
    }
    Ok(certs)
}

/// Lee una clave privada PEM (PKCS#8, SEC1 o PKCS#1).
pub fn load_key(path: &Path) -> Result<PrivateKeyDer<'static>, TlsError> {
    PrivateKeyDer::from_pem_slice(&read(path)?).map_err(|e| TlsError::Invalid(format!("{}: clave privada inválida: {e}", path.display())))
}

/// Almacén de CAs raíz a partir de un fichero PEM.
pub fn load_roots(path: &Path) -> Result<RootCertStore, TlsError> {
    let mut roots = RootCertStore::empty();
    for cert in load_certs(path)? {
        roots.add(cert)?;
    }
    Ok(roots)
}

/// Proveedor criptográfico explícito ("ring"): no dependemos de cuál esté
/// instalado por defecto en el proceso.
pub fn crypto_provider() -> Arc<rustls::crypto::CryptoProvider> {
    Arc::new(rustls::crypto::ring::default_provider())
}

/// Configuración TLS de cliente (solo TLS 1.3) para PostgreSQL y Redis.
pub fn client_config(roots: RootCertStore) -> Result<rustls::ClientConfig, TlsError> {
    Ok(rustls::ClientConfig::builder_with_provider(crypto_provider())
        .with_protocol_versions(&[&rustls::version::TLS13])?
        .with_root_certificates(roots)
        .with_no_client_auth())
}

/// Configuración del servidor: TLS 1.3 obligatorio, certificado de cliente
/// obligatorio y firmado por la CA de clientes, y ALPN "h2" (gRPC va sobre HTTP/2).
pub fn server_config(files: &GrpcTlsFiles) -> Result<Arc<rustls::ServerConfig>, TlsError> {
    let provider = crypto_provider();
    let client_roots = Arc::new(load_roots(&files.client_ca_file)?);
    let verifier = WebPkiClientVerifier::builder_with_provider(client_roots, provider.clone()).build()?;
    let mut config = rustls::ServerConfig::builder_with_provider(provider)
        .with_protocol_versions(&[&rustls::version::TLS13])?
        .with_client_cert_verifier(verifier)
        .with_single_cert(load_certs(&files.cert_file)?, load_key(&files.key_file)?)?;
    config.alpn_protocols = vec![b"h2".to_vec()];
    Ok(Arc::new(config))
}

/// Lista de identidades de cliente permitidas (vacía = cualquiera con
/// certificado válido de nuestra CA).
#[derive(Debug, Clone, Default)]
pub struct ClientAllowlist(Vec<String>);

impl ClientAllowlist {
    /// Crea la lista.
    pub fn new(names: Vec<String>) -> Self {
        Self(names)
    }

    /// Devuelve la identidad del cliente si está permitido, o el motivo del rechazo.
    ///
    /// La identidad es el primer nombre DNS (SAN) del certificado o, si no
    /// tiene, su Common Name (CN). Con una lista definida, basta con que
    /// CUALQUIERA de sus nombres esté en la lista.
    pub fn check(&self, cert: &CertificateDer<'_>) -> Result<String, String> {
        let (_, parsed) = x509_parser::parse_x509_certificate(cert.as_ref()).map_err(|e| format!("certificado ilegible: {e}"))?;
        let mut names: Vec<String> = parsed
            .subject_alternative_name()
            .ok()
            .flatten()
            .map(|san| {
                san.value
                    .general_names
                    .iter()
                    .filter_map(|name| match name {
                        x509_parser::extensions::GeneralName::DNSName(dns) => Some((*dns).to_owned()),
                        _ => None,
                    })
                    .collect()
            })
            .unwrap_or_default();
        names.extend(parsed.subject().iter_common_name().filter_map(|cn| cn.as_str().ok()).map(str::to_owned));
        let identity = names.first().cloned().ok_or_else(|| "certificado sin nombre (ni SAN DNS ni CN)".to_owned())?;
        if self.0.is_empty() || names.iter().any(|n| self.0.contains(n)) {
            Ok(identity)
        } else {
            Err(format!("cliente {identity:?} no está en GRPC_ALLOWED_CLIENTS"))
        }
    }
}

/// Información de la conexión que tonic guarda en cada petición: dirección
/// del cliente e identidad de su certificado (para los logs de auditoría).
#[derive(Debug, Clone)]
pub struct PeerInfo {
    /// Dirección IP y puerto del cliente.
    pub remote_addr: Option<SocketAddr>,
    /// Identidad del certificado del cliente.
    pub identity: String,
}

/// Una conexión TLS ya verificada. Envuelve el flujo cifrado y le enseña a
/// tonic de dónde viene (trait `Connected`).
#[derive(Debug)]
pub struct VerifiedTlsConn {
    stream: TlsStream<TcpStream>,
    peer: PeerInfo,
}

impl Connected for VerifiedTlsConn {
    type ConnectInfo = PeerInfo;

    fn connect_info(&self) -> Self::ConnectInfo {
        self.peer.clone()
    }
}

// Leer y escribir se delega tal cual en el flujo TLS. `TlsStream<TcpStream>`
// es `Unpin` (se puede mover en memoria sin peligro), así que basta con
// `Pin::new`, sin código `unsafe`.
impl AsyncRead for VerifiedTlsConn {
    fn poll_read(mut self: Pin<&mut Self>, cx: &mut Context<'_>, buf: &mut ReadBuf<'_>) -> Poll<io::Result<()>> {
        Pin::new(&mut self.stream).poll_read(cx, buf)
    }
}

impl AsyncWrite for VerifiedTlsConn {
    fn poll_write(mut self: Pin<&mut Self>, cx: &mut Context<'_>, buf: &[u8]) -> Poll<io::Result<usize>> {
        Pin::new(&mut self.stream).poll_write(cx, buf)
    }

    fn poll_flush(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        Pin::new(&mut self.stream).poll_flush(cx)
    }

    fn poll_shutdown(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        Pin::new(&mut self.stream).poll_shutdown(cx)
    }

    fn poll_write_vectored(mut self: Pin<&mut Self>, cx: &mut Context<'_>, bufs: &[io::IoSlice<'_>]) -> Poll<io::Result<usize>> {
        Pin::new(&mut self.stream).poll_write_vectored(cx, bufs)
    }

    fn is_write_vectored(&self) -> bool {
        self.stream.is_write_vectored()
    }
}

/// Acepta conexiones TCP, hace el saludo TLS de cada una EN PARALELO (un
/// cliente lento no frena a los demás) y entrega a tonic solo las válidas.
///
/// Devuelve un flujo ("stream") de conexiones listo para
/// `Server::serve_with_incoming_shutdown`. Cuando tonic deja de leerlo (al
/// apagarse), el bucle de aceptación termina solo.
pub fn verified_incoming(
    listener: TcpListener,
    config: Arc<rustls::ServerConfig>,
    allowlist: ClientAllowlist,
) -> ReceiverStream<Result<VerifiedTlsConn, io::Error>> {
    let (tx, rx) = mpsc::channel(128);
    let acceptor = TlsAcceptor::from(config);
    let allowlist = Arc::new(allowlist);
    let limiter = Arc::new(Semaphore::new(MAX_CONCURRENT_HANDSHAKES));
    tokio::spawn(async move {
        loop {
            let accepted = tokio::select! {
                () = tx.closed() => break,
                accepted = listener.accept() => accepted,
            };
            let (tcp, remote_addr) = match accepted {
                Ok(pair) => pair,
                Err(e) => {
                    // Por ejemplo, "demasiados ficheros abiertos": esperar un
                    // poco en vez de girar en vacío consumiendo CPU.
                    tracing::warn!(error = %e, "error aceptando conexión gRPC");
                    tokio::time::sleep(Duration::from_millis(100)).await;
                    continue;
                }
            };
            let Ok(permit) = limiter.clone().try_acquire_owned() else {
                tracing::warn!(%remote_addr, "demasiados saludos TLS a la vez: conexión rechazada");
                continue;
            };
            let (acceptor, allowlist, tx) = (acceptor.clone(), allowlist.clone(), tx.clone());
            tokio::spawn(async move {
                let _permit = permit;
                let _ = tcp.set_nodelay(true);
                let stream = match tokio::time::timeout(HANDSHAKE_TIMEOUT, acceptor.accept(tcp)).await {
                    Ok(Ok(stream)) => stream,
                    Ok(Err(e)) => {
                        tracing::info!(%remote_addr, error = %e, "saludo TLS rechazado");
                        return;
                    }
                    Err(_) => {
                        tracing::info!(%remote_addr, "saludo TLS demasiado lento");
                        return;
                    }
                };
                let Some(cert) = stream.get_ref().1.peer_certificates().and_then(|c| c.first()) else {
                    // No debería pasar: el verificador exige certificado.
                    tracing::warn!(%remote_addr, "conexión sin certificado de cliente");
                    return;
                };
                match allowlist.check(cert) {
                    Ok(identity) => {
                        let conn = VerifiedTlsConn { stream, peer: PeerInfo { remote_addr: Some(remote_addr), identity } };
                        let _ = tx.send(Ok(conn)).await;
                    }
                    Err(reason) => tracing::warn!(%remote_addr, %reason, "cliente gRPC no autorizado"),
                }
            });
        }
        tracing::debug!("bucle de aceptación gRPC terminado");
    });
    ReceiverStream::new(rx)
}
