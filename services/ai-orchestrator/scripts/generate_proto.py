"""Genera el código Python de los contratos protobuf (carpeta proto/ del repo).

¿Por qué existe este script?
    Los mensajes que viajan por Kafka están "empaquetados" en protobuf, un
    formato binario. Para leerlos, Python necesita unas clases generadas a
    partir de los ficheros .proto (los "planos"). En Go las genera "buf"; en
    Python usamos grpcio-tools, que trae su propio compilador (protoc) dentro,
    así no tienes que instalar nada más.

    El resultado va a src/nomadiq/ y se sube a git (igual que gen/go/): así el
    servicio arranca sin pasos extra y la CI comprueba que está al día.

Uso (desde services/ai-orchestrator):
    uv run python scripts/generate_proto.py
"""

from __future__ import annotations

import shutil
import sys
from importlib import resources
from pathlib import Path

from grpc_tools import protoc

SERVICE_DIR = Path(__file__).resolve().parent.parent
PROTO_DIR = SERVICE_DIR.parent.parent / "proto"
OUT_DIR = SERVICE_DIR / "src"

# Solo generamos lo que este servicio necesita (los eventos y sus dependencias).
PROTO_FILES = [
    "nomadiq/common/v1/common.proto",
    "nomadiq/flights/v1/flights.proto",
    "nomadiq/flights/v1/events.proto",
    # Entradas anónimas a zonas (geo.zone-entries.v1) para las audioguías.
    "nomadiq/geo/v1/geo.proto",
    "nomadiq/geo/v1/events.proto",
]


def main() -> int:
    # Borramos lo generado antes para que no queden ficheros "huérfanos" de
    # contratos que ya no existen.
    target = OUT_DIR / "nomadiq"
    if target.exists():
        shutil.rmtree(target)

    # Los .proto importan "google/protobuf/timestamp.proto": esos ficheros
    # vienen dentro de grpcio-tools y le decimos a protoc dónde están.
    well_known = str(resources.files("grpc_tools") / "_proto")
    args = [
        "protoc",
        f"-I{PROTO_DIR}",
        f"-I{well_known}",
        f"--python_out={OUT_DIR}",
        # .pyi = "pistas de tipos" para que mypy entienda las clases generadas.
        f"--pyi_out={OUT_DIR}",
        *PROTO_FILES,
    ]
    code = protoc.main(args)
    if code != 0:
        print("protoc falló", file=sys.stderr)
        return int(code)

    # Python necesita un __init__.py en cada carpeta para tratarla como paquete.
    for folder in [target, *[p for p in target.rglob("*") if p.is_dir()]]:
        (folder / "__init__.py").write_text("# Código generado desde proto/: no editar a mano.\n")
    print(f"Generado en {target}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
