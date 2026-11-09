#!/usr/bin/env bash
# =============================================================================
# Pone UNA clave en secrets.env sin que se vea en la pantalla ni quede en el
# historial de la terminal. Se ejecuta EN EL SERVIDOR:
#
#   sudo infrastructure/production/poner-clave.sh TRAVELPAYOUTS_TOKEN
#
# Te pide que pegues el valor (no se ve mientras lo pegas: es normal) y lo
# guarda en secrets.env, cambiando el que hubiera. Después:
#   sudo infrastructure/production/deploy.sh
# para que los servicios usen la clave nueva.
# =============================================================================
set -euo pipefail

PROD="$(cd "$(dirname "$0")" && pwd)"
FILE="$PROD/secrets.env"
KEY="${1:-}"

if [ "$(id -u)" -ne 0 ]; then
  echo "Ejecuta con sudo: sudo $0 NOMBRE_DE_LA_CLAVE" >&2
  exit 1
fi
# Solo nombres que ya están en la plantilla (así no se cuela una errata).
if [ -z "$KEY" ] || ! grep -Eq "^${KEY}=" "$PROD/secrets.env.example"; then
  echo "Dime qué clave quieres poner. Las que hay:" >&2
  grep -Eo '^[A-Z0-9_]+=' "$PROD/secrets.env.example" | tr -d '=' | sed 's/^/  /' >&2
  exit 1
fi
[ -f "$FILE" ] || cp "$PROD/secrets.env.example" "$FILE"
chmod 600 "$FILE"

# -s: no se ve lo que pegas. -r: las barras "\" se guardan tal cual.
read -r -s -p "Pega el valor de ${KEY} y pulsa Enter (no se verá): " VALUE
echo
# Quitar espacios o saltos de línea que se cuelan al copiar.
VALUE="$(printf '%s' "$VALUE" | tr -d '\r\n' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
if [ -z "$VALUE" ]; then
  echo "No has pegado nada: no cambio nada." >&2
  exit 1
fi

# Se reescribe el fichero sin la línea vieja y con la nueva al final.
TMP="$(mktemp "$PROD/.secrets.XXXXXX")"
chmod 600 "$TMP"
grep -Ev "^${KEY}=" "$FILE" > "$TMP" || true
printf '%s=%s\n' "$KEY" "$VALUE" >> "$TMP"
mv "$TMP" "$FILE"
unset VALUE
echo "Guardada ${KEY} (el valor no se enseña)."
echo "Cuando termines de poner claves: sudo $PROD/deploy.sh"
