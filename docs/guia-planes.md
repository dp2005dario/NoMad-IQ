# Guía para principiantes: Elegid planes

Cuando el grupo ya ha elegido destino (en **Grupo**, con los agentes), toca
la siguiente discusión: **¿qué hacemos allí?** "Elegid planes" lo resuelve
como una app de citas: cada uno, desde su móvil, desliza tarjetas de planes.

- A la **derecha** (o el botón ♥) = **sí**.
- A la **izquierda** (o el botón ✕) = **no**.
- Cuando un plan tiene el sí de **todos**, es un **¡Match!**

Se entra desde el viaje en grupo, cuando ya hay resultado: botón **Elegid
planes juntos**.

## De dónde salen los planes

1. **Mi plan**: cualquiera añade el suyo ("Fado en Alfama", "Esta noche ·
   21:30 · ≈ 25 €").
2. **Ideas de la ciudad**: pones el código del aeropuerto del destino (LIS) y
   la app trae las atracciones de la ficha de la ciudad (las mismas de "Sobre
   la ciudad", sacadas de Wikidata, con foto). Si alguien ya la añadió, no se
   repite.

## Privacidad

- Solo los del viaje ven los planes.
- De cada plan se ve **cuántos** han votado y cuántos sí, **nunca quién**.
  Los votos se guardan por asiento ("Viajero 2"), no por cuenta.
- Si alguien borra su cuenta, sus votos quedan anónimos y deja de contar
  para los match (si no, ningún plan podría tener ya el sí de todos).

## Cómo funciona por dentro (0 €)

Solo PostgreSQL (dos tablas: `ai.group_plans` y `ai.group_plan_votes`) con
topes para que nada crezca sin límite: **60 planes por viaje** y **15 por
persona**. Las fotos y enlaces solo pueden ser de Wikimedia/Wikipedia (así
nadie mete enlaces raros en el móvil de los demás).

```
GET    /v1/group-negotiations/{id}/plans               el tablero
POST   /v1/group-negotiations/{id}/plans               añadir (1-10 de golpe)
PUT    /v1/group-negotiations/{id}/plans/{plan}/vote   votar {"yes": true}
DELETE /v1/group-negotiations/{id}/plans/{plan}        quitar uno mío
```

Todas devuelven el tablero entero: la app pinta la siguiente tarjeta sin
otra llamada.

## Dónde está el código

| Archivo | Qué hace |
|---|---|
| `services/ai-orchestrator/src/ai_orchestrator/plans/` | Servidor: reglas, base de datos y API |
| `services/ai-orchestrator/src/ai_orchestrator/migrations/0012_group_plans.sql` | Las tablas |
| `mobile/lib/features/plans/plans_api.dart` | La app habla con el servidor |
| `mobile/lib/features/plans/plans_screen.dart` | Las tarjetas, el match y añadir planes |

## Probarlo en VS Code

Abre la carpeta del proyecto y, en la terminal (Terminal → New Terminal):

```bash
cd services/ai-orchestrator
.venv/bin/pytest tests/test_plans.py
cd ../../mobile
flutter test test/plans_test.dart
```
