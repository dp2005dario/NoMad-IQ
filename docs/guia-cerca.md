# Guía para principiantes: Cerca de ti

Estás en una ciudad que no conoces y necesitas **agua**, un **baño**, **wifi**
o **cargar el móvil**. O tienes **un par de horas libres** y no sabes qué
ver. "Cerca de ti" resuelve las dos cosas.

Se entra desde el **Mapa**, en la tira de atajos de arriba ("Cerca de ti").

## Las dos pestañas

### Gratis

Elige qué buscas (Agua potable, Baños, Wifi gratis, Cargar el móvil) y ves
los más cercanos con los metros, si cuesta dinero (si se sabe) y el horario.
El botón 🚶 abre Google Maps andando hasta allí.

### Tengo tiempo

Elige cuánto tiempo tienes (1 a 4 horas) y la app arma un **paseo** que sale
de donde estás, pasa por sitios conocidos (monumentos, miradores, museos) y
**vuelve a tiempo**. "Abrir el paseo en el mapa" lo lleva a Google Maps con
todas las paradas.

Cómo se hace el paseo (en el móvil, al instante): desde donde estás vas al
sitio más cercano; desde allí, al siguiente más cercano... y solo se añade
una parada si te da tiempo a llegar, quedarte 15 minutos **y volver**. Se
cuentan 75 metros por minuto y un 30 % más de camino porque las calles no van
en línea recta.

## Lo que no está (y por qué)

La maqueta tenía "Ofertas ya" (happy hours de bares). No existe una fuente
gratuita y fiable de ofertas en tiempo real, y una oferta inventada es peor
que ninguna. Queda para cuando haya acuerdos con locales.

## De dónde salen los datos (0 €)

De **OpenStreetMap**, a través de nuestro servidor:

```
GET /v1/nearby?lat=40.42&lon=-3.70
```

- La app manda solo la **casilla** de ~1 km donde estás (dos decimales):
  el servidor nunca sabe en qué calle estás. Las distancias se calculan en
  el móvil.
- El servidor guarda cada casilla **una semana** en Redis. Mil turistas en
  la Puerta del Sol = **una** pregunta a OpenStreetMap a la semana.
- Cajeros, guía del aeropuerto y "Cerca de ti" comparten **un solo límite de
  ritmo** hacia OpenStreetMap (1 pregunta por segundo): así respetamos su
  norma de uso justo aunque haya muchos usuarios.
- Los "sitios que ver" son solo los que tienen ficha en Wikidata (los
  conocidos), para que el paseo no te lleve a una estatua cualquiera.

## Si Overpass falla (espejos y copia vieja)

Los datos vienen de Overpass, un servicio gratis de OpenStreetMap que a veces
se satura ("502", "ReadTimeout"). Para que la app no se quede sin respuesta:

1. **Espejos.** Si el servidor principal falla, se prueba el siguiente de la
   lista, en orden. Los que fallan rápido se repiten una vez tras una pausa
   corta; los que tardan (timeout) no, para no hacer esperar a la persona.
   Se configuran con dos variables (todas las direcciones deben ser `https://`):
   `OVERPASS_URL` (el principal, por defecto `overpass-api.de`) y
   `OVERPASS_FALLBACK_URLS` (respaldos separados por comas, por defecto
   `overpass.private.coffee`; vacío = sin respaldo). Ambos están en la lista
   de servidores públicos de la wiki de OpenStreetMap. Antes de añadir otro
   espejo, comprueba en esa wiki que existe y que acepta tu volumen de uso.
2. **Copia vieja.** Cada casilla se guarda una semana como "fresca"
   (`NEARBY_TTL_SECONDS`) y además se conserva `OVERPASS_STALE_SECONDS`
   más (30 días por defecto). Si la casilla ha caducado y Overpass falla en
   todos los espejos, se enseña la copia vieja en vez de dar error. Solo si
   nunca se guardó esa casilla, la app recibe el 503 de siempre.

Lo mismo vale para el modo coche (`guia-coche.md`) y la guía del aeropuerto
(`guia-aeropuerto.md`); cajeros y "dormir barato" usan los espejos pero no la
copia vieja. El código está en `atms/overpass.py` (`post_query`) y
`stale_cache.py`.

## Dónde está el código

| Archivo | Qué hace |
|---|---|
| `services/ai-orchestrator/src/ai_orchestrator/nearby/` | Servidor: consulta, caché y `/v1/nearby` |
| `mobile/lib/features/nearby/nearby_api.dart` | La app pide la casilla y lee la respuesta |
| `mobile/lib/features/nearby/walk.dart` | El paseo de "tengo tiempo" |
| `mobile/lib/features/nearby/nearby_screen.dart` | La pantalla |
| `infrastructure/edge/dynamic.yml` | La puerta de entrada deja pasar solo `GET /v1/nearby` |

## Probarlo en VS Code

```bash
cd services/ai-orchestrator
.venv/bin/pytest tests/test_nearby.py
cd ../../mobile
flutter test test/nearby_test.dart
```
