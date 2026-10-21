#!/usr/bin/env bash
# Crea los topics de Kafka de forma idempotente (se puede ejecutar varias veces).
# Lo lanza el contenedor "kafka-init" cuando el broker está sano.
set -euo pipefail

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
)

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

"${KAFKA_BIN}/kafka-topics.sh" --bootstrap-server "${BOOTSTRAP}" --list
