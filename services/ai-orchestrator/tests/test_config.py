"""Tests de la configuración: lo inseguro no arranca salvo que se pida."""

from __future__ import annotations

from typing import Any

import pytest
from pydantic import ValidationError

from ai_orchestrator.config import Settings

BASE: dict[str, Any] = {
    "kafka_brokers": "localhost:29092, otro:9092",
    "pghost": "localhost",
    "pguser": "nomadiq",
    "pgpassword": "secreto",
    "pgdatabase": "nomadiq",
    "redis_host": "localhost",
    "redis_password": "secreto",
}
DEV: dict[str, Any] = {
    **BASE,
    "http_insecure_dev": True,
    "pgsslmode": "disable",
    "db_insecure_dev": True,
    "ollama_insecure_dev": True,
    "redis_tls": False,
    "redis_insecure_dev": True,
}


@pytest.fixture(autouse=True)
def clean_env(monkeypatch: pytest.MonkeyPatch) -> None:
    # Si tu terminal tiene variables como QDRANT_API_KEY (por ejemplo, tras
    # cargar el .env), no deben colarse en estos tests.
    for name in Settings.model_fields:
        monkeypatch.delenv(name.upper(), raising=False)


def settings(**kw: Any) -> Settings:
    # _env_file=None: el test no lee ningún .env de tu ordenador.
    return Settings(_env_file=None, **kw)


def test_local_dev_config_is_accepted() -> None:
    s = settings(**DEV)
    assert s.kafka_broker_list == ["localhost:29092", "otro:9092"]
    assert s.llm_temperature <= 0.2  # temperatura baja por defecto
    # La contraseña no aparece si alguien imprime la configuración.
    assert "secreto" not in repr(s)


def test_secure_defaults_require_mtls_and_verified_db() -> None:
    with pytest.raises(ValidationError) as err:
        settings(**BASE)
    text = str(err.value)
    assert "mTLS" in text
    assert "PGSSLMODE=verify-full" not in text  # el modo por defecto ya es el seguro
    assert "OLLAMA_URL usa http" in text


def test_db_without_verification_needs_explicit_flag() -> None:
    with pytest.raises(ValidationError, match="PGSSLMODE=require"):
        settings(**{**DEV, "pgsslmode": "require", "db_insecure_dev": False})


def test_contradictory_flags_are_rejected() -> None:
    with pytest.raises(ValidationError, match="contradice"):
        settings(**{**DEV, "pgsslmode": "verify-full"})


def test_partial_tls_files_are_rejected(tmp_path: Any) -> None:
    with pytest.raises(ValidationError, match="van juntas"):
        settings(**{**DEV, "http_insecure_dev": False, "tls_cert_file": tmp_path / "a.pem"})


def test_qdrant_requires_api_key_and_https() -> None:
    with pytest.raises(ValidationError) as err:
        settings(**{**DEV, "qdrant_url": "http://qdrant:6333"})
    assert "QDRANT_API_KEY" in str(err.value)
    assert "QDRANT_INSECURE_DEV" in str(err.value)


def test_values_are_bounded() -> None:
    with pytest.raises(ValidationError):
        settings(**{**DEV, "llm_max_attempts": 50})
    with pytest.raises(ValidationError):
        settings(**{**DEV, "llm_temperature": 1.5})


def test_reads_from_environment(monkeypatch: pytest.MonkeyPatch) -> None:
    for key, value in DEV.items():
        monkeypatch.setenv(key.upper(), str(value).lower() if isinstance(value, bool) else str(value))
    monkeypatch.setenv("OLLAMA_MODEL", "qwen2.5:7b")
    s = Settings(_env_file=None)  # type: ignore[call-arg]
    assert s.ollama_model == "qwen2.5:7b"
    assert s.pgpassword.get_secret_value() == "secreto"


def test_audioguides_need_redis_and_a_known_language() -> None:
    no_redis = {k: v for k, v in DEV.items() if not k.startswith("redis_")}
    with pytest.raises(ValidationError, match="REDIS_HOST"):
        settings(**no_redis)
    # Sin audioguías, Redis no hace falta.
    assert not settings(
        **no_redis,
        audioguides_enabled=False,
        places_enabled=False,
        flyra_enabled=False,
        landmarks_enabled=False,
    ).audioguides_enabled
    with pytest.raises(ValidationError, match="PLACES_ENABLED"):
        settings(**no_redis, audioguides_enabled=False, flyra_enabled=False, landmarks_enabled=False)
    with pytest.raises(ValidationError, match="REDIS_INSECURE_DEV"):
        settings(**{**DEV, "redis_insecure_dev": False})
    with pytest.raises(ValidationError, match="AUDIOGUIDE_DEFAULT_LANGUAGE"):
        settings(**{**DEV, "audioguide_default_language": "xx"})
    # El cerrojo dura más que la peor generación posible (3 intentos de 60 s).
    assert settings(**DEV).audioguide_lock_ttl_seconds > 180


def test_flyra_needs_redis_only_with_an_llm() -> None:
    no_redis = {k: v for k, v in DEV.items() if not k.startswith("redis_")}
    off = {"audioguides_enabled": False, "places_enabled": False, "landmarks_enabled": False}
    with pytest.raises(ValidationError, match="FLYRA_ENABLED"):
        settings(**no_redis, **off)
    # Sin modelo no hay chat, así que tampoco hace falta su contador.
    assert settings(**no_redis, **off, llm_enabled=False).flyra_enabled
    assert settings(**DEV).flyra_daily_limit == 50


def test_landmarks_need_redis() -> None:
    no_redis = {k: v for k, v in DEV.items() if not k.startswith("redis_")}
    off = {"audioguides_enabled": False, "places_enabled": False, "flyra_enabled": False}
    with pytest.raises(ValidationError, match="LANDMARKS_ENABLED"):
        settings(**no_redis, **off)
    # Sin modelo de visión por defecto: se decide por GPS y brújula.
    assert settings(**DEV).landmark_vision_model is None


def test_mapillary_token_is_optional_checked_and_never_echoed() -> None:
    # Sin token, el botón "Ver la calle de verdad" no existe y nada falla.
    assert settings(**DEV).mapillary_token is None
    assert settings(**DEV, mapillary_token="").mapillary_token is None
    assert settings(**DEV, mapillary_token="MLY|123|abc0").mapillary_token is not None
    with pytest.raises(ValidationError) as err:
        settings(**DEV, mapillary_token="secreto-raro")
    assert "MAPILLARY_TOKEN" in str(err.value)
    assert "secreto-raro" not in str(err.value)
    no_redis = {k: v for k, v in DEV.items() if k not in ("redis_host", "redis_password")}
    with pytest.raises(ValidationError, match="fotos de calle necesitan Redis"):
        settings(**no_redis, audioguides_enabled=False, places_enabled=False, mapillary_token="MLY|1|a")
