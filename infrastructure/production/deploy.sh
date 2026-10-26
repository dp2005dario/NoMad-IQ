#!/usr/bin/env bash
# =============================================================================
# Despliega (o actualiza) NomadIQ en el servidor. Se ejecuta DENTRO del
# servidor, después de bootstrap.sh, y cada vez que quieras subir cambios:
#
#   cd ~/NoMad-IQ && git pull
#   sudo infrastructure/production/deploy.sh
#
# Qué hace:
#   1. Lee secrets.env y config.env (y genera los secretos "auto" que falten).
#   2. Crea la llave de firma de las sesiones (JWT) si no existe.
#   3. Descarga las voces de Piper (comprobando su huella SHA-256).
#   4. Construye las imágenes AQUÍ (sin registro de imágenes: 0 €) y se las
#      da a k3s.
#   5. Guarda secretos y configuración en Kubernetes (cifrados en disco).
#   6. Aplica todos los manifiestos de k8s/ y reinicia los servicios para que
#      usen las imágenes nuevas.
#
# Nunca imprime un secreto por pantalla.
# =============================================================================
set -euo pipefail

PROD="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$PROD/../.." && pwd)"
KEYS=/etc/nomadiq                 # llaves que NO van en git ni en el repo
KUBECTL=(k3s kubectl)
NS=nomadiq

if [ "$(id -u)" -ne 0 ]; then
  echo "Ejecuta con sudo: sudo $0" >&2
  exit 1
fi

for f in secrets.env config.env; do
  if [ ! -f "$PROD/$f" ]; then
    echo "Falta $PROD/$f: cópialo de $f.example y rellénalo (docs/guia-produccion.md)." >&2
    exit 1
  fi
done
chmod 600 "$PROD/secrets.env"

echo "== 1/6 Secretos =="
# Si un secreto "auto" está vacío, se genera uno aleatorio y se guarda en el
# fichero (para que el siguiente despliegue use el MISMO: si cambiara la
# contraseña de la base de datos, los servicios ya no podrían entrar).
fill() {
  local key="$1" value="$2"
  if ! grep -Eq "^${key}=.+" "$PROD/secrets.env"; then
    sed -i "/^${key}=$/d" "$PROD/secrets.env"
    echo "${key}=${value}" >> "$PROD/secrets.env"
    echo "  generado ${key}"
  fi
}
fill POSTGRES_PASSWORD "$(openssl rand -hex 24)"
fill REDIS_PASSWORD "$(openssl rand -hex 24)"
fill NOTIFY_PSEUDONYM_KEY "$(openssl rand -hex 32)"
fill NOTIFY_TOKEN_KEY "$(openssl rand -hex 32)"
fill JAVA_TRUSTSTORE_PASSWORD "$(openssl rand -hex 24)"
fill BACKUP_PASSPHRASE "$(openssl rand -base64 33 | tr -d '/+=')"
# Kafka quiere un UUID en base64 "url" de 22 caracteres.
fill KAFKA_CLUSTER_ID "$(openssl rand -base64 16 | tr '+/' '-_' | tr -d '=')"

# Comprobar que lo obligatorio está relleno (sin enseñar los valores).
missing=()
for key in TRAVELPAYOUTS_TOKEN TRAVELPAYOUTS_MARKER FCM_PROJECT_ID \
  BACKUP_S3_ENDPOINT BACKUP_S3_REGION BACKUP_S3_ACCESS_KEY BACKUP_S3_SECRET_KEY NTFY_URL; do
  grep -Eq "^${key}=.+" "$PROD/secrets.env" || missing+=("$key")
done
for key in DOMAIN ACME_EMAIL OLLAMA_MODEL; do
  grep -Eq "^${key}=.+" "$PROD/config.env" || missing+=("$key")
done
if [ "${#missing[@]}" -gt 0 ]; then
  echo "Faltan valores en secrets.env/config.env: ${missing[*]}" >&2
  exit 1
fi

echo "== 2/6 Llaves =="
install -d -m 700 "$KEYS"
if [ ! -f "$KEYS/jwt-active.pem" ]; then
  # Llave privada EC P-256 (ES256) con la que auth-gateway firma las sesiones.
  openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$KEYS/jwt-active.pem"
  chmod 600 "$KEYS/jwt-active.pem"
  echo "  creada la llave de sesiones (JWT)"
fi
if [ ! -f "$KEYS/fcm.json" ]; then
  echo "Falta $KEYS/fcm.json (la cuenta de servicio de Firebase). Súbela con scp" >&2
  echo "y muévela allí: sudo mv fcm.json $KEYS/ && sudo chmod 600 $KEYS/fcm.json" >&2
  exit 1
fi

echo "== 3/6 Voces de Piper =="
bash "$REPO/infrastructure/tts/download-voices.sh"

echo "== 4/6 Imágenes (puede tardar la primera vez) =="
export DOCKER_BUILDKIT=1
build() {
  # build <nombre> <Dockerfile> [target]
  local name="$1" file="$2" target="${3:-}"
  local args=(-t "nomadiq/${name}:prod" -f "$file")
  [ -n "$target" ] && args+=(--target "$target")
  docker build "${args[@]}" "$REPO"
}
docker build -t nomadiq/postgres:prod -f "$PROD/postgres.Dockerfile" "$PROD"
for svc in flight-ingestor price-consumer auth-gateway ai-orchestrator geo-engine notifier; do
  build "$svc" "$REPO/services/$svc/Dockerfile"
done
build ai-orchestrator-audio-base "$REPO/services/ai-orchestrator/Dockerfile" audio-worker
build audio-worker "$PROD/audio-worker.Dockerfile"

# k3s no usa el almacén de Docker: le pasamos cada imagen. (Sin registro
# público ni de pago; "imagePullPolicy: Never" en los manifiestos.)
for img in postgres flight-ingestor price-consumer auth-gateway ai-orchestrator \
  geo-engine notifier audio-worker; do
  docker save "nomadiq/${img}:prod" | k3s ctr -n k8s.io images import -
done
# Borrar capas viejas para no llenar el disco (200 GB gratis, pero mejor así).
docker image prune -f >/dev/null

echo "== 5/6 Secretos y configuración en Kubernetes =="
"${KUBECTL[@]}" apply -f "$PROD/k8s/00-namespace.yaml"
# "create ... --dry-run | apply" = crear o actualizar, sin borrar nada antes.
upsert() { "${KUBECTL[@]}" apply -f - >/dev/null; }

"${KUBECTL[@]}" -n "$NS" create secret generic nomadiq-secrets \
  --from-env-file="$PROD/secrets.env" --dry-run=client -o yaml | upsert
"${KUBECTL[@]}" -n "$NS" create secret generic nomadiq-jwt \
  --from-file=jwt-active.pem="$KEYS/jwt-active.pem" --dry-run=client -o yaml | upsert
"${KUBECTL[@]}" -n "$NS" create secret generic nomadiq-fcm \
  --from-file=fcm.json="$KEYS/fcm.json" --dry-run=client -o yaml | upsert
NTFY_URL="$(grep -E '^NTFY_URL=' "$PROD/secrets.env" | cut -d= -f2-)"
"${KUBECTL[@]}" -n nomadiq-monitoring create secret generic alertmanager-ntfy \
  --from-literal=ntfy-url="$NTFY_URL" --dry-run=client -o yaml | upsert
unset NTFY_URL

"${KUBECTL[@]}" -n "$NS" create configmap nomadiq-config \
  --from-env-file="$PROD/config.env" --dry-run=client -o yaml | upsert
"${KUBECTL[@]}" -n "$NS" create configmap postgres-init \
  --from-file="$REPO/infrastructure/postgres/init" --dry-run=client -o yaml | upsert

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/client-ssl.properties" <<'EOF'
security.protocol=SSL
ssl.truststore.type=PEM
ssl.truststore.location=/certs/ca.crt
EOF
"${KUBECTL[@]}" -n "$NS" create configmap kafka-topics \
  --from-file=create-topics.sh="$REPO/infrastructure/kafka/create-topics.sh" \
  --from-file=client-ssl.properties="$TMP/client-ssl.properties" \
  --dry-run=client -o yaml | upsert

# Reglas de la puerta: las MISMAS de desarrollo, pasadas a https + mTLS.
python3 "$PROD/render_edge.py" "$REPO/infrastructure/edge/dynamic.yml" > "$TMP/dynamic.yml"
"${KUBECTL[@]}" -n "$NS" create configmap edge-dynamic \
  --from-file=dynamic.yml="$TMP/dynamic.yml" \
  --from-file=tls-options.yml="$PROD/tls-options.yml" \
  --dry-run=client -o yaml | upsert

echo "== 6/6 Manifiestos =="
# Un Job no se puede modificar: se borra el anterior (ya terminó) y se crea
# de nuevo, que vuelve a comprobar los topics de Kafka (es idempotente).
"${KUBECTL[@]}" -n "$NS" delete job kafka-topics --ignore-not-found >/dev/null
"${KUBECTL[@]}" apply -k "$PROD/k8s"
# Las imágenes se llaman siempre ":prod": hay que reiniciar para que los
# servicios usen la recién construida.
"${KUBECTL[@]}" -n "$NS" rollout restart deployment
for d in $("${KUBECTL[@]}" -n "$NS" get deployment -o name); do
  "${KUBECTL[@]}" -n "$NS" rollout status "$d" --timeout=600s
done

echo
echo "Desplegado. Comprueba:  sudo k3s kubectl -n $NS get pods"
echo "y abre https://$(grep -E '^DOMAIN=' "$PROD/config.env" | cut -d= -f2-)/.well-known/jwks.json  (debe salir una llave pública)"
