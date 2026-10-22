"""Seudónimos de destinatario: HMAC-SHA256 del user_id con una clave secreta.

Es EXACTAMENTE el mismo cálculo que hacen el geo-engine (Rust) y el notifier
(Go), con la misma etiqueta. Gracias a eso, cuando anunciamos por Kafka que
una negociación terminó, podemos decir "avisad a estas personas" sin escribir
ningún user_id: el notifier reconoce los seudónimos porque guarda los
teléfonos con ellos.

Analogía: el número de taquilla del gimnasio. El notifier sabe que la
taquilla 4F7A tiene dos teléfonos, pero no de quién es. Solo quien tiene la
llave maestra (la clave) puede calcular la taquilla de cada persona.

El test test_pseudonym_matches_go_and_rust comprueba que el resultado es
idéntico al de los otros dos servicios.
"""

from __future__ import annotations

import base64
import hashlib
import hmac

# Separación de dominios: la misma etiqueta que services/notifier/internal/pseudonym.
_CONTEXT = b"nomadiq/notify/recipient/v1\x00"
MIN_KEY_BYTES = 32


class Pseudonymizer:
    def __init__(self, key: bytes) -> None:
        if len(key) < MIN_KEY_BYTES:
            raise ValueError(f"la clave de seudónimos necesita al menos {MIN_KEY_BYTES} bytes")
        self._key = bytes(key)

    @classmethod
    def from_hex(cls, value: str) -> Pseudonymizer:
        try:
            return cls(bytes.fromhex(value.strip()))
        except ValueError as exc:
            raise ValueError("la clave de seudónimos debe ir en hexadecimal (openssl rand -hex 32)") from exc

    def recipient(self, user_id: str) -> str:
        mac = hmac.new(self._key, _CONTEXT + user_id.encode(), hashlib.sha256)
        # base64url sin relleno "=": 43 caracteres.
        return base64.urlsafe_b64encode(mac.digest()).rstrip(b"=").decode()

    def __repr__(self) -> str:
        # Nunca imprimir la clave, ni en un log de depuración.
        return "Pseudonymizer(<oculta>)"
