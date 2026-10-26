#!/usr/bin/env python3
"""Convierte las reglas de la puerta de entrada de desarrollo (edge/dynamic.yml)
en las de producción, sin copiar el fichero a mano.

Lo único que cambia en producción es CÓMO habla la puerta con los servicios:
  - https:// en vez de http://
  - con su carné (certificado de cliente, mTLS) y comprobando el del servicio
    con la CA interna.
Las rutas, límites de ritmo y controles son EXACTAMENTE los mismos, así que
lo que se prueba en local es lo que corre en producción.

Uso:  python3 render_edge.py ../edge/dynamic.yml > dynamic-prod.yml
"""

from __future__ import annotations

import re
import sys

CERTS = "/certs"

TRANSPORT = f"""  serversTransports:
    # La puerta enseña su carné (mTLS) y comprueba el del servicio.
    internal-mtls:
      rootCAs: ["{CERTS}/ca.crt"]
      certificates:
        - certFile: {CERTS}/tls.crt
          keyFile: {CERTS}/tls.key
"""


def render(text: str) -> str:
    if "serversTransport" in text:
        raise SystemExit("dynamic.yml ya trae serversTransport: revisa render_edge.py")
    out: list[str] = []
    services = 0
    auth = 0
    for line in text.splitlines():
        server = re.match(r'^(\s*)servers: \[\{ url: "http://([a-z-]+):(\d+)" \}\]\s*$', line)
        forward = re.match(r"^(\s*)address: http://(auth-gateway:\d+/v1/auth/verify)\s*$", line)
        if server:
            indent, host, port = server.groups()
            out.append(f'{indent}servers: [{{ url: "https://{host}:{port}" }}]')
            out.append(f"{indent}serversTransport: internal-mtls")
            services += 1
        elif forward:
            indent, target = forward.groups()
            out.append(f"{indent}address: https://{target}")
            out.append(f"{indent}tls:")
            out.append(f"{indent}  ca: {CERTS}/ca.crt")
            out.append(f"{indent}  cert: {CERTS}/tls.crt")
            out.append(f"{indent}  key: {CERTS}/tls.key")
            auth += 1
        else:
            out.append(line)
            if line == "http:":
                out.append(TRANSPORT.rstrip("\n"))
        if "http://" in out[-1] and not out[-1].lstrip().startswith("#"):
            raise SystemExit(f"línea con http:// que no sé convertir: {line!r}")
    if services == 0 or auth == 0:
        raise SystemExit("no encontré servicios o el forwardAuth en dynamic.yml")
    return "# GENERADO por render_edge.py a partir de edge/dynamic.yml: no editar.\n" + "\n".join(out) + "\n"


if __name__ == "__main__":
    sys.stdout.write(render(open(sys.argv[1], encoding="utf-8").read()))
