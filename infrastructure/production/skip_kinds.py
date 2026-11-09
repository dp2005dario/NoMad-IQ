#!/usr/bin/env python3
"""Quita piezas del paquete de Kubernetes antes de aplicarlo (lo usa deploy.sh).

Uso:  python3 skip_kinds.py StatefulSet/ollama Deployment/notifier < todo.yaml > aplicar.yaml

Lee los manifiestos (separados por "---") y deja fuera los que sean de ese
tipo y nombre. Así, en un servidor pequeño, la IA local (Ollama) ni arranca;
y sin Firebase no arranca el notifier. Sin argumentos no quita nada.
Solo usa la biblioteca estándar de Python (el servidor no tiene PyYAML).
"""

from __future__ import annotations

import re
import sys


def kind_and_name(doc: str) -> tuple[str, str]:
    """El "kind" y el "metadata.name" de un manifiesto (los de arriba del todo)."""
    kind = re.search(r"^kind:\s*(\S+)", doc, re.M)
    # El nombre es la primera línea "  name:" dentro de "metadata:".
    meta = re.search(r"^metadata:\s*\n((?:[ \t]+.*\n?)*)", doc, re.M)
    name = re.search(r"^\s{2}name:\s*(\S+)", meta.group(1), re.M) if meta else None
    return (kind.group(1) if kind else "", name.group(1).strip("'\"") if name else "")


def main() -> None:
    skip = {a.lower() for a in sys.argv[1:]}
    docs = re.split(r"^---\s*$", sys.stdin.read(), flags=re.M)
    kept = []
    for doc in docs:
        if not doc.strip():
            continue
        kind, name = kind_and_name(doc)
        if f"{kind}/{name}".lower() in skip:
            continue
        kept.append(doc.strip("\n"))
    sys.stdout.write("\n---\n".join(kept) + "\n")


if __name__ == "__main__":
    main()
