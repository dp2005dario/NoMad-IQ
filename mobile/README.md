# NomadIQ — app móvil (Flutter)

La app que usan los viajeros: Android (Google Play) e iOS desde el mismo código.
Guía paso a paso para principiantes: [`docs/guia-app-movil.md`](../docs/guia-app-movil.md).

```bash
cd mobile
flutter pub get        # descarga librerías y genera las traducciones
flutter run            # abre la app en el móvil o emulador conectado
flutter test           # tests
flutter analyze        # revisión estática (la CI no admite ni un aviso)
```

| Carpeta | Qué hay |
|---|---|
| `lib/core/` | tema (colores y letras de las maquetas), rutas, ajustes, nombres de idiomas |
| `lib/features/` | una carpeta por pantalla (bienvenida, inicio, idioma...) |
| `lib/widgets/` | piezas reutilizables (el avatar de Flyra) |
| `lib/l10n/` | textos en cada idioma (`app_XX.arb`); `generated/` se crea solo |
| `assets/fonts/` | Bricolage Grotesque y Manrope (licencia OFL, dentro de la app) |

**Reglas:** ningún texto visible escrito en el código (todo en los `.arb`), diseños que
aguanten idiomas largos, letra grande y derecha-a-izquierda, y la IA siempre se llama Flyra.
