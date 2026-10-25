# El worker de audio de producción = la imagen "audio-worker" del
# ai-orchestrator + las voces de Piper copiadas dentro.
#
# ¿Por qué dentro de la imagen? Kubernetes, con las normas de seguridad
# "restricted", no deja montar carpetas de la máquina. Así las voces viajan
# con la imagen (solo lectura) y no hace falta ningún permiso especial.
# deploy.sh descarga las voces (comprobando su SHA-256) antes de construirla.
FROM nomadiq/ai-orchestrator-audio-base:prod
COPY --chown=10001:10001 infrastructure/tts/voices /voices
