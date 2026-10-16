"""Configuration must fail closed: an operator cannot accidentally expose the
backend, and a capability report must never contain a secret."""

from __future__ import annotations

import pathlib

import pytest

from app.config import ConfigurationError, Settings


def base_env(**overrides: str) -> dict[str, str]:
    env = {
        "JARVIS_HOST": "127.0.0.1",
        "JARVIS_BACKEND_TOKEN": "t" * 24,
        "JARVIS_PROVIDER_API_KEY": "gsk_example_example_example",
        "JARVIS_PROVIDER_MODEL": "openai/gpt-oss-120b",
    }
    env.update(overrides)
    return env


def test_defaults_are_safe() -> None:
    settings = Settings.load({})
    assert settings.host == "127.0.0.1"
    assert settings.require_https is False
    assert settings.max_request_bytes == 1 << 20


def test_public_bind_without_token_is_refused() -> None:
    with pytest.raises(ConfigurationError) as error:
        Settings.load(base_env(JARVIS_HOST="0.0.0.0", JARVIS_BACKEND_TOKEN=""))
    assert "JARVIS_BACKEND_TOKEN" in str(error.value)


def test_public_bind_requires_tls_acknowledgement() -> None:
    with pytest.raises(ConfigurationError) as error:
        Settings.load(base_env(JARVIS_HOST="0.0.0.0"))
    assert "TLS" in str(error.value)

    settings = Settings.load(base_env(JARVIS_HOST="0.0.0.0", JARVIS_TRUST_PROXY_TLS="1"))
    assert settings.host == "0.0.0.0"

    settings = Settings.load(base_env(JARVIS_HOST="0.0.0.0", JARVIS_REQUIRE_HTTPS="1"))
    assert settings.require_https is True


def test_limits_are_validated() -> None:
    with pytest.raises(ConfigurationError):
        Settings.load(base_env(JARVIS_RATE_LIMIT_PER_MINUTE="0"))
    with pytest.raises(ConfigurationError):
        Settings.load(base_env(JARVIS_MAX_REQUEST_BYTES="10"))


def test_capability_report_contains_no_secret_values() -> None:
    settings = Settings.load(base_env(JARVIS_GITHUB_TOKEN="ghp_secret_value_that_must_not_leak",
                                      JARVIS_GOOGLE_CLIENT_SECRET="client-secret-value"))
    report = settings.capability_report()
    flattened = " ".join(f"{key}={value}" for key, value in report.items())
    assert "ghp_secret_value_that_must_not_leak" not in flattened
    assert "client-secret-value" not in flattened
    assert report["github"] == "configured"
    assert report["provider"] == "configured"


def test_data_dir_is_expandable(tmp_path: pathlib.Path) -> None:
    settings = Settings.load(base_env(JARVIS_DATA_DIR=str(tmp_path / "nested" / "data")))
    assert settings.database_path.name == "jarvis.sqlite3"
    assert settings.database_path.parent == tmp_path / "nested" / "data"


def test_origins_are_parsed_and_trimmed() -> None:
    settings = Settings.load(base_env(JARVIS_ALLOWED_ORIGINS=" https://a.example , https://b.example ,, "))
    assert settings.allowed_origins == ["https://a.example", "https://b.example"]
