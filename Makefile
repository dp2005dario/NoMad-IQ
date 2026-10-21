# Atajos para el día a día. Ejecuta "make help" para ver la lista.
# Cada "objetivo" (proto, test, up...) es un atajo: "make up" ejecuta los
# comandos de debajo. Las líneas de comando deben empezar con un tabulador.
# .PHONY indica que son nombres de tareas, no ficheros que generar.
.PHONY: help proto test test-integration up up-apps down logs

help: ## Muestra esta ayuda
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  %-18s %s\n", $$1, $$2}'

proto: ## Valida los .proto y regenera el código en gen/
	cd proto && buf lint && buf generate

test: ## Tests unitarios del flight-ingestor (con detector de carreras)
	cd services/flight-ingestor && go vet ./... && go test -race ./...

test-integration: ## Tests contra el Kafka de docker compose (requiere "make up")
	cd services/flight-ingestor && KAFKA_BROKERS=localhost:29092 go test -tags integration -count=1 ./internal/publisher/

up: ## Arranca la infraestructura (Kafka, PostgreSQL, Redis, Qdrant)
	cd infrastructure && docker compose up -d --wait

up-apps: ## Arranca infraestructura + microservicios
	cd infrastructure && docker compose --profile apps up -d --build --wait

down: ## Para todo (los datos se conservan en los volúmenes)
	cd infrastructure && docker compose --profile apps down

logs: ## Sigue los logs de todos los contenedores
	cd infrastructure && docker compose --profile apps logs -f
