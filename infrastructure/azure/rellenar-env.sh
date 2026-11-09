#!/usr/bin/env bash
# =============================================================================
# Rellena config.env y secrets.env EN EL SERVIDOR con lo que se sabe solo.
# Lo llama crear-servidor.sh (desde la Cloud Shell) por SSH; no hace falta
# ejecutarlo a mano.
#
#   rellenar-env.sh DOMINIO CORREO LLM CUENTA CONTENEDOR TEMA_NTFY
#   (la clave del almacén llega por la entrada estándar, nunca como argumento:
#    así no aparece en la lista de procesos ni en ningún historial)
#
# No toca las claves que ya estén puestas (Travelpayouts, etc.).
# =============================================================================
set -euo pipefail

DOMAIN="$1" EMAIL="$2" LLM="$3" ACCOUNT="$4" CONTAINER="$5" TOPIC="$6"
IFS= read -r KEY

cd "$(dirname "$0")/../production"
[ -f config.env ] || cp config.env.example config.env
[ -f secrets.env ] || cp secrets.env.example secrets.env
chmod 600 secrets.env

# put FICHERO CLAVE VALOR: cambia (o añade) una línea CLAVE=VALOR.
put() {
  local file="$1" key="$2" value="$3" tmp
  tmp="$(mktemp "./.env.XXXXXX")"
  chmod 600 "$tmp"
  grep -v "^${key}=" "$file" > "$tmp" || true
  printf '%s=%s\n' "$key" "$value" >> "$tmp"
  mv "$tmp" "$file"
}

put config.env DOMAIN "$DOMAIN"
put config.env ACME_EMAIL "$EMAIL"
put config.env LLM_ENABLED "$LLM"
put config.env BACKUP_PROVIDER azure
put secrets.env BACKUP_AZURE_ACCOUNT "$ACCOUNT"
put secrets.env BACKUP_AZURE_KEY "$KEY"
put secrets.env BACKUP_BUCKET "$CONTAINER"
# El tema de avisos solo se pone la primera vez (si no, cambiaría cada vez).
grep -q '^NTFY_URL=.' secrets.env || put secrets.env NTFY_URL "https://ntfy.sh/$TOPIC"
unset KEY
echo "config.env y secrets.env rellenados (faltan tus claves: poner-clave.sh)."
