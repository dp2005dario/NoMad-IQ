# Guía para principiantes: Radar local

El Radar responde a tres preguntas de "ahora mismo, aquí":

1. **¿Va a llover?** Las próximas horas, hora a hora.
2. **¿Qué timos hay en esta ciudad?** Los que han avisado otros viajeros.
3. **¿Me están cobrando de más?** Comparas lo que te piden con lo que
   pagaron otros viajeros en esa ciudad.

Se entra desde el **Mapa**, en los atajos ("Radar").

> Analogía: es como el tablón de anuncios de un albergue, donde los
> mochileros escriben "cuidado con los taxis de la estación" o "el café
> aquí vale 1 €". Solo que ordenado, anónimo y con un mínimo de gente.

## Regla: nada inventado

- **La lluvia** viene de **MET Norway** (el servicio meteorológico de
  Noruega). Es gratis, cubre todo el mundo y permite uso comercial si se
  cita (licencia CC BY 4.0). Por eso abajo siempre pone "Data from MET
  Norway".
- **Los timos** solo se enseñan si **3 o más personas distintas** los
  avisaron en los últimos 90 días. Con 1 o 2 no sale nada: podría ser un
  error o alguien con mala idea.
- **Los precios** solo se enseñan con **5 o más personas distintas** en
  el último año. Se enseña el "rango normal" (del percentil 25 al 75: lo
  que pagó la mitad del medio, sin los extremos raros).
- Si aún no hay bastantes avisos, la pantalla lo dice tal cual ("aún no
  hay suficientes"). No se rellena con nada.

## Cómo se usa

1. La app mira tu GPS y busca el aeropuerto más cercano (a menos de
   80 km): esa es "tu ciudad" para el radar.
2. Arriba ves la lluvia; si va a llover, un botón busca cafés cerca en
   Google Maps.
3. En "Timos" ves los avisados. Si te pasa algo, tocas su etiqueta para
   avisar (otra vez para retirarlo).
4. En "¿Este precio es normal?" eliges qué es (café, cerveza, agua,
   comida sencilla, taxi corto), escribes lo que te piden y ves si es
   normal, algo caro o mucho más de lo que pagaron otros. Si lo pagas,
   "Apuntar lo que pagué" ayuda al siguiente.

## Privacidad

- Al servidor de la lluvia solo va una **celda** de unos 5 km, nunca tu
  punto exacto.
- Los avisos van por **ciudad** (código del aeropuerto), no por calle.
- **Nadie ve quién avisó**: el servidor solo devuelve cuántos.
- Si borras tu cuenta, se borran también tus avisos y precios.
- Ver y avisar timos o precios necesita cuenta (para que cada persona
  cuente una sola vez). La lluvia la ve cualquiera.

## Para miles de usuarios (0 €)

- La lluvia se guarda 15 minutos por celda: mil personas en Lisboa = una
  sola pregunta a MET Norway.
- Cada cuenta puede enviar como mucho 30 avisos al día.
- Los avisos viejos se borran solos (timos a los 90 días, precios al año).

## Dónde está el código

| Archivo | Qué hace |
|---|---|
| `services/ai-orchestrator/src/ai_orchestrator/radar/` | Servidor: lluvia, timos, precios |
| `services/ai-orchestrator/src/ai_orchestrator/migrations/0015_radar.sql` | Las tablas de avisos |
| `mobile/lib/features/radar/radar_api.dart` | La app habla con el servidor |
| `mobile/lib/features/radar/radar_screen.dart` | La pantalla |

## Probarlo en VS Code

Abre la carpeta `NoMad-IQ` (Archivo → Abrir carpeta) y en la terminal
(Ver → Terminal):

```bash
cd services/ai-orchestrator
.venv/bin/pytest tests/test_radar.py
cd ../../mobile
flutter test test/radar_test.dart
```
