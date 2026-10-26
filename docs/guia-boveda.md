# Guía de la Bóveda (para principiantes)

La **Bóveda** guarda tus papeles de viaje (pasaporte, DNI, tarjetas de
embarque, seguro, reservas, visados...) **cifrados dentro del móvil** y solo
se abre con tu huella (o el PIN del teléfono). Se abre con el atajo
**Bóveda** de Inicio.

## 0. La idea con una analogía

Piensa en una caja fuerte de hotel:

- Cada documento va en un **sobre cerrado con candado** (cifrado AES-256-GCM).
- La **llave** del candado está guardada en otra caja fuerte más pequeña que
  viene soldada al móvil (el chip seguro: Android Keystore).
- Para sacar la llave hace falta **tu huella**. Sin ella, los sobres son
  ruido: ni nosotros, ni Google, ni quien te robe el móvil puede leerlos.
- Si dejas la caja abierta y te vas, **se cierra sola** a los 2 minutos o en
  cuanto sales de la app.

## 1. Glosario

| Palabra | Qué significa |
|---|---|
| **Cifrar** | Convertir el documento en datos ilegibles que solo la llave devuelve a su forma original |
| **AES-256-GCM** | El candado. "256" es el tamaño de la llave; "GCM" además detecta si alguien ha tocado el sobre |
| **Nonce** | Un número al azar distinto en cada sobre, para que dos sobres iguales no se parezcan |
| **AAD** | Cada sobre va "atado" a su nombre: si alguien lo cambia de sitio, al abrirlo se nota |
| **Keystore** | La caja fuerte del chip del móvil donde vive la llave (paquete `flutter_secure_storage`) |
| **local_auth** | El paquete que enseña la ventana de la huella del sistema |
| **FLAG_SECURE** | Una marca de Android que impide capturas de pantalla y oculta la app en "recientes" |
| **OCR** | Leer el texto de una imagen. Se hace en el móvil con ML Kit |

## 2. El viaje de "escanear el pasaporte"

1. Tocas el botón de la huella. `local_auth` enseña la ventana del sistema.
2. Si es la primera vez, se crean 32 bytes al azar (la llave) y se guardan
   en el Keystore.
3. **Escanear documento** abre la cámara del sistema. La foto temporal se
   borra en cuanto se lee: el único ejemplar es el cifrado.
4. Eliges tipo, nombre y caducidad. Si caduca en menos de 6 meses, sale en
   naranja (muchos países piden 6 meses de validez).
5. El móvil lee el texto (OCR) y se guardan **tres sobres**: la lista
   (`index`), el documento (`<id>.bin`) y su texto (`<id>.txt`).
6. Al cerrar, la llave se borra de la memoria.

Los PDF se leen página a página con el lector de PDF de Android (paquete
`pdfx`). Ese lector necesita una copia en la caché privada de la app: la app
la borra en cuanto termina (`wipePdfTemp`).

## 3. Preguntar a tu seguro

En **Dinero → Tu dinero fuera → Seguro**, abres la Bóveda y eliges la
póliza (tipo "Seguro de viaje"). Tocas una pregunta (maleta perdida, médico,
cancelación, retrasos, robos, esquí) o escribes la tuya.

No hay IA: `policy_search.dart` busca las frases de la póliza que hablan de
eso (con palabras en español, inglés, francés, alemán, italiano y
portugués), prefiere las que llevan un importe y marca las que parecen una
**exclusión**. Así la póliza nunca sale del móvil. La app recuerda siempre
que lo que vale es la póliza.

## 4. Fichero a fichero

| Fichero | Para qué sirve |
|---|---|
| `mobile/lib/features/vault/vault_store.dart` | La llave, los ficheros, la huella y el candado (AES-GCM) |
| `mobile/lib/features/vault/vault.dart` | La Bóveda: abrir, cerrar sola, añadir, leer, borrar |
| `mobile/lib/features/vault/doc_source.dart` | Cámara, galería, PDF, el OCR y borrar copias temporales |
| `mobile/lib/features/vault/vault_screen.dart` | La pantalla (cerrada y abierta) |
| `mobile/lib/features/vault/doc_viewer_screen.dart` | Ver un documento, editarlo o borrarlo |
| `mobile/lib/features/vault/policy_search.dart` | Buscar en la póliza |
| `mobile/lib/features/money/insurance_panel.dart` | La pestaña Seguro |
| `mobile/android/app/src/main/kotlin/.../MainActivity.kt` | La "ventana segura" (sin capturas) |

## 5. Probarlo desde Visual Studio Code

1. **Archivo → Abrir carpeta…** → `ECLIPTA`, y **Ver → Terminal**.
2. `cd mobile` y `flutter test test/vault_test.dart`.
3. En un móvil de verdad: `flutter run`, **Inicio → Bóveda**. El móvil
   necesita tener puesto un bloqueo de pantalla (huella o PIN).

## 6. Límites honestos

- 100 documentos y 15 MB por documento.
- Si desinstalas la app o borras sus datos, la llave desaparece y los
  documentos con ella (es el precio de que nadie más pueda abrirlos). Guarda
  los originales en otro sitio.
- La búsqueda en la póliza encuentra frases, no "entiende" la póliza. Ante la
  duda, llama al teléfono de asistencia.
