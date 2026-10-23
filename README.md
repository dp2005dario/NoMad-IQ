# 🚀 NomadIQ — Next-Gen Autonomous Travel Ecosystem

> NomadIQ es un asistente de viajes inteligente y autónomo que elimina la fricción de la planificación turística. A diferencia de las aplicaciones tradicionales, combina procesamiento de alta concurrencia, computación geoespacial, orquestación de agentes de IA y seguridad de grado bancario, monetizándose de forma pasiva a través de un motor de afiliación automatizado.

---

## 🌟 Visión General del Proyecto
En la industria turística actual, los usuarios sufren de fatiga de planificación: comparar cientos de webs, coordinar grupos con intereses dispares, lidiar con imprevistos climáticos o logísticos y preocuparse por la seguridad de sus documentos. **NomadIQ** nace para resolver este problema mediante un ecosistema hiper-conectado impulsado por inteligencia artificial, diseñado desde cero para escalar a millones de usuarios.

---

## ⚙️ Arquitectura Técnica y Stack Políglota
Para garantizar una escalabilidad masiva sin degradación del rendimiento, el sistema adopta una arquitectura de microservicios orientada a eventos:

* **Go (Golang):** Ingesta masiva y alta concurrencia para el rastreo y consulta asíncrona de APIs de aerolíneas mediante *Goroutines*.
* **Rust:** Núcleo geoespacial de alto rendimiento para cálculos críticos de mapas, geofencing y optimización de rutas urbanas.
* **Java Spring Boot:** Pasarela de identidad, seguridad empresarial y autenticación robusta mediante OAuth2 y JWT.
* **Python (FastAPI + Ollama / PyTorch):** Cerebro de inteligencia artificial, orquestación de agentes autónomos, procesamiento de lenguaje natural (NLP) y visión computacional.
* **Apache Kafka & gRPC:** Sistema nervioso distribuido para streaming de eventos asíncronos y comunicación interna de baja latencia.
* **Bases de Datos & Caché:** PostgreSQL con PostGIS para datos relacionales y geoespaciales, Redis Cluster para caché en memoria y Qdrant como base de datos vectorial.

---

## 🧩 Funcionalidades Core y Capacidades
* **Cazadora "Sniper" de Tarifas:** Monitoreo en background de variaciones de precios y errores de emisión en aerolíneas.
* **Negociación Multi-Agente para Grupos:** Agentes de IA independientes que negocian y estructuran itinerarios compartidos sin discusiones.
* **Re-planificador Dinámico por Clima:** Adaptación automática de la agenda de actividades en milisegundos ante imprevistos ambientales.
* **Bóveda Cifrada de Documentos:** Almacenamiento seguro de pasaportes y credenciales protegido por autenticación biométrica.
* **Herramientas Avanzadas:** Audioguías contextuales en formato podcast, divisor de gastos por visión artificial, traductor instantáneo de menús con alérgenos y optimización de equipaje.

---

## 🛡️ Seguridad de Grado Bancario (Zero Trust Architecture)
* **Cifrado Robusto:** Datos sensibles protegidos mediante **AES-256** en reposo y comunicaciones bajo **TLS 1.3**.
* **mTLS (Mutual TLS):** Autenticación mutua obligatoria en la red interna entre microservicios.
* **Aislamiento Estricto:** Control de acceso por roles (*RBAC*) y principios de seguridad en profundidad.

---

## 💰 Modelo de Negocio y Monetización Pasiva
* **Afiliación por Conversión (CPS):** Integración mediante *Deep Linking* con plataformas globales de hoteles (Booking), vuelos (Travelpayouts), eSIMs, seguros de viaje, transporte y atracciones.
* **Google Play Billing:** Gestión automatizada de suscripciones recurrentes (**NomadIQ Pro**) y micropagos, con ingresos limpios transferidos directamente a cuentas bancarias (como BBVA) por umbrales mínimos.

---

## 🗂️ Estructura del Repositorio

```
proto/                    Contratos gRPC y eventos Kafka (Protocol Buffers, fuente única de verdad)
gen/go/                   Código Go generado desde proto/ (no editar a mano)
infrastructure/           docker-compose local: Kafka (KRaft), PostgreSQL+PostGIS, Redis, Qdrant
services/flight-ingestor/ Microservicio Go: vigila rutas y publica precios en Kafka
services/price-consumer/  Microservicio Go: guarda el historial de precios, detecta chollos y publica alertas
services/auth-gateway/    Microservicio Java Spring Boot: registro, login, JWT ES256 + JWKS, refresh tokens y revocación
services/ai-orchestrator/ Microservicio Python FastAPI + Ollama: convierte alertas en recomendaciones fundamentadas con IA local
services/geo-engine/      Microservicio Rust: aeropuertos cercanos, rutas óptimas y geofencing en streaming (índices R-tree en memoria)
services/notifier/        Microservicio Go: notificaciones push seudónimas, anti-spam en Redis, cifrado HPKE y entrega a FCM a ritmo controlado
mobile/                   App Flutter (Android/iOS): Flyra, tema de las maquetas, todos los idiomas (i18n desde el día 1, RTL)
docs/                     Documentación, incluida la guía de aprendizaje
.github/workflows/        Integración continua
```

**Primeros pasos:** `cp infrastructure/.env.example infrastructure/.env`, rellena los secretos, ejecuta `make keys` (crea las claves de las notificaciones) y `make up`. ¿Empiezas de cero? Lee primero [`docs/guia-principiantes.md`](docs/guia-principiantes.md) (incluye cómo usar el proyecto en VS Code), después [`docs/guia-aprendizaje.md`](docs/guia-aprendizaje.md) para el detalle técnico, [`docs/guia-price-consumer.md`](docs/guia-price-consumer.md) para el detector de chollos, [`docs/guia-auth-gateway.md`](docs/guia-auth-gateway.md) para la pasarela de identidad, [`docs/guia-ai-orchestrator.md`](docs/guia-ai-orchestrator.md) para el cerebro de IA, [`docs/guia-geo-engine.md`](docs/guia-geo-engine.md) para el motor geoespacial en Rust, [`docs/guia-audioguias.md`](docs/guia-audioguias.md) para la histéresis del geofencing y las audioguías por zona (texto y voz con Piper), [`docs/guia-notificaciones.md`](docs/guia-notificaciones.md) para las notificaciones push sin spam y sin rastro de ubicación, [`docs/guia-negociacion-grupo.md`](docs/guia-negociacion-grupo.md) para la negociación de grupo con agentes de IA y [`docs/guia-app-movil.md`](docs/guia-app-movil.md) para la app Flutter.
