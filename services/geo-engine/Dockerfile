# syntax=docker/dockerfile:1
# Construcción en dos etapas:
#   1. "build": compila el binario con Rust (compilador, cabeceras de OpenSSL...).
#   2. Imagen final: solo el binario sobre "distroless" (sin shell ni gestor de
#      paquetes: menos superficie de ataque) y ejecutándose sin root.
#
# Se construye desde la raíz del repositorio porque necesita proto/:
#   docker build -f services/geo-engine/Dockerfile .

# La misma versión que fija rust-toolchain.toml.
FROM rust:1.97.0-bookworm AS build
# librdkafka (cliente de Kafka en C) se compila aquí y necesita las cabeceras
# de OpenSSL para hablar TLS con Kafka en producción.
RUN apt-get update \
 && apt-get install -y --no-install-recommends libssl-dev pkg-config \
 && rm -rf /var/lib/apt/lists/*
# La imagen ya trae Rust 1.97.0; esto evita que rustup intente descargar
# clippy y rustfmt (que pide rust-toolchain.toml) y que aquí no hacen falta.
ENV RUSTUP_TOOLCHAIN=1.97.0
WORKDIR /src
COPY proto ./proto
COPY services/geo-engine ./services/geo-engine
WORKDIR /src/services/geo-engine
# Las "cache mounts" guardan las librerías descargadas y lo ya compilado entre
# construcciones: la segunda vez solo se recompila lo que cambió.
# --locked: falla si Cargo.lock no está al día (nada de versiones sorpresa).
RUN --mount=type=cache,target=/usr/local/cargo/registry \
    --mount=type=cache,target=/src/services/geo-engine/target \
    cargo build --release --locked \
 && mkdir -p /out && cp target/release/geo-engine /out/geo-engine

# "cc" = distroless con la librería de C (glibc), libgcc y OpenSSL: lo justo
# para un binario de Rust que enlaza librdkafka.
FROM gcr.io/distroless/cc-debian12:nonroot
COPY --from=build /out/geo-engine /geo-engine
USER nonroot:nonroot
EXPOSE 50052 8087 8090
HEALTHCHECK --interval=15s --timeout=5s --start-period=20s --retries=3 CMD ["/geo-engine", "--healthcheck"]
ENTRYPOINT ["/geo-engine"]
