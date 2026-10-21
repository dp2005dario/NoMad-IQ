# Atajos para el día a día. Ejecuta "make help" para ver la lista.
.PHONY: help proto test test-integration up up-apps down logs alerts

help: ## Muestra esta ayuda
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  %-18s %s\n", $$1, $$2}'

proto: ## Valida los .proto y regenera el código en gen/
	cd proto && buf lint && buf generate

test: ## Tests unitarios de todos los servicios Go (con detector de carreras)
	cd services/flight-ingestor && go vet ./... && go test -race ./...
	cd services/price-consumer && go vet ./... && go test -race ./...

# Para el price-consumer se leen usuario y contraseña de infrastructure/.env.
test-integration: ## Tests contra Kafka y PostgreSQL de docker compose (requiere "make up")
	cd services/flight-ingestor && KAFKA_BROKERS=localhost:29092 go test -tags integration -count=1 ./internal/publisher/
	cd services/price-consumer && set -a && . ../../infrastructure/.env && set +a && \
		KAFKA_BROKERS=localhost:29092 PGHOST=localhost PGUSER="$$POSTGRES_USER" PGPASSWORD="$$POSTGRES_PASSWORD" PGDATABASE="$$POSTGRES_DB" \
		go test -tags integration -count=1 ./internal/store/ ./internal/kafka/

up: ## Arranca la infraestructura (Kafka, PostgreSQL, Redis, Qdrant)
	cd infrastructure && docker compose up -d --wait

up-apps: ## Arranca infraestructura + microservicios
	cd infrastructure && docker compose --profile apps up -d --build --wait

down: ## Para todo (los datos se conservan en los volúmenes)
	cd infrastructure && docker compose --profile apps down

logs: ## Sigue los logs de todos los contenedores
	cd infrastructure && docker compose --profile apps logs -f

# Lee de PostgreSQL (legible) en vez de Kafka (allí el contenido es protobuf binario).
alerts: ## Muestra las últimas alertas de chollos detectadas
	cd infrastructure && docker compose exec postgres sh -c 'PGPASSWORD="$$POSTGRES_PASSWORD" psql -h 127.0.0.1 -U "$$POSTGRES_USER" -d "$$POSTGRES_DB" -c "SELECT created_at, user_id, alert_type, route_key, current_amount_minor AS precio, reference_amount_minor AS referencia, drop_basis_points AS bajada_pb, published_at IS NOT NULL AS publicada FROM flights.fare_alerts ORDER BY created_at DESC LIMIT 20"'
