# NomadIQ — app móvil (Flutter)

La app que usan los viajeros: Android (Google Play) e iOS desde el mismo código.
Guía paso a paso para principiantes: [`docs/guia-app-movil.md`](../docs/guia-app-movil.md).

```bash
cd mobile
flutter pub get        # descarga librerías y genera las traducciones
flutter run            # abre la app (backend en http://10.0.2.2:8080 = puerta "edge" por defecto)
flutter run --dart-define=NOMADIQ_API_URL=https://...   # otro backend
flutter run --dart-define=NOMADIQ_TILES_URL=https://...  # otro servidor de mapas (por defecto OpenFreeMap)
flutter run --dart-define-from-file=firebase.json        # con avisos push (copia firebase.example.json)
flutter test           # tests
flutter analyze        # revisión estática (la CI no admite ni un aviso)
```

| Carpeta | Qué hay |
|---|---|
| `lib/core/` | tema (colores y letras de las maquetas), rutas, ajustes, nombres de idiomas, cliente HTTP de los servicios (`api_client.dart`) y la caja de herramientas (`services.dart`) |
| `lib/auth/` | inicio de sesión: cliente del auth-gateway, sesión y almacén cifrado del pase |
| `lib/features/` | una carpeta por pantalla (bienvenida, inicio, idioma, mapa, audioguía...) |
| `lib/features/map/` | mapa MapLibre: estilo día/tarde/noche, zonas del geo-engine, rastreador de GPS y modo viaje (`location_tracker.dart`), envío de posiciones por lotes, aviso al entrar |
| `lib/features/push/` | avisos push: descifrado HPKE, claves del móvil, registro en el notifier y notificaciones traducidas |
| `lib/features/audioguide/` | guion y reproductor (just_audio) de las audioguías del ai-orchestrator |
| `lib/widgets/` | piezas reutilizables (el avatar de Flyra) |
| `lib/l10n/` | textos en cada idioma (`app_XX.arb`); `generated/` se crea solo |
| `assets/fonts/` | Bricolage Grotesque y Manrope (licencia OFL, dentro de la app) |

**Reglas:** ningún texto visible escrito en el código (todo en los `.arb`), diseños que
aguanten idiomas largos, letra grande y derecha-a-izquierda, y la IA siempre se llama Flyra.
