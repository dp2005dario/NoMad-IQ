"""Identidad de quien llama: la lee de las cabeceras que pone el auth-gateway.

Vive en su propio módulo porque la usan varias partes de la API
(recomendaciones, audioguías, negociaciones). La explicación de por qué nos
fiamos de estas cabeceras (mTLS + Zero Trust) está al principio de api.py.
"""

from __future__ import annotations

import re
from dataclasses import dataclass
from typing import Annotated

from fastapi import Header, HTTPException

HEADER_USER_ID = "X-User-ID"
HEADER_USER_ROLES = "X-User-Roles"
# Rol mínimo para usar la API (el auth-gateway emite USER y ADMIN).
REQUIRED_ROLE = "USER"

# Formato de un user_id (el auth-gateway emite UUID; se admite algo más amplio).
USER_ID_RE = re.compile(r"^[A-Za-z0-9._:@-]{1,128}$")
_ROLE = re.compile(r"^[A-Z_]{1,32}$")


@dataclass(frozen=True, slots=True)
class Principal:
    """Quién hace la petición (ya autenticado por el auth-gateway)."""

    user_id: str
    roles: frozenset[str]


async def current_principal(
    user_id: Annotated[str | None, Header(alias=HEADER_USER_ID)] = None,
    roles: Annotated[str | None, Header(alias=HEADER_USER_ROLES)] = None,
) -> Principal:
    """Lee la identidad de las cabeceras y la valida con reglas estrictas."""
    if user_id is None or not USER_ID_RE.fullmatch(user_id):
        raise HTTPException(status_code=401, detail="identidad ausente o inválida")
    parsed = frozenset(r.strip() for r in (roles or "").split(",") if r.strip())
    if any(not _ROLE.fullmatch(r) for r in parsed):
        raise HTTPException(status_code=401, detail="roles inválidos")
    # Control de acceso por roles (RBAC): sin el rol USER, no hay acceso.
    if REQUIRED_ROLE not in parsed:
        raise HTTPException(status_code=403, detail="se necesita el rol USER")
    return Principal(user_id=user_id, roles=parsed)
