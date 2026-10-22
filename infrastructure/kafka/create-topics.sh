#!/usr/bin/env bash
# Crea los topics de Kafka de forma idempotente (se puede ejecutar varias veces).
# Lo lanza el contenedor "kafka-init" cuando el broker está sano.
# -e: parar si un comando falla; -u: error si se usa una variable sin definir;
# -o pipefail: un fallo en medio de una tubería (a | b) también cuenta.
set -euo pipefail

# Dirección del broker; si no se define KAFKA_BOOTSTRAP se usa kafka:9092.
BOOTSTRAP="${KAFKA_BOOTSTRAP:-kafka:9092}"
KAFKA_BIN=/opt/kafka/bin

# nombre | particiones | retención en ms | política de limpieza
TOPICS=(
  # Observaciones de precio: mucho volumen, 7 días basta para recalcular.
  "flights.price-observed.v1|12|604800000|delete"
  # Alertas a usuarios: poco volumen, se guardan 30 días para auditoría.
  "flights.fare-alerts.v1|6|2592000000|delete"
  # Mensajes de precio imposibles de procesar (DLQ): se guardan 14 días para
  # investigarlos y, una vez corregido el fallo, volver a inyectarlos.
  "flights.price-observed-dlq.v1|3|1209600000|delete"
  # Alertas que el ai-orchestrator no pudo leer (DLQ): mismos 14 días.
  "flights.fare-alerts-dlq.v1|3|1209600000|delete"
  # Posiciones GPS de usuarios (geo-engine). Son DATOS PERSONALES: se guardan
  # solo 24 horas (minimización de datos, RGPD). Clave = user_id.
  "geo.user-positions.v1|12|86400000|delete"
  # Entradas y salidas de zonas detectadas por el geo-engine: 7 días.
  "geo.geofence-transitions.v1|6|604800000|delete"
  # Posiciones imposibles de procesar (DLQ): 3 días, también por privacidad.
  "geo.user-positions-dlq.v1|3|259200000|delete"
  # Entradas ANÓNIMAS a zonas (solo zone_id + idioma, sin user_id ni
  # coordenadas) para el ai-orchestrator. Clave = zone_id: una zona = una
  # partición = un solo consumidor que genera su audioguía. 24 horas: no hace
  # falta más, la audioguía queda en la caché de Redis.
  "geo.zone-entries.v1|6|86400000|delete"
  # Entradas a zonas que el ai-orchestrator no pudo leer (DLQ): 3 días.
  "geo.zone-entries-dlq.v1|3|259200000|delete"
)

# Recorre la lista y separa cada entrada por el carácter | en cuatro variables.
# replication-factor=1 porque en local solo hay un broker (en producción, 3).
for entry in "${TOPICS[@]}"; do
  IFS='|' read -r name partitions retention cleanup <<<"${entry}"
  echo "Asegurando topic ${name} (${partitions} particiones)"
  "${KAFKA_BIN}/kafka-topics.sh" --bootstrap-server "${BOOTSTRAP}" \
    --create --if-not-exists \
    --topic "${name}" \
    --partitions "${partitions}" \
    --replication-factor 1 \
    --config "retention.ms=${retention}" \
    --config "cleanup.policy=${cleanup}" \
    --config "min.insync.replicas=1"
done

# Muestra los topics existentes para comprobarlo en los logs.
"${KAFKA_BIN}/kafka-topics.sh" --bootstrap-server "${BOOTSTRAP}" --list
