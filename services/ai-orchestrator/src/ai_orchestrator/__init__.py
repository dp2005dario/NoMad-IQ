"""ai-orchestrator: el "cerebro" de IA de NomadIQ.

Este paquete escucha las alertas de precio que publica el price-consumer en
Kafka y, con ayuda de un modelo de lenguaje local (Ollama), las convierte en
una recomendación corta y comprensible ("Compra ya: es el precio más bajo del
último mes").

Regla de oro del servicio: el modelo de IA NUNCA inventa datos de negocio.
Los precios, fechas y rutas salen siempre de nuestras bases de datos; la IA
solo razona sobre ellos y redacta. Ver grounding.py para saber cómo se impone.
"""
