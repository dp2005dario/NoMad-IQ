# Guía del SOS (para principiantes)

El botón rojo **SOS** es el primer atajo de Inicio. Está pensado para un mal
momento en un país que no conoces: sin Internet, sin saber el idioma y sin
saber a qué número llamar.

## 1. Cómo funciona

1. Al abrir la pantalla, el móvil pide la ubicación al GPS.
2. **¿En qué país estoy?** Sin Internet: se busca el aeropuerto más cercano
   entre los ~5.500 que la app ya lleva dentro (`assets/geo/airports.txt`) y
   se usa su país. Si está a más de 400 km (en alta mar), no se adivina.
3. Con el país salen:
   - los **números de emergencia** (`lib/features/sos/emergency_data.dart`).
     Si el país no está en la tabla, el **112**: los móviles GSM lo desvían
     al número local casi en todo el mundo;
   - **"¡Ayuda!" en el idioma de allí**, con su pronunciación si se escribe
     con otro alfabeto (助けて！ → «Tasukete!»).
4. **Mantener pulsado 3 segundos** el botón (se va llenando; si sueltas
   antes, no pasa nada: así no salta en el bolsillo). Entonces aparecen:
   - **Llamar al número de aquí** (abre el marcador con el número puesto);
   - **Mandar mi ubicación a mis contactos**: abre un SMS ya escrito para
     todos ellos con un enlace al mapa de OpenStreetMap. Lo envías tú: así
     funciona sin servidor y sin datos móviles (los SMS van por la red de
     voz).

## 2. Lo que se guarda (solo en el móvil)

| Qué | Dónde |
|---|---|
| Hasta 5 contactos (nombre y teléfono) | `LocalData.sosContacts` |
| Ficha médica (grupo sanguíneo, alergias, enfermedades, medicación) | `LocalData.medicalCard` |

Nada de esto va a ningún servidor. Se borra con "Borrar mi cuenta".

## 3. Límites honestos

- No hay "ubicación en directo hasta que lo canceles" (la maqueta lo
  enseñaba): necesitaría un servidor que guarde tu posición sin parar. Se
  manda la posición del momento en el SMS.
- Cerca de una frontera el país puede salir el de al lado (el aeropuerto
  más cercano está cruzando). Los números de emergencia del vecino casi
  siempre funcionan también, y el 112 casi siempre.
- "Embajadas y consulados cerca" abre la búsqueda de OpenStreetMap: depende
  de que alguien las haya puesto en el mapa (en capitales, casi siempre).

## 4. Probarlo desde Visual Studio Code

1. **Archivo → Abrir carpeta…** → `ECLIPTA`, **Ver → Terminal**.
2. `cd mobile` y `flutter test test/sos_test.dart`.
3. En un móvil de verdad: **Inicio → SOS**. Para probar sin llamar a
   emergencias, añade un contacto tuyo y usa solo el botón del SMS.
