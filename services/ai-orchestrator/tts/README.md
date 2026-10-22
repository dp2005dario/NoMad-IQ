# Piper (motor de voz) para el worker de audio

`requirements.txt` fija Piper y sus dependencias con su versión exacta **y su
huella SHA-256**. La imagen `audio-worker` (ver `../Dockerfile`) lo instala en
`/opt/piper`, en un entorno de Python **aparte** del de la aplicación.

¿Por qué aparte?

- **Licencia**: Piper es GPL-3.0. Nuestro código no lo importa: lo ejecuta como
  un programa independiente (texto por la entrada estándar, sonido por la
  salida) desde `src/ai_orchestrator/audioguides/speech.py`.
- **Aislamiento**: si una voz se cuelga, se mata ese proceso y el worker sigue.
- **Tamaño**: la API no necesita Piper ni onnxruntime; solo el worker los lleva.

Para actualizar Piper:

```bash
# desde services/ai-orchestrator
uv pip compile tts/requirements.in --python-version 3.13 --universal --generate-hashes -o tts/requirements.txt
```

Las voces no van aquí: las descarga `infrastructure/tts/download-voices.sh`
(`make voices`).
