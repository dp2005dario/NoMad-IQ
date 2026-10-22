# Atajos para el día a día. Ejecuta "make help" para ver la lista.
# Cada "objetivo" (proto, test, up...) es un atajo: "make up" ejecuta los
# comandos de debajo. Las líneas de comando deben empezar con un tabulador.
# .PHONY indica que son nombres de tareas, no ficheros que generar.
.PHONY: help proto proto-python test test-java test-python test-rust test-rust-integration test-integration up up-apps down logs alerts ollama recommendations zones

help: ## Muestra esta ayuda
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  %-18s %s\n", $$1, $$2}'

proto: ## Valida los .proto y regenera el código en gen/
	cd proto && buf lint && buf generate

test: ## Tests unitarios de todos los servicios Go (con detector de carreras)
	cd services/flight-ingestor && go vet ./... && go test -race ./...
	cd services/price-consumer && go vet ./... && go test -race ./...

proto-python: ## Regenera el código Python de los .proto (ai-orchestrator)
	cd services/ai-orchestrator && uv run python scripts/generate_proto.py

test-python: ## ai-orchestrator: estilo (ruff), tipos (mypy) y tests unitarios (sin Ollama real)
	cd services/ai-orchestrator && uv run ruff format --check . && uv run ruff check . && uv run mypy && uv run pytest -q

test-java: ## Tests del auth-gateway: unitarios + integración con Testcontainers (requiere Docker)
	cd services/auth-gateway && ./mvnw -B verify

test-rust: ## geo-engine: formato, clippy (avisos = errores) y tests unitarios + mTLS
	cd services/geo-engine && cargo fmt --check && cargo clippy --all-targets -- -D warnings && cargo test

# Los e2e necesitan además el geo-engine en marcha ("make up-apps").
test-rust-integration: ## geo-engine: tests contra PostGIS, Redis y Kafka reales (requiere "make up")
	cd services/geo-engine && set -a && . ../../infrastructure/.env && set +a && \
		KAFKA_BROKERS=localhost:29092 GEO_ENGINE_GRPC=http://127.0.0.1:50052 REDIS_HOST=localhost \
		PGHOST=localhost PGUSER="$$POSTGRES_USER" PGPASSWORD="$$POSTGRES_PASSWORD" PGDATABASE="$$POSTGRES_DB" \
		cargo test --test integration -- --ignored

# Para el price-consumer se leen usuario y contraseña de infrastructure/.env.
test-integration: ## Tests contra Kafka y PostgreSQL de docker compose (requiere "make up")
	cd services/flight-ingestor && KAFKA_BROKERS=localhost:29092 go test -tags integration -count=1 ./internal/publisher/
	cd services/price-consumer && set -a && . ../../infrastructure/.env && set +a && \
		KAFKA_BROKERS=localhost:29092 PGHOST=localhost PGUSER="$$POSTGRES_USER" PGPASSWORD="$$POSTGRES_PASSWORD" PGDATABASE="$$POSTGRES_DB" \
		go test -tags integration -count=1 ./internal/store/ ./internal/kafka/
	cd services/ai-orchestrator && set -a && . ../../infrastructure/.env && set +a && \
		KAFKA_BROKERS=localhost:29092 PGHOST=localhost PGUSER="$$POSTGRES_USER" PGPASSWORD="$$POSTGRES_PASSWORD" PGDATABASE="$$POSTGRES_DB" \
		uv run pytest -m integration -q

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

# Descarga el modelo la primera vez (varios GB); después arranca en segundos.
ollama: ## Arranca Ollama (LLM local) y descarga el modelo (OLLAMA_MODEL, por defecto llama3.1:8b)
	cd infrastructure && docker compose --profile ai up -d --wait ollama && \
		docker compose exec ollama ollama pull $${OLLAMA_MODEL:-llama3.1:8b}

recommendations: ## Muestra las últimas recomendaciones generadas por el ai-orchestrator
	cd infrastructure && docker compose exec postgres sh -c 'PGPASSWORD="$$POSTGRES_PASSWORD" psql -h 127.0.0.1 -U "$$POSTGRES_USER" -d "$$POSTGRES_DB" -c "SELECT created_at, user_id, verdict, source, headline FROM ai.fare_recommendations ORDER BY created_at DESC LIMIT 20"'

zones: ## Muestra las zonas de geofencing guardadas en PostGIS (geo-engine)
	cd infrastructure && docker compose exec postgres sh -c 'PGPASSWORD="$$POSTGRES_PASSWORD" psql -h 127.0.0.1 -U "$$POSTGRES_USER" -d "$$POSTGRES_DB" -c "SELECT slug, kind, active, round(ST_Area(geom::geography)) AS m2, updated_at FROM geo.zones ORDER BY slug"'
