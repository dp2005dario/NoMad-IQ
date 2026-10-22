#!/usr/bin/env bash
# Descarga las voces de Piper (una por idioma) en infrastructure/tts/voices/<idioma>/.
#
# Uso:  ./download-voices.sh            # los 6 idiomas (unos 230 MB)
#       ./download-voices.sh es en      # solo esos idiomas
#
# Cada archivo se comprueba con su huella SHA-256 antes de usarlo: si alguien
# cambiara el archivo en el servidor (o llegara corrupto), el script se para.
# Es la misma idea que el uv.lock o el go.sum, pero para las voces.
#
# Las voces NO se guardan en git (pesan decenas de MB cada una): las baja este
# script. El worker de audio las lee en modo solo lectura desde /voices.
#
# Licencias: cada voz trae su MODEL_CARD con la licencia de los datos con los
# que se entrenó. Revísalas antes de un uso comercial (ver docs/guia-audioguias.md).
set -euo pipefail

BASE_URL="https://github.com/rhasspy/piper/releases/download/v0.0.2"
DIR="$(cd "$(dirname "$0")" && pwd)/voices"

# idioma | voz | sha256 del .tar.gz
VOICES=(
  "es|es-carlfm-x-low|0156a186de321639e6295521f667758ad086bc8433f0a6797a9f044ed5cf5bf3"
  "en|en-gb-alan-low|526eeeeccb26206dc92de5965615803b5bf88df059f46372caa4a9fa12d76a32"
  "fr|fr-gilles-low|77662c7332c2a6f522ab478287d9b0fe9afc11a2da71f310bf923124ee699aae"
  "de|de-thorsten-low|4d052a7726b77719d0dbc66c845f1d0fe4432bfbd26f878f6dd0883d49e9e43d"
  "it|it-riccardo_fasol-x-low|394b27b8780f5167e73a62ac103839cc438abc7edb544192f965e5b8f5f4acdb"
  "pt|pt-br-edresson-low|c68be522a526e77f49e90eeb4c13c01b4acdfeb635759f0eeb0eea8f16fd1f33"
)

wanted=("$@")
for entry in "${VOICES[@]}"; do
  IFS='|' read -r lang name sha <<<"$entry"
  if [ ${#wanted[@]} -gt 0 ] && [[ ! " ${wanted[*]} " =~ " ${lang} " ]]; then
    continue
  fi
  target="$DIR/$lang"
  if [ -f "$target/$name.onnx" ]; then
    echo "✓ $lang: $name ya está"
    continue
  fi
  echo "↓ $lang: $name"
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  curl -fsSL --retry 3 -o "$tmp/voice.tar.gz" "$BASE_URL/voice-$name.tar.gz"
  echo "$sha  $tmp/voice.tar.gz" | sha256sum -c --quiet -
  mkdir -p "$tmp/x"
  tar -xzf "$tmp/voice.tar.gz" -C "$tmp/x"
  # Una sola voz por carpeta de idioma (el worker se niega a elegir entre varias).
  rm -rf "$target"
  mkdir -p "$target"
  mv "$tmp/x/$name.onnx" "$tmp/x/$name.onnx.json" "$target/"
  [ -f "$tmp/x/MODEL_CARD" ] && mv "$tmp/x/MODEL_CARD" "$target/MODEL_CARD"
  rm -rf "$tmp"
  trap - EXIT
done
echo "Voces en $DIR"
