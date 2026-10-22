# syntax=docker/dockerfile:1
# Construcción en dos etapas, igual que los otros servicios Go: la primera
# compila; la segunda solo lleva los binarios (~25 MB, sin shell ni gestor de
# paquetes, sin root).
#
# Una sola imagen con tres binarios:
#   /notifier    el servicio (lo que arranca por defecto)
#   /fcm-fake    FCM falso para desarrollo y CI (docker compose lo usa con
#                "entrypoint: /fcm-fake"; en producción no se despliega)
#   /notifyctl   herramienta para generar claves y descifrar avisos a mano
#
# Se construye desde la raíz del repositorio porque necesita gen/go:
#   docker build -f services/notifier/Dockerfile .

FROM golang:1.24-alpine AS build
WORKDIR /src

COPY gen/go/go.mod gen/go/go.sum ./gen/go/
COPY services/notifier/go.mod services/notifier/go.sum ./services/notifier/
WORKDIR /src/services/notifier
RUN go mod download

WORKDIR /src
COPY gen/go ./gen/go
COPY services/notifier ./services/notifier
WORKDIR /src/services/notifier
RUN for cmd in notifier fcm-fake notifyctl; do \
      CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w" -o /out/$cmd ./cmd/$cmd || exit 1; \
    done

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /out/ /
USER nonroot:nonroot
EXPOSE 8089 8090
HEALTHCHECK --interval=15s --timeout=5s --start-period=10s --retries=3 CMD ["/notifier", "-healthcheck"]
ENTRYPOINT ["/notifier"]
