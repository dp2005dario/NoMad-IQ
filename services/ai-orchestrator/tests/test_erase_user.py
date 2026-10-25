"""Tests del borrado a mano (python -m ai_orchestrator.erase_user)."""

from __future__ import annotations

import pytest

from ai_orchestrator.erase_user import erase, main, parse_user_id
from ai_orchestrator.erasure import ErasureReport
from ai_orchestrator.pseudonym import Pseudonymizer

USER = "7d1c2b9e-3f4a-4c5d-8e6f-1a2b3c4d5e6f"


class FakeEraser:
    def __init__(self) -> None:
        self.calls: list[str] = []

    async def erase(self, user_id: str) -> ErasureReport:
        self.calls.append(user_id)
        return ErasureReport(
            recommendations=1,
            groups_deleted=0,
            seats_anonymized=2,
            negotiation_seats_anonymized=1,
        )


def test_parse_user_id_normalizes_uuid() -> None:
    assert parse_user_id(f"  {USER.upper()} ") == USER


@pytest.mark.parametrize("bad", ["", "dario@example.com", "1234", "'; DROP TABLE x; --"])
def test_parse_user_id_rejects_non_uuid(bad: str) -> None:
    with pytest.raises(ValueError):
        parse_user_id(bad)


async def test_erase_uses_the_same_eraser_and_adds_recipient() -> None:
    eraser = FakeEraser()
    pseudo = Pseudonymizer(b"k" * 32)
    out = await erase(USER, eraser, pseudo)
    assert eraser.calls == [USER]
    assert out["recommendations"] == 1
    assert out["recipient"] == pseudo.recipient(USER)


async def test_erase_without_key_has_no_recipient() -> None:
    out = await erase(USER, FakeEraser(), None)
    assert "recipient" not in out


def test_main_rejects_bad_arguments(capsys: pytest.CaptureFixture[str]) -> None:
    assert main(["erase_user"]) == 2
    assert main(["erase_user", "no-es-un-uuid"]) == 2
    assert "UUID" in capsys.readouterr().err
