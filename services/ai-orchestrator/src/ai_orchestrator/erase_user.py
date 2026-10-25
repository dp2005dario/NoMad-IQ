"""Borrar a mano los datos de UNA persona (cuando lo pide por correo).

Lo normal es que cada persona borre su cuenta desde la app (Ajustes). Pero
Google Play y el RGPD exigen también una vía para quien ya no tiene la app o
no recuerda la contraseña: nos escribe y lo hacemos nosotros. Este programa
es la parte de este servicio en ese borrado; el resto lo hace
infrastructure/production/erase-user.sh, que lo llama así:

    python -m ai_orchestrator.erase_user <user_id>

Hace EXACTAMENTE lo mismo que "Borrar mis datos" desde la app (la misma
clase PostgresEraser), así que no hay dos versiones que se desincronicen.

Imprime solo números (cuántas cosas se borraron) y, si hay clave de
seudónimos, el seudónimo de notificaciones de la persona, para que el
script borre también sus teléfonos registrados en el notifier. Nunca
imprime datos de la persona.
"""

from __future__ import annotations

import asyncio
import dataclasses
import json
import sys
import uuid

from ai_orchestrator.config import Settings
from ai_orchestrator.erasure import PostgresEraser, UserDataEraser
from ai_orchestrator.pseudonym import Pseudonymizer
from ai_orchestrator.store import create_pool


def parse_user_id(raw: str) -> str:
    """El auth-gateway solo emite UUID: cualquier otra cosa es un error de tecleo."""
    try:
        return str(uuid.UUID(raw.strip()))
    except ValueError as exc:
        raise ValueError(f"user_id no válido (se espera un UUID): {raw!r}") from exc


async def erase(
    user_id: str, eraser: UserDataEraser, pseudonymizer: Pseudonymizer | None
) -> dict[str, object]:
    report = await eraser.erase(user_id)
    out: dict[str, object] = dataclasses.asdict(report)
    if pseudonymizer is not None:
        out["recipient"] = pseudonymizer.recipient(user_id)
    return out


async def _main(raw: str) -> dict[str, object]:
    user_id = parse_user_id(raw)
    settings = Settings()
    key = settings.notify_pseudonym_key
    pseudonymizer = Pseudonymizer.from_hex(key.get_secret_value()) if key is not None else None
    pool = await create_pool(settings)
    try:
        return await erase(user_id, PostgresEraser(pool), pseudonymizer)
    finally:
        await pool.close()


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print("uso: python -m ai_orchestrator.erase_user <user_id>", file=sys.stderr)
        return 2
    try:
        result = asyncio.run(_main(argv[1]))
    except ValueError as exc:
        print(str(exc), file=sys.stderr)
        return 2
    print(json.dumps(result))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
