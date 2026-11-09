#!/usr/bin/env bash
# =============================================================================
# Crea el servidor de ECLIPTA en Azure, con UNA orden, desde el navegador.
#
# Dónde se ejecuta: en la "Cloud Shell" de Azure (el icono >_ arriba a la
# derecha del portal, modo Bash). Allí ya está todo instalado y ya has
# entrado con tu cuenta: no hay que instalar nada en tu ordenador.
#
#   git clone https://github.com/dp2005dario/NoMad-IQ.git
#   bash NoMad-IQ/infrastructure/azure/crear-servidor.sh
#
# Qué crea (todo dentro del grupo "eclipta-rg", para borrarlo de golpe si
# algún día quieres):
#   1. Una cuenta de almacenamiento con un contenedor privado para las copias
#      de seguridad cifradas de la base de datos.
#   2. Una máquina Ubuntu 24.04 con un nombre web gratis de Azure
#      (eclipta-xxxxxx.<región>.cloudapp.azure.com) y solo las puertas 22
#      (SSH con llave), 80 y 443 abiertas.
#   3. Al arrancar, la máquina se descarga el código y se prepara sola
#      (bootstrap.sh: cortafuegos, Docker, k3s y cert-manager).
#   4. Deja escritos en la máquina config.env y secrets.env con todo lo que
#      se puede rellenar solo (dominio, correo, copias, avisos). Las claves
#      de webs externas (Travelpayouts...) las pones tú después, en la
#      máquina, con poner-clave.sh: nunca pasan por ningún chat.
#
# Opciones (se ponen delante de "bash"), por ejemplo:
#   REGION=northeurope bash NoMad-IQ/infrastructure/azure/crear-servidor.sh
#   REGION     región de Azure (por defecto westeurope = Países Bajos).
#   SIZE       tamaño de la máquina (por defecto Standard_B2as_v2: 2 núcleos
#              y 8 GB, sin la IA local). Con Standard_B4as_v2 (16 GB) se
#              enciende también la IA de Flyra, pero cuesta el doble.
#   APAGAR     hora (UTC, HHMM) a la que la máquina se apaga sola cada día
#              para ahorrar crédito (por defecto 2200 = 23:00 en España en
#              invierno). APAGAR=no la deja encendida siempre. Encenderla:
#              portal → máquina "eclipta" → Iniciar, o "az vm start -g
#              eclipta-rg -n eclipta" (o la app de Azure en el móvil).
#   AVISO_EUR  presupuesto mensual en euros (por defecto 15): te llega un
#              correo al gastar el 50 %, el 90 % y el 100 %.
#
# Se puede volver a ejecutar: lo que ya existe no se crea otra vez.
# Nunca enseña ninguna clave por pantalla.
# =============================================================================
set -euo pipefail

REGION="${REGION:-westeurope}"
SIZE="${SIZE:-Standard_B2as_v2}"
RG=eclipta-rg
VM=eclipta
USER_NAME=azureuser
REPO_URL=https://github.com/dp2005dario/NoMad-IQ.git
BRANCH="${BRANCH:-main}"
STATE="$HOME/.eclipta-azure.env"   # solo nombres (nada secreto)
APAGAR="${APAGAR:-2200}"
AVISO_EUR="${AVISO_EUR:-15}"

paso() { printf '\n== %s ==\n' "$1"; }

# --- 0. Comprobaciones -------------------------------------------------------
if ! command -v az >/dev/null; then
  echo "Este script es para la Cloud Shell de Azure (icono >_ del portal)." >&2
  exit 1
fi
if ! az account show >/dev/null 2>&1; then
  echo "No hay ninguna suscripción activa. Crea primero la de estudiante o" >&2
  echo "la de prueba gratis en el portal de Azure y vuelve a ejecutar esto." >&2
  exit 1
fi
SUB_NAME="$(az account show --query name -o tsv)"
EMAIL="$(az account show --query user.name -o tsv)"
echo "Suscripción: $SUB_NAME"
echo "Región: $REGION · Máquina: $SIZE"

# Lo que cuesta la máquina, con el precio oficial de Azure de hoy (su lista
# pública de precios). Más disco (~5 €/mes) e IP fija (~3 €/mes).
HOUR="$(curl -fsS --max-time 20 "https://prices.azure.com/api/retail/prices?currencyCode=EUR&\$filter=serviceName%20eq%20'Virtual%20Machines'%20and%20armRegionName%20eq%20'$REGION'%20and%20armSkuName%20eq%20'$SIZE'%20and%20priceType%20eq%20'Consumption'" 2>/dev/null \
  | python3 -c "import json,sys; it=[i for i in json.load(sys.stdin)['Items'] if 'Windows' not in i['productName'] and 'Spot' not in i['skuName'] and 'Low Priority' not in i['skuName']]; print(min(i['retailPrice'] for i in it) if it else '')" 2>/dev/null || true)"
if [ -n "$HOUR" ]; then
  python3 - "$HOUR" <<'PY'
import sys
h = float(sys.argv[1])
print(f"Precio de la máquina: {h:.3f} € por hora encendida.")
print(f"  Encendida siempre: ~{h * 730 + 8:.0f} €/mes (con disco e IP).")
print(f"  Encendida 8 h al día: ~{h * 8 * 30.4 + 8:.0f} €/mes (con disco e IP).")
PY
else
  echo "(No he podido leer el precio de hoy: mira https://azure.microsoft.com/pricing/calculator/)"
fi

# Los nombres con letras al azar se guardan para que, si se vuelve a
# ejecutar, use los mismos (no crea un segundo servidor).
if [ -f "$STATE" ]; then
  # shellcheck disable=SC1090
  . "$STATE"
fi
if [ -z "${SUFFIX:-}" ]; then
  SUFFIX="$(tr -dc 'a-z0-9' </dev/urandom | head -c 6)"
  echo "SUFFIX=$SUFFIX" > "$STATE"
fi
DNS_LABEL="eclipta-$SUFFIX"
STORAGE="eclipta$SUFFIX"            # solo minúsculas y números, máx. 24
CONTAINER=nomadiq-backups

# Con 16 GB o más cabe la IA local; con menos, se apaga.
case "$SIZE" in
  *B2as*|*B2s*|*B2ms*|*D2*) LLM=false ;;
  *) LLM=true ;;
esac

# Algunas cuentas nuevas aún no tienen "activados" estos servicios.
paso "1/6 Activando los servicios de Azure que hacen falta"
for ns in Microsoft.Compute Microsoft.Network Microsoft.Storage; do
  az provider register --namespace "$ns" --wait >/dev/null
done

paso "2/6 Grupo de recursos"
az group create -n "$RG" -l "$REGION" -o none

paso "3/6 Almacén para las copias de seguridad"
if ! az storage account show -n "$STORAGE" -g "$RG" >/dev/null 2>&1; then
  az storage account create -n "$STORAGE" -g "$RG" -l "$REGION" \
    --sku Standard_LRS --kind StorageV2 --https-only true \
    --min-tls-version TLS1_2 --allow-blob-public-access false -o none
fi
STORAGE_KEY="$(az storage account keys list -n "$STORAGE" -g "$RG" --query '[0].value' -o tsv)"
az storage container create -n "$CONTAINER" --account-name "$STORAGE" \
  --account-key "$STORAGE_KEY" --public-access off -o none

paso "4/6 La máquina (tarda unos minutos)"
if ! az vm show -g "$RG" -n "$VM" >/dev/null 2>&1; then
  # Lo que la máquina hace sola al arrancar por primera vez.
  INIT="$(mktemp)"
  cat > "$INIT" <<EOF
#cloud-config
runcmd:
  - [sudo, -u, $USER_NAME, git, clone, --branch, $BRANCH, $REPO_URL, /home/$USER_NAME/NoMad-IQ]
  - [env, SUDO_USER=$USER_NAME, bash, /home/$USER_NAME/NoMad-IQ/infrastructure/production/bootstrap.sh]
EOF
  if ! az vm create -g "$RG" -n "$VM" -l "$REGION" \
    --image Ubuntu2404 --size "$SIZE" \
    --admin-username "$USER_NAME" --generate-ssh-keys \
    --public-ip-sku Standard --public-ip-address-dns-name "$DNS_LABEL" \
    --os-disk-size-gb 64 --storage-sku StandardSSD_LRS \
    --custom-data "$INIT" -o none; then
    echo >&2
    echo "Azure no ha dejado crear la máquina. Suele ser porque en esa región" >&2
    echo "no hay ese tamaño para tu cuenta. Prueba otra región, por ejemplo:" >&2
    echo "  REGION=northeurope bash $0" >&2
    echo "  REGION=francecentral bash $0" >&2
    echo "  REGION=swedencentral bash $0" >&2
    echo "(antes borra el grupo a medio hacer: az group delete -n $RG --yes)" >&2
    rm -f "$INIT" "$STATE"
    exit 1
  fi
  rm -f "$INIT"
  # Puertas web: 80 (Let's Encrypt y redirigir) y 443 (https).
  az vm open-port -g "$RG" -n "$VM" --port 80 --priority 1010 -o none
  az vm open-port -g "$RG" -n "$VM" --port 443 --priority 1020 -o none
fi
# Apagado automático cada día (gratis; Azure avisa por correo 30 min antes).
if [ "$APAGAR" != no ]; then
  az vm auto-shutdown -g "$RG" -n "$VM" --time "$APAGAR" --email "$EMAIL" -o none \
    && echo "Se apagará sola cada día a las $APAGAR (UTC)." \
    || echo "AVISO: no se pudo poner el apagado automático (ponlo en el portal: máquina → Apagado automático)."
fi

# Alerta de gasto: correo al 50 %, 90 % y 100 % del presupuesto del mes.
SUB_ID="$(az account show --query id -o tsv)"
BUDGET_BODY="$(python3 - "$AVISO_EUR" "$EMAIL" <<'PY'
import datetime, json, sys
amount, email = float(sys.argv[1]), sys.argv[2]
start = datetime.date.today().replace(day=1).isoformat() + "T00:00:00Z"
note = lambda pct: {"enabled": True, "operator": "GreaterThanOrEqualTo", "threshold": pct,
                    "thresholdType": "Actual", "contactEmails": [email]}
print(json.dumps({"properties": {"category": "Cost", "amount": amount, "timeGrain": "Monthly",
      "timePeriod": {"startDate": start},
      "notifications": {"al50": note(50), "al90": note(90), "al100": note(100)}}}))
PY
)"
az rest --method put -o none \
  --url "https://management.azure.com/subscriptions/$SUB_ID/providers/Microsoft.Consumption/budgets/eclipta-aviso?api-version=2023-05-01" \
  --body "$BUDGET_BODY" \
  && echo "Alerta de gasto puesta: correo al llegar a 50 %, 90 % y 100 % de $AVISO_EUR €/mes." \
  || echo "AVISO: tu cuenta no deja crear alertas de gasto por aquí. Mira el crédito que te queda en https://www.microsoftazuresponsorships.com/balance"

FQDN="$(az network public-ip list -g "$RG" --query "[0].dnsSettings.fqdn" -o tsv)"
echo "Tu servidor: $FQDN"

paso "5/6 Esperando a que la máquina termine de prepararse (10-20 min)"
SSH=(ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15 "$USER_NAME@$FQDN")
for _ in $(seq 1 40); do
  "${SSH[@]}" true 2>/dev/null && break
  printf '.'
  sleep 15
done
# Se pregunta cada 30 s y se enseña un punto: así se ve que sigue vivo.
for _ in $(seq 1 80); do
  ST="$("${SSH[@]}" 'cloud-init status' 2>/dev/null || true)"
  case "$ST" in *done*|*error*) break ;; esac
  printf '.'
  sleep 30
done
echo
if ! printf '%s' "$ST" | grep -q 'done'; then
  echo "La preparación de la máquina ha fallado. Mira qué pasó con:" >&2
  echo "  ${SSH[*]} 'sudo tail -n 60 /var/log/cloud-init-output.log'" >&2
  exit 1
fi

paso "6/6 Rellenando config.env y secrets.env en la máquina"
# Un tema de ntfy con letras al azar (es como una contraseña: quien lo sepa
# puede leer los avisos del servidor).
NTFY_TOPIC="eclipta-avisos-$(tr -dc 'a-z0-9' </dev/urandom | head -c 12)"
# La clave del almacén viaja por la conexión SSH cifrada (por la "entrada"
# del programa), sin salir en pantalla ni quedar en ningún historial.
printf '%s\n' "$STORAGE_KEY" | "${SSH[@]}" \
  "bash ~/NoMad-IQ/infrastructure/azure/rellenar-env.sh '$FQDN' '$EMAIL' '$LLM' '$STORAGE' '$CONTAINER' '$NTFY_TOPIC'"
unset STORAGE_KEY

cat <<EOF

¡Listo! El servidor está creado y preparado.

  Dirección:      https://$FQDN
  Entrar en él:   ssh $USER_NAME@$FQDN
  Avisos (ntfy):  en la app ntfy, suscríbete al tema que sale con
                  ssh $USER_NAME@$FQDN 'grep NTFY_URL ~/NoMad-IQ/infrastructure/production/secrets.env'

Siguiente paso (docs/guia-azure.md, paso 4): entra con
  ssh $USER_NAME@$FQDN
y pon tus claves, una a una (te pide pegarlas y no se ven):
  cd ~/NoMad-IQ
  sudo infrastructure/production/poner-clave.sh TRAVELPAYOUTS_TOKEN
  sudo infrastructure/production/poner-clave.sh TRAVELPAYOUTS_MARKER
  sudo nohup infrastructure/production/deploy.sh > ~/deploy.log 2>&1 &
  tail -f ~/deploy.log      (Ctrl+C solo deja de mirar; el despliegue sigue)

OJO: la llave para entrar está en esta Cloud Shell (~/.ssh/id_rsa). Si la
Cloud Shell se borra, se pierde: descárgala (botón "Administrar archivos" →
Descargar → .ssh/id_rsa) y guárdala bien. Sin ella puedes entrar igual
desde el portal: máquina "eclipta" → Conectar → "Restablecer contraseña".
EOF
