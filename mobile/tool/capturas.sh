#!/usr/bin/env bash
# Hace las capturas de todas las pantallas en un emulador Android.
#
# Lo usa el robot de GitHub (.github/workflows/capturas.yml) con el emulador
# ya encendido. La app se compila con lib/tour_main.dart: se abre sola,
# visita cada pantalla y escribe "ECLIPTA_SHOT:nombre" en el registro del
# móvil (logcat). Este script lo lee y hace la foto en ese momento.
#
# Uso: tool/capturas.sh <app.apk> <carpeta de las capturas>
set -u

APK="$1"
OUT="$2"
PKG=com.eclipta.app
mkdir -p "$OUT"

# -g: todos los permisos ya dados (ubicación, cámara...), sin ventanitas.
adb install -r -g "$APK"
adb logcat -c
# Sin animaciones del sistema: capturas más estables.
adb shell settings put global window_animation_scale 0 || true
adb shell settings put global transition_animation_scale 0 || true
adb shell settings put global animator_duration_scale 0 || true

# Cada 10 s, la memoria que usa el emulador en el robot (en MB): si se
# cae por falta de memoria se verá cómo sube en el registro.
( while sleep 10; do
    ps -C qemu-system-x86_64 -o rss= 2>/dev/null | awk '{printf "MEMORIA emulador: %d MB\n", $1/1024}'
    free -m | awk '/Mem:/{printf "MEMORIA libre robot: %d MB\n", $7}'
  done ) &
MEMPID=$!
trap 'kill $MEMPID 2>/dev/null' EXIT

adb shell monkey -p "$PKG" -c android.intent.category.LAUNCHER 1 >/dev/null

# Lee el registro hasta "FIN" (o como mucho 15 minutos).
# Además de los avisos de la app (flutter), los errores graves de Android
# (cierres, WebView, gráficos): si el emulador se cae, en el registro del
# robot queda lo último que pasó (el .zip no siempre se puede abrir).
timeout 900 adb logcat -v raw -s flutter:I AndroidRuntime:E chromium:E cr_*:E libc:F DEBUG:F OpenGLRenderer:E EGL_emulation:E | while IFS= read -r line; do
  case "$line" in
    *ECLIPTA_SHOT:FIN*)
      echo "Fin del recorrido"
      touch "$OUT/.fin"
      break
      ;;
    *ECLIPTA_SHOT:*)
      name="${line##*ECLIPTA_SHOT:}"
      name="$(printf '%s' "$name" | tr -cd 'a-z0-9-')"
      # Como mucho 30 s por foto: si el emulador se cae, adb se quedaría
      # esperando para siempre ("waiting for device") hasta el límite de
      # 60 minutos del robot. Así falla rápido y se ve dónde se cayó.
      if ! timeout 30 adb exec-out screencap -p > "$OUT/$name.png"; then
        echo "El emulador no responde (se ha caído) en: $name" >&2
        break
      fi
      echo "Captura: $name"
      ;;
    *)
      # Cualquier otra línea: al registro del robot (recortada).
      printf 'LOG: %.300s\n' "$line"
      ;;
  esac
done

# El registro completo de la app, por si algo falla (errores de Flutter).
timeout 30 adb logcat -d -s flutter:* > "$OUT/registro-flutter.txt" || true
count=$(ls "$OUT"/*.png 2>/dev/null | wc -l)
echo "Capturas hechas: $count"
# Solo vale si la app llegó al final: si el emulador se cae a medias, es
# un fallo (antes salía "bien" con que hubiera una sola foto).
if [ ! -f "$OUT/.fin" ]; then
  echo "El recorrido NO llegó al final (mira la última captura)." >&2
  # Pistas en el registro del robot (el .zip no siempre se puede abrir):
  # ¿sigue viva la app?, sus últimas líneas y si Android la cerró.
  echo "== ¿App viva? (número de proceso) ==" >&2
  timeout 15 adb shell pidof "$PKG" >&2 || echo "  NO: la app se cerró" >&2
  echo "== Últimas líneas de la app ==" >&2
  tail -n 40 "$OUT/registro-flutter.txt" >&2 || true
  echo "== Cierres de Android (crash / sin memoria) ==" >&2
  timeout 15 adb logcat -d -b crash | tail -n 40 >&2 || true
  timeout 15 adb logcat -d | grep -E "lowmemorykiller|ActivityManager: (Process|Killing).*eclipta|ANR in" | tail -n 20 >&2 || true
  exit 1
fi
rm -f "$OUT/.fin"
[ "$count" -gt 0 ]
