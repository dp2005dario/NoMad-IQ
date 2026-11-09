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

# Lee un valor de config.env (sin enseñarlo; config.env no tiene secretos).
conf() { grep -E "^$1=" "$PROD/config.env" | tail -n1 | cut -d= -f2- || true; }

# Dónde van las copias: Oracle ("oci", por defecto) o Azure ("azure").
BACKUP_PROVIDER="$(conf BACKUP_PROVIDER)"
BACKUP_PROVIDER="${BACKUP_PROVIDER:-oci}"
case "$BACKUP_PROVIDER" in
  oci) backup_keys=(BACKUP_S3_ENDPOINT BACKUP_S3_REGION BACKUP_S3_ACCESS_KEY BACKUP_S3_SECRET_KEY) ;;
  azure) backup_keys=(BACKUP_AZURE_ACCOUNT BACKUP_AZURE_KEY) ;;
  *)
    echo "BACKUP_PROVIDER debe ser oci o azure (en config.env)." >&2
    exit 1
    ;;
esac

# ¿IA local (Ollama)? En un servidor de 8 GB no cabe: LLM_ENABLED=false.
LLM_ENABLED="$(conf LLM_ENABLED)"
LLM_ENABLED="${LLM_ENABLED:-true}"

# ¿Avisos push? Solo si está el json de Firebase (si no, el notifier no se
# arranca y la app funciona igual, sin avisos al móvil).
PUSH=true
[ -f "$KEYS/fcm.json" ] || PUSH=false

# Comprobar que lo obligatorio está relleno (sin enseñar los valores).
missing=()
required=(TRAVELPAYOUTS_TOKEN TRAVELPAYOUTS_MARKER NTFY_URL "${backup_keys[@]}")
[ "$PUSH" = true ] && required+=(FCM_PROJECT_ID)
for key in "${required[@]}"; do
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
if [ "$PUSH" = false ]; then
  echo "  AVISO: falta $KEYS/fcm.json (Firebase): se despliega SIN avisos push."
  echo "  Cuando lo tengas: sudo mv fcm.json $KEYS/ && sudo chmod 600 $KEYS/fcm.json"
  echo "  y vuelve a ejecutar este script."
fi

echo "== 3/6 Voces de Piper =="
bash "$REPO/infrastructure/tts/download-voices.sh"

echo "== 4/6 Imágenes (puede tardar la primera vez) =="
export DOCKER_BUILDKIT=1
# En un servidor de 8 GB, compilar Java y Rust a la vez puede quedarse sin
# memoria. Durante la construcción se usa un "swap" (memoria de reserva en el
# disco) de 8 GB, y se quita al acabar (Kubernetes no quiere swap).
MEM_GB=$(( $(awk '/MemTotal/ {print $2}' /proc/meminfo) / 1024 / 1024 ))
SWAP=false
if [ "$MEM_GB" -lt 12 ]; then
  [ -f /swapfile.build ] || { fallocate -l 8G /swapfile.build && chmod 600 /swapfile.build && mkswap /swapfile.build >/dev/null; }
  swapon /swapfile.build 2>/dev/null && SWAP=true
fi
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
[ "$SWAP" = true ] && swapoff /swapfile.build
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
if [ "$PUSH" = true ]; then
  "${KUBECTL[@]}" -n "$NS" create secret generic nomadiq-fcm \
    --from-file=fcm.json="$KEYS/fcm.json" --dry-run=client -o yaml | upsert
fi
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
# Lo que se apaga en un servidor pequeño o sin Firebase: se quita del
# paquete ANTES de aplicarlo (así ni siquiera arranca) y, si ya estaba de
# un despliegue anterior, se borra.
skip=()
[ "$LLM_ENABLED" = false ] && skip+=(StatefulSet/ollama)
[ "$PUSH" = false ] && skip+=(Deployment/notifier)
"${KUBECTL[@]}" kustomize "$PROD/k8s" > "$TMP/all.yaml"
python3 "$PROD/skip_kinds.py" "${skip[@]}" < "$TMP/all.yaml" > "$TMP/apply.yaml"
"${KUBECTL[@]}" apply -f "$TMP/apply.yaml"
for item in "${skip[@]}"; do
  "${KUBECTL[@]}" -n "$NS" delete "${item,,}" --ignore-not-found >/dev/null
  echo "  apagado: $item"
done
# Las imágenes se llaman siempre ":prod": hay que reiniciar para que los
# servicios usen la recién construida.
"${KUBECTL[@]}" -n "$NS" rollout restart deployment
for d in $("${KUBECTL[@]}" -n "$NS" get deployment -o name); do
  "${KUBECTL[@]}" -n "$NS" rollout status "$d" --timeout=600s
done

echo
echo "Desplegado. Comprueba:  sudo k3s kubectl -n $NS get pods"
echo "y abre https://$(grep -E '^DOMAIN=' "$PROD/config.env" | cut -d= -f2-)/.well-known/jwks.json  (debe salir una llave pública)"
