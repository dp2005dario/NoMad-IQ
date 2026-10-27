#!/usr/bin/env python3
"""Genera k8s/20-services.yaml (los microservicios) a partir de una tabla.

¿Por qué un generador? Los 7 servicios se parecen mucho (mismos certificados,
mismas reglas de seguridad, mismas variables de PostgreSQL/Redis/Kafka). Con
una tabla se ve de un vistazo qué tiene cada uno y no hay copias que se
desincronicen. Si cambias algo aquí, ejecuta:  python3 gen_services.py
"""

from __future__ import annotations

from pathlib import Path


def secret(key: str) -> dict:
    return {"secretKeyRef": {"name": "nomadiq-secrets", "key": key}}


def config(key: str) -> dict:
    return {"configMapKeyRef": {"name": "nomadiq-config", "key": key}}


# Trozos de configuración que comparten varios servicios.
PG = {
    "PGHOST": "postgres",
    "PGUSER": secret("POSTGRES_USER"),
    "PGPASSWORD": secret("POSTGRES_PASSWORD"),
    "PGDATABASE": secret("POSTGRES_DB"),
    # verify-full: cifrado Y comprobando que el servidor es nuestro PostgreSQL.
    "PGSSLMODE": "verify-full",
    "PGSSLROOTCERT": "/certs/ca.crt",
}
REDIS = {
    "REDIS_HOST": "redis",
    "REDIS_PASSWORD": secret("REDIS_PASSWORD"),
    "REDIS_TLS": "true",
    "REDIS_TLS_CA_FILE": "/certs/ca.crt",
}
KAFKA = {"KAFKA_BROKERS": "kafka:9092", "KAFKA_TLS_CA_FILE": "/certs/ca.crt"}
SERVER_MTLS = {
    "TLS_CERT_FILE": "/certs/tls.crt",
    "TLS_KEY_FILE": "/certs/tls.key",
    "TLS_CLIENT_CA_FILE": "/certs/ca.crt",
}
OLLAMA = {
    "OLLAMA_URL": "https://ollama:11434",
    "OLLAMA_TLS_CA_FILE": "/certs/ca.crt",
    "OLLAMA_TLS_CERT_FILE": "/certs/tls.crt",
    "OLLAMA_TLS_KEY_FILE": "/certs/tls.key",
    "OLLAMA_MODEL": config("OLLAMA_MODEL"),
}
COMMON = {"LOG_LEVEL": "info"}

DISTROLESS = 65532  # usuario "nonroot" de las imágenes distroless
PYTHON = 10001  # usuario de las imágenes de Python (ver su Dockerfile)

SERVICES = [
    {
        "name": "flight-ingestor",
        "uid": DISTROLESS,
        "ports": {"grpc": 50051, "health": 8081},
        "probe": ("health", "/healthz", "/readyz"),
        "mem": ("128Mi", "256Mi"),
        "env": {
            **KAFKA,
            "GRPC_TLS_CERT_FILE": "/certs/tls.crt",
            "GRPC_TLS_KEY_FILE": "/certs/tls.key",
            "GRPC_TLS_CLIENT_CA_FILE": "/certs/ca.crt",
            "FARE_PROVIDER": "travelpayouts",
            "TRAVELPAYOUTS_TOKEN": secret("TRAVELPAYOUTS_TOKEN"),
            "TRAVELPAYOUTS_MARKER": secret("TRAVELPAYOUTS_MARKER"),
            "TRAVELPAYOUTS_CURRENCY": "EUR",
            "POLL_INTERVAL": "15m",
        },
    },
    {
        "name": "price-consumer",
        "uid": DISTROLESS,
        "ports": {"api": 8092, "health": 8082},
        "probe": ("health", "/healthz", "/readyz"),
        "mem": ("128Mi", "384Mi"),
        "env": {
            **KAFKA,
            **PG,
            **SERVER_MTLS,
            "INGESTOR_GRPC_ADDR": "flight-ingestor:50051",
            "INGESTOR_TLS_CA_FILE": "/certs/ca.crt",
            "INGESTOR_TLS_CERT_FILE": "/certs/tls.crt",
            "INGESTOR_TLS_KEY_FILE": "/certs/tls.key",
            "POPULAR_ROUTES": config("POPULAR_ROUTES"),
        },
    },
    {
        "name": "auth-gateway",
        "uid": DISTROLESS,
        "ports": {"api": 8083, "health": 8084},
        "probe": ("health", "/livez", "/readyz"),
        "mem": ("384Mi", "768Mi"),
        "tmp": True,
        "extra_volumes": [("jwt", "nomadiq-jwt", "/jwt")],
        "env": {
            **PG,
            **{k: v for k, v in REDIS.items() if k != "REDIS_TLS_CA_FILE"},
            **SERVER_MTLS,
            "JWT_ACTIVE_KEY_FILE": "/jwt/jwt-active.pem",
            "FORWARD_HEADERS_STRATEGY": "native",
            # Login con Google: opcional (si falta, el servidor responde 503 a ese botón).
            "GOOGLE_CLIENT_ID": {"configMapKeyRef": {"name": "nomadiq-config", "key": "GOOGLE_CLIENT_ID", "optional": True}},
            "JAVA_TRUSTSTORE_PASSWORD": secret("JAVA_TRUSTSTORE_PASSWORD"),
            # Java comprueba a Redis con la CA interna (truststore.p12 lo crea
            # cert-manager). La memoria de Java, con techo.
            "JAVA_TOOL_OPTIONS": "-XX:MaxRAMPercentage=70 "
            "-Djavax.net.ssl.trustStore=/certs/truststore.p12 -Djavax.net.ssl.trustStoreType=PKCS12 "
            "-Djavax.net.ssl.trustStorePassword=$(JAVA_TRUSTSTORE_PASSWORD)",
        },
    },
    {
        "name": "ai-orchestrator",
        "uid": PYTHON,
        "ports": {"api": 8085, "health": 8086},
        "probe": ("health", "/healthz", "/readyz"),
        "mem": ("512Mi", "1Gi"),
        "tmp": True,
        "audio": "ro",
        "env": {
            **KAFKA,
            **PG,
            **REDIS,
            **SERVER_MTLS,
            **OLLAMA,
            "LLM_ENABLED": "true",
            # El servidor gratis no tiene tarjeta gráfica: la IA piensa más
            # despacio que en un PC. Más margen de espera (la puerta "edge"
            # aguanta hasta 150 s) para que las respuestas no se corten.
            "OLLAMA_TIMEOUT_SECONDS": "120",
            "FLYRA_TIMEOUT_SECONDS": "120",
            "MENU_TIMEOUT_SECONDS": "120",
            "TRIP_ADAPT_TIMEOUT_SECONDS": "120",
            "AUDIO_DIR": "/var/lib/nomadiq/audio",
            "AUDIOGUIDE_DEFAULT_LANGUAGE": "en",
            "NOTIFY_PSEUDONYM_KEY": secret("NOTIFY_PSEUDONYM_KEY"),
            "MAPILLARY_TOKEN": secret("MAPILLARY_TOKEN"),
            "TICKETMASTER_API_KEY": secret("TICKETMASTER_API_KEY"),
            "EXPOSE_API_DOCS": "false",
        },
    },
    {
        "name": "audio-worker",
        # La imagen del worker + las voces de Piper dentro (audio-worker.Dockerfile).
        "image": "audio-worker",
        "uid": PYTHON,
        "ports": {"health": 8086},
        "probe": ("health", "/healthz", "/readyz"),
        "mem": ("512Mi", "1Gi"),
        "cpu": "1",
        "tmp": True,
        "audio": "rw",
        "env": {
            **KAFKA,
            **PG,
            **REDIS,
            **SERVER_MTLS,
            **OLLAMA,
            "LLM_ENABLED": "true",
            "AUDIOGUIDE_DEFAULT_LANGUAGE": "en",
            "AUDIO_POLL_SECONDS": "30",
        },
    },
    {
        "name": "geo-engine",
        "uid": DISTROLESS,
        "ports": {"grpc": 50052, "health": 8087, "api": 8090},
        "probe": ("health", "/healthz", "/readyz"),
        "mem": ("256Mi", "512Mi"),
        "env": {
            **KAFKA,
            **PG,
            **REDIS,
            "GRPC_TLS_CERT_FILE": "/certs/tls.crt",
            "GRPC_TLS_KEY_FILE": "/certs/tls.key",
            "GRPC_TLS_CLIENT_CA_FILE": "/certs/ca.crt",
            # Solo la puerta de entrada puede usar la API HTTP.
            "API_ALLOWED_CLIENTS": "edge",
            "SEED_DEMO_ZONES": "false",
            "NOTIFY_PSEUDONYM_KEY": secret("NOTIFY_PSEUDONYM_KEY"),
        },
    },
    {
        "name": "notifier",
        "uid": DISTROLESS,
        "ports": {"api": 8089, "health": 8090},
        "probe": ("health", "/healthz", "/readyz"),
        "mem": ("128Mi", "256Mi"),
        "extra_volumes": [("fcm", "nomadiq-fcm", "/fcm")],
        "env": {
            **KAFKA,
            **PG,
            **REDIS,
            **SERVER_MTLS,
            "NOTIFY_PSEUDONYM_KEY": secret("NOTIFY_PSEUDONYM_KEY"),
            "NOTIFY_TOKEN_KEY": secret("NOTIFY_TOKEN_KEY"),
            "FCM_PROJECT_ID": secret("FCM_PROJECT_ID"),
            "FCM_CREDENTIALS_FILE": "/fcm/fcm.json",
        },
    },
]


def env_yaml(env: dict) -> list[str]:
    lines = []
    for k, v in {**env, **COMMON}.items():
        if isinstance(v, dict):
            (kind, ref), = v.items()
            # "optional": si la clave no existe en el ConfigMap, el pod arranca igual.
            opt = ", optional: true" if ref.get("optional") else ""
            lines.append(
                f"            - {{name: {k}, valueFrom: {{{kind}: {{name: {ref['name']}, key: {ref['key']}{opt}}}}}}}"
            )
        else:
            lines.append(f'            - {{name: {k}, value: "{v}"}}')
    return lines


def render(s: dict) -> str:
    name = s["name"]
    image = s.get("image", name)
    ports = s["ports"]
    port_name, live, ready = s["probe"]
    req, lim = s["mem"]
    mounts = [f"            - {{name: certs, mountPath: /certs, readOnly: true}}"]
    volumes = [f"        - {{name: certs, secret: {{secretName: tls-{name}}}}}"]
    if s.get("tmp"):
        mounts.append("            - {name: tmp, mountPath: /tmp}")
        volumes.append("        - {name: tmp, emptyDir: {}}")
    for vol, sec, path in s.get("extra_volumes", []):
        mounts.append(f"            - {{name: {vol}, mountPath: {path}, readOnly: true}}")
        volumes.append(f"        - {{name: {vol}, secret: {{secretName: {sec}}}}}")
    if "audio" in s:
        ro = "true" if s["audio"] == "ro" else "false"
        mounts.append(f"            - {{name: audio, mountPath: /var/lib/nomadiq/audio, readOnly: {ro}}}")
        volumes.append("        - {name: audio, persistentVolumeClaim: {claimName: audio-data}}")
    svc_ports = "\n".join(f"    - {{name: {n}, port: {p}}}" for n, p in ports.items())
    ctr_ports = "\n".join(f"            - {{name: {n}, containerPort: {p}}}" for n, p in ports.items())
    return f"""---
apiVersion: v1
kind: Service
metadata:
  name: {name}
  namespace: nomadiq
spec:
  selector: {{app: {name}}}
  ports:
{svc_ports}
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {name}
  namespace: nomadiq
spec:
  replicas: 1
  revisionHistoryLimit: 3
  selector:
    matchLabels: {{app: {name}}}
  template:
    metadata:
      labels: {{app: {name}, kafka-client: "true"}}
      annotations:
        prometheus.io/scrape: "false"
    spec:
      automountServiceAccountToken: false
      securityContext:
        runAsNonRoot: true
        runAsUser: {s['uid']}
        runAsGroup: {s['uid']}
        fsGroup: {s['uid']}
        seccompProfile: {{type: RuntimeDefault}}
      containers:
        - name: {name}
          image: nomadiq/{image}:prod
          # La imagen se construye en la propia máquina (deploy.sh): gratis,
          # sin registro de imágenes de pago.
          imagePullPolicy: Never
          env:
{chr(10).join(env_yaml(s['env']))}
          ports:
{ctr_ports}
          readinessProbe:
            httpGet: {{path: {ready}, port: {port_name}}}
            periodSeconds: 10
            failureThreshold: 3
          livenessProbe:
            httpGet: {{path: {live}, port: {port_name}}}
            initialDelaySeconds: 60
            periodSeconds: 20
            failureThreshold: 3
          resources:
            requests: {{cpu: 50m, memory: {req}}}
            limits: {{cpu: "{s.get('cpu', '1')}", memory: {lim}}}
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities: {{drop: [ALL]}}
          volumeMounts:
{chr(10).join(mounts)}
      volumes:
{chr(10).join(volumes)}"""


HEADER = """# GENERADO por gen_services.py: no lo edites a mano (cambia la tabla de allí).
#
# Los 7 microservicios de NomadIQ. Todos:
#   - hablan entre sí con mTLS (cada uno con su certificado de 01-pki.yaml);
#   - van a PostgreSQL con verify-full, a Redis y Kafka con TLS;
#   - corren sin root, con el disco del contenedor en solo lectura y un techo
#     de memoria y CPU (si alguno se pasa, Kubernetes lo reinicia: no hay
#     "más máquinas" que pagar).
---
# Las audioguías en .opus: las graba el audio-worker y las lee la API.
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: audio-data
  namespace: nomadiq
spec:
  accessModes: [ReadWriteOnce]
  resources:
    requests: {storage: 10Gi}
"""

if __name__ == "__main__":
    out = Path(__file__).with_name("k8s") / "20-services.yaml"
    out.write_text(HEADER + "\n".join(render(s) for s in SERVICES) + "\n", encoding="utf-8")
    print(f"escrito {out}")
