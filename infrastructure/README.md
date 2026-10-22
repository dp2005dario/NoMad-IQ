# infrastructure/ — Entorno local

Levanta en tu máquina todo lo que necesitan los microservicios.

| Servicio | Imagen | Puerto (solo 127.0.0.1) | Para qué |
|---|---|---|---|
| Kafka (KRaft) | `apache/kafka:3.9.1` | 29092 | Bus de eventos |
| PostgreSQL + PostGIS | `postgis/postgis:17-3.5` | 5432 | Datos relacionales y geoespaciales |
| Redis | `redis:7.4-alpine` | 6379 | Caché |
| Qdrant | `qdrant/qdrant:v1.13.6` | 6333 (REST), 6334 (gRPC) | Vectores para la IA |
| flight-ingestor | build local | 50051 (gRPC), 8081 (salud) | Perfil `apps` |
| notifier | build local | 8089 (API de teléfonos), 8090 (salud) | Perfil `apps`. Necesita las claves de `make keys` |
| fcm-fake | build local (misma imagen) | 8099 | Perfil `apps`. Firebase falso: `GET /messages` muestra lo que "vería Google" |

## Arranque

```bash
cd infrastructure
cp .env.example .env          # rellena cada valor (ver comentarios dentro)
make -C .. keys               # crea las claves de las notificaciones push si faltan
docker compose up -d --wait   # infraestructura
docker compose ps             # todo debe salir "healthy"; kafka-init "exited (0)"

# Con el microservicio y dos rutas de ejemplo:
SEED_WATCHES="MAD-NRT:2026-12-01:ECONOMY" POLL_INTERVAL=10s \
  docker compose --profile apps up -d --build --wait

# Ver los eventos que llegan a Kafka:
docker compose exec kafka /opt/kafka/bin/kafka-console-consumer.sh \
  --bootstrap-server localhost:9092 --topic flights.price-observed.v1 \
  --property print.key=true --property print.headers=true
```

`docker compose down` para todo y conserva los datos; `docker compose down -v`
**borra también los volúmenes** (datos de Kafka, PostgreSQL, Redis y Qdrant).

## Desarrollo frente a producción

Este compose es para desarrollo. En producción (Kubernetes) cambian varias cosas:

- Kafka con 3+ brokers, `replication-factor=3`, `min.insync.replicas=2` y listeners con mTLS.
- PostgreSQL gestionado o con réplicas, y cifrado del disco (AES-256 en reposo).
- Redis Cluster en lugar de un nodo.
- Secretos desde un gestor (Kubernetes Secrets + Sealed Secrets / Vault), nunca ficheros `.env`.
