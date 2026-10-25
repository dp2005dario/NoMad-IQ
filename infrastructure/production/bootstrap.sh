#!/usr/bin/env bash
# =============================================================================
# Prepara un servidor NUEVO (Ubuntu 24.04, Oracle Always Free Ampere A1) para
# NomadIQ. Se ejecuta UNA vez, dentro del servidor, con:
#
#   sudo bash infrastructure/production/bootstrap.sh
#
# Qué hace, en orden (cada paso explicado abajo):
#   1. Actualiza el sistema y activa las actualizaciones de seguridad solas.
#   2. Abre en el cortafuegos SOLO los puertos 22 (SSH), 80 y 443 (web).
#   3. Instala Docker (para construir las imágenes en el propio servidor).
#   4. Instala k3s: un Kubernetes completo pero ligero, de un solo binario.
#   5. Instala cert-manager: el "notario" que fabrica y renueva los
#      certificados internos (mTLS) solo.
#
# Se puede ejecutar dos veces sin romper nada (cada paso comprueba si ya está).
# =============================================================================
set -euo pipefail

# Versiones FIJAS: así el servidor de mañana es igual que el de hoy. Para
# actualizar, cambia el número aquí (mira antes las notas de la versión).
K3S_VERSION="v1.36.5+k3s1"
CERT_MANAGER_VERSION="v1.21.3"

if [ "$(id -u)" -ne 0 ]; then
  echo "Ejecuta con sudo: sudo bash $0" >&2
  exit 1
fi

echo "== 1/5 Actualizando el sistema =="
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get -y upgrade
apt-get install -y --no-install-recommends ca-certificates curl gnupg git \
  unattended-upgrades iptables-persistent openssl
# Parches de seguridad automáticos cada día (sin reiniciar por sorpresa).
dpkg-reconfigure -f noninteractive unattended-upgrades

echo "== 2/5 Cortafuegos: solo 22, 80 y 443 =="
# Las imágenes de Ubuntu de Oracle traen reglas iptables que lo bloquean todo
# salvo SSH. Añadimos 80 y 443 ANTES de la regla que rechaza el resto.
# (Además hay que abrirlos en la "Security List" de la red en la consola de
# Oracle: lo explica docs/guia-produccion.md.)
allow() {
  # allow <regla...>: la añade (si no está) justo antes del primer REJECT.
  if ! iptables -C INPUT "$@" -j ACCEPT 2>/dev/null; then
    pos="$(iptables -L INPUT --line-numbers -n | awk '$2 == "REJECT" {print $1; exit}')"
    iptables -I INPUT "${pos:-1}" "$@" -j ACCEPT
  fi
}
allow -p tcp --dport 80 -m state --state NEW
allow -p tcp --dport 443 -m state --state NEW
# Los contenedores (10.42.x) y servicios internos (10.43.x) de k3s tienen que
# poder hablar con la propia máquina (API de Kubernetes, métricas). Son
# direcciones privadas: desde Internet no se puede llegar con ellas.
allow -s 10.42.0.0/16
allow -s 10.43.0.0/16
# La imagen de Oracle rechaza también el tráfico "reenviado", que es justo
# el que usan los contenedores entre ellos: quitamos esa regla.
iptables -D FORWARD -j REJECT --reject-with icmp-host-prohibited 2>/dev/null || true
netfilter-persistent save

echo "== 3/5 Docker =="
if ! command -v docker >/dev/null; then
  # Repositorio oficial de Docker (firmado con su llave).
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  # shellcheck disable=SC1091
  . /etc/os-release
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${VERSION_CODENAME} stable" \
    > /etc/apt/sources.list.d/docker.list
  apt-get update
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin
fi
# El usuario normal (ubuntu) puede usar docker sin sudo.
usermod -aG docker "${SUDO_USER:-ubuntu}" || true

echo "== 4/5 k3s (Kubernetes ligero) =="
if ! command -v k3s >/dev/null; then
  # --disable traefik: traemos NUESTRA puerta (edge) con las reglas del proyecto.
  # --secrets-encryption: los Secrets se guardan cifrados (AES) en el disco.
  # --write-kubeconfig-mode 600: la llave del clúster solo la lee root.
  curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION="$K3S_VERSION" sh -s - \
    --disable traefik \
    --secrets-encryption \
    --write-kubeconfig-mode 600
fi
# Esperar a que el nodo esté listo.
until k3s kubectl get nodes 2>/dev/null | grep -q " Ready"; do sleep 3; done

echo "== 5/5 cert-manager =="
k3s kubectl apply -f "https://github.com/cert-manager/cert-manager/releases/download/${CERT_MANAGER_VERSION}/cert-manager.yaml"
k3s kubectl -n cert-manager rollout status deploy/cert-manager-webhook --timeout=300s

echo
echo "Listo. Siguiente paso (como usuario normal, en una sesión NUEVA de SSH"
echo "para que se aplique el grupo docker):"
echo "  cd ~/NoMad-IQ/infrastructure/production"
echo "  cp secrets.env.example secrets.env && chmod 600 secrets.env && nano secrets.env"
echo "  cp config.env.example config.env && nano config.env"
echo "  sudo ./deploy.sh"
