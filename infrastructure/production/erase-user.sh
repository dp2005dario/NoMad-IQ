#!/usr/bin/env bash
# =============================================================================
# Borra la cuenta y TODOS los datos de una persona que lo pide por correo
# (porque ya no tiene la app o no recuerda la contraseña).
#
#   sudo infrastructure/production/erase-user.sh correo@ejemplo.com
#
# ANTES de ejecutarlo comprueba que el correo de la petición llega DESDE esa
# misma dirección (si no, cualquiera podría borrar la cuenta de otro).
#
# Hace lo mismo que "Borrar mi cuenta y mis datos" en la app:
#   1. Busca el id de la cuenta por su correo.
#   2. ai-orchestrator borra/anonimiza sus datos (misma lógica que la app).
#   3. Se borran sus alertas de vuelos, sus teléfonos para avisos y, por
#      último, la cuenta (con sus sesiones).
# No imprime nada de la persona: solo cuántas cosas se borraron.
# =============================================================================
set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo "uso: sudo $0 correo@ejemplo.com" >&2
  exit 2
fi
EMAIL="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
K=(k3s kubectl -n nomadiq)

# psql dentro del pod de PostgreSQL. Los valores van como variables de psql
# (:'nombre'), que psql escapa: nada de pegar texto dentro del SQL.
# shellcheck disable=SC2016  # las $ son para el sh del pod, no para este
psql_in() {
  "${K[@]}" exec -i postgres-0 -- sh -c \
    'PGPASSWORD="$POSTGRES_PASSWORD" psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -At -v ON_ERROR_STOP=1 "$@"' _ "$@"
}

USER_ID="$(echo "SELECT id FROM identity.users WHERE email = :'email';" | psql_in -v email="$EMAIL")"
if [ -z "$USER_ID" ]; then
  echo "No hay ninguna cuenta con ese correo (puede que ya se borrara)." >&2
  exit 1
fi

echo "== Datos del ai-orchestrator =="
REPORT="$("${K[@]}" exec deploy/ai-orchestrator -- python -m ai_orchestrator.erase_user "$USER_ID")"
RECIPIENT="$(printf '%s' "$REPORT" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("recipient", ""))')"
printf '%s' "$REPORT" | python3 -c 'import json,sys; d=json.load(sys.stdin); d.pop("recipient", None); print(d)'

echo "== Alertas de vuelos, teléfonos y cuenta =="
psql_in -v uid="$USER_ID" -v rcp="$RECIPIENT" <<'SQL'
BEGIN;
DELETE FROM flights.fare_subscriptions WHERE user_id = :'uid';
DELETE FROM flights.fare_alerts WHERE user_id = :'uid';
DELETE FROM notify.devices WHERE recipient = :'rcp';
DELETE FROM identity.users WHERE id = :'uid';
COMMIT;
SQL

echo "Hecho. Responde a la persona confirmando el borrado. Las copias de"
echo "seguridad con sus datos desaparecen solas en 14 días."
