"""Negociación de grupo con agentes de IA.

Un grupo de amigos quiere viajar junto y hay varias opciones (Lisboa, Roma,
Tokio...). Cada persona tiene su presupuesto y sus gustos. En vez de discutir
por WhatsApp durante días, cada uno tiene un "agente" de IA que le representa
y negocia con los de los demás hasta encontrar un plan que todos acepten.

Piezas (de dentro hacia fuera):
    domain.py   -> el vocabulario: opciones, preferencias, posturas, resultado.
    engine.py   -> las REGLAS (sin IA): presupuesto como línea roja, rondas
                   limitadas, concesiones que no se deshacen, árbitro justo.
    agents.py   -> los agentes: LLM (Ollama) con plan B por reglas.
    service.py  -> negocia UNA negociación de principio a fin.
    store.py    -> PostgreSQL: estados, preferencias privadas, outbox.
    events.py   -> los mensajes de Kafka (proto/nomadiq/ai/v1/negotiation.proto).
    consumer.py -> lee las órdenes de trabajo de Kafka.
    api.py      -> la API HTTP para la app.

La guía completa para principiantes está en docs/guia-negociacion-grupo.md.
"""
