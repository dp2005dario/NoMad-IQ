"""Audioguías contextuales por zona: el guion que escucha el viajero al llegar.

El recorrido completo, de principio a fin:

    móvil ──posición──► geo-engine ──(histéresis)──► geo.zone-entries.v1
                                                         │  solo zone_id + idioma
                                                         ▼
                              ai-orchestrator: ZoneEntryConsumer (este paquete)
                                   │ 1. ¿ya está en la caché de Redis? → listo
                                   │ 2. si no: UNA sola generación por zona+idioma
                                   │    (hechos verificados + LLM, o reglas)
                                   ▼
                     Redis: ai:audioguide:v1:<zone_id>:<idioma>
                                   ▲
              capa de notificaciones (futura) ──► GET /v1/audioguides/<zone_id>?lang=es

Las tres ideas clave (los tres riesgos del análisis de diseño):

1. **Nada bloquea al móvil.** La generación ocurre en segundo plano, leyendo de
   Kafka. La app nunca espera al LLM: o el guion ya está en la caché, o llegará.
2. **Un autobús de turistas = UNA generación.** El guion de una zona no depende
   de quién llega: es el mismo para todos los que hablan ese idioma. Se guarda
   en Redis por zona+idioma y solo el primero lo genera ("single flight").
3. **La IA no sabe quién eres ni dónde estás exactamente.** El evento que
   recibe solo trae la zona y el idioma. Sin user_id, sin coordenadas.

Ficheros:
    domain.py    tipos (entrada a zona, hechos, guion) e idiomas admitidos
    events.py    traduce el protobuf de Kafka a tipos de dominio
    facts.py     lee de PostgreSQL la zona y sus hechos verificados
    writer.py    redacta el guion: LLM anclado a hechos, o reglas (plan B)
    cache.py     caché en Redis + cerrojo distribuido + single flight local
    service.py   junta todo: "asegúrate de que existe el guion de esta zona"
    consumer.py  el bucle de Kafka (lotes, DLQ, reintentos)
"""
