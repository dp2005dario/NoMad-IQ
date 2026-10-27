# Guía para principiantes: "Ayuda"

La pantalla de Ayuda sigue una regla sencilla: **primero Flyra** (responde al
momento, de día y de noche) y, si hace falta, **una persona**. Se abre desde
Ajustes → Ayuda.

## Las opciones

| Opción | Qué hace el botón | Siempre sale |
| --- | --- | --- |
| Pregunta a Flyra | abre el chat con Flyra | sí |
| Tu aerolínea o agencia | abre Papeles (tus derechos y la carta de reclamación) | sí |
| Asistencia de tu seguro | abre la Bóveda, donde está tu póliza con el teléfono 24 h | sí |
| Expertos en reclamaciones | abre la web del socio | solo si hay socio configurado |
| Gestor de visados | abre la web del socio | solo si hay socio configurado |
| Soporte de ECLIPTA | abre tu correo con un mensaje al equipo | solo si hay correo configurado |

Las opciones de pago o con comisión **lo dicen claramente** en su tarjeta. Las
que no tienen contacto configurado no salen, para no llevarte a un sitio vacío.

## Cómo se configuran los contactos (te toca a ti, DARIO)

Se pasan al compilar la app, igual que los datos de Firebase:

```bash
flutter run \
  --dart-define=NOMADIQ_SUPPORT_EMAIL=soporte@tudominio.com \
  --dart-define=NOMADIQ_CLAIMS_PARTNER_URL=https://... \
  --dart-define=NOMADIQ_VISA_PARTNER_URL=https://...
```

- El **correo de soporte** lo eliges tú.
- Los **socios** de reclamaciones y visados salen de programas de afiliados. Por
  ejemplo, Travelpayouts tiene socios de reclamaciones de vuelos. Pega el enlace
  de afiliado que te den, y solo se aceptan enlaces `https://`.

El correo de soporte sale ya con la versión de la app y el idioma. No lleva nada
más del móvil.

## Dónde está el código

| Archivo | Qué hace |
| --- | --- |
| `mobile/lib/features/help/help_screen.dart` | la pantalla |
| `mobile/lib/features/help/help_contacts.dart` | los contactos (opcionales) |
| `mobile/lib/core/config.dart` | lee los contactos al compilar |
| `mobile/test/help_test.dart` | las pruebas |

Para probarlo en VS Code: `Terminal > Nuevo terminal`, luego `cd mobile` y
`flutter test test/help_test.dart`.
