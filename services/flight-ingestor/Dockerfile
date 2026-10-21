# syntax=docker/dockerfile:1
# Construcción en dos etapas: la primera compila con todas las herramientas;
# la segunda solo contiene el binario. Imagen final: ~20 MB, sin shell ni
# gestor de paquetes (menos superficie de ataque) y ejecutándose sin root.
#
# Se construye desde la raíz del repositorio porque necesita gen/go:
#   docker build -f services/flight-ingestor/Dockerfile .

FROM golang:1.24-alpine AS build
WORKDIR /src

# Primero solo los go.mod/go.sum: Docker cachea la descarga de dependencias
# y no la repite mientras no cambien.
COPY gen/go/go.mod gen/go/go.sum ./gen/go/
COPY services/flight-ingestor/go.mod services/flight-ingestor/go.sum ./services/flight-ingestor/
WORKDIR /src/services/flight-ingestor
RUN go mod download

WORKDIR /src
COPY gen/go ./gen/go
COPY services/flight-ingestor ./services/flight-ingestor
WORKDIR /src/services/flight-ingestor
# CGO_ENABLED=0: binario estático, no depende de librerías del sistema.
# -trimpath y -s -w: sin rutas locales ni símbolos de depuración.
RUN CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w" -o /out/flight-ingestor ./cmd/flight-ingestor

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /out/flight-ingestor /flight-ingestor
USER nonroot:nonroot
EXPOSE 50051 8081
HEALTHCHECK --interval=15s --timeout=5s --start-period=10s --retries=3 CMD ["/flight-ingestor", "-healthcheck"]
ENTRYPOINT ["/flight-ingestor"]
