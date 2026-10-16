"""Configuration for the JARVIS companion backend.

Every setting comes from the environment so that no secret is ever stored in the
repository. `Settings.load()` validates the combination of settings and refuses
insecure ones instead of warning about them.
"""

from __future__ import annotations

import os
import pathlib
from dataclasses import dataclass, field

LOOPBACK_HOSTS = {"127.0.0.1", "::1", "localhost"}


class ConfigurationError(Exception):
    """Raised when the process is asked to start in an unsafe configuration."""


def _flag(name: str, default: bool = False) -> bool:
    """Environment-only boolean helper (kept for callers that read os.environ)."""
    raw = os.environ.get(name)
    if raw is None:
        return default
    return raw.strip().lower() in {"1", "true", "yes", "on"}


@dataclass
class Settings:
    # Networking
    host: str = "127.0.0.1"
    port: int = 8787
    # Security
    auth_token: str | None = None
    allowed_origins: list[str] = field(default_factory=list)
    require_https: bool = False
    trust_proxy_tls: bool = False
    rate_limit_per_minute: int = 120
    max_request_bytes: int = 1 << 20          # 1 MiB
    # Storage
    data_dir: pathlib.Path = pathlib.Path("./data")
    # Providers (optional — a key here means the device does not need one)
    provider: str = "groq"
    provider_base_url: str = "https://api.groq.com/openai/v1"
    provider_model: str = "openai/gpt-oss-120b"
    provider_api_key: str | None = None
    # Integrations (optional)
    google_client_id: str | None = None
    google_client_secret: str | None = None
    google_redirect_uri: str = "https://localhost/oauth/google/callback"
    whatsapp_token: str | None = None
    whatsapp_phone_number_id: str | None = None
    instagram_token: str | None = None
    search_api_key: str | None = None
    github_token: str | None = None
    # Scheduling / dispatch
    dispatch_webhook: str | None = None
    log_level: str = "info"

    # -- derived -----------------------------------------------------------
    @property
    def is_loopback(self) -> bool:
        return self.host in LOOPBACK_HOSTS

    @property
    def database_path(self) -> pathlib.Path:
        return self.data_dir / "jarvis.sqlite3"

    def capability_report(self) -> dict[str, str]:
        """Which optional features are configured. Never contains secret values."""
        return {
            "provider": "configured" if self.provider_api_key else "server_has_no_key",
            "google_oauth": "configured" if (self.google_client_id and self.google_client_secret) else "not_configured",
            "whatsapp_business": "configured" if (self.whatsapp_token and self.whatsapp_phone_number_id) else "not_configured",
            "instagram_graph": "configured" if self.instagram_token else "not_configured",
            "web_search": "configured" if self.search_api_key else "not_configured",
            "github": "configured" if self.github_token else "not_configured",
            "dispatch_webhook": "configured" if self.dispatch_webhook else "pull_only",
        }

    # -- loading -----------------------------------------------------------
    @classmethod
    def load(cls, env: dict[str, str] | None = None) -> "Settings":
        env = dict(os.environ if env is None else env)

        def get(name: str, default: str | None = None) -> str | None:
            value = env.get(name, default)
            if value is None:
                return None
            value = value.strip()
            return value or None

        def flag(name: str, default: bool = False) -> bool:
            """Reads booleans from the same mapping as everything else.

            (Module-level `_flag` inspects the real process environment, which would
            silently ignore an env mapping passed by a caller or a test.)
            """
            raw = env.get(name)
            if raw is None:
                return default
            return raw.strip().lower() in {"1", "true", "yes", "on"}

        origins = [origin.strip() for origin in (get("JARVIS_ALLOWED_ORIGINS", "") or "").split(",") if origin.strip()]
        settings = cls(
            host=get("JARVIS_HOST", "127.0.0.1") or "127.0.0.1",
            port=int(get("JARVIS_PORT", "8787") or 8787),
            auth_token=get("JARVIS_BACKEND_TOKEN"),
            allowed_origins=origins,
            require_https=flag("JARVIS_REQUIRE_HTTPS"),
            trust_proxy_tls=flag("JARVIS_TRUST_PROXY_TLS"),
            rate_limit_per_minute=int(get("JARVIS_RATE_LIMIT_PER_MINUTE", "120") or 120),
            max_request_bytes=int(get("JARVIS_MAX_REQUEST_BYTES", str(1 << 20)) or (1 << 20)),
            data_dir=pathlib.Path(get("JARVIS_DATA_DIR", "./data") or "./data").expanduser(),
            provider=get("JARVIS_PROVIDER", "groq") or "groq",
            provider_base_url=get("JARVIS_PROVIDER_BASE_URL", "https://api.groq.com/openai/v1") or "https://api.groq.com/openai/v1",
            provider_model=get("JARVIS_PROVIDER_MODEL", "openai/gpt-oss-120b") or "openai/gpt-oss-120b",
            provider_api_key=get("JARVIS_PROVIDER_API_KEY"),
            google_client_id=get("JARVIS_GOOGLE_CLIENT_ID"),
            google_client_secret=get("JARVIS_GOOGLE_CLIENT_SECRET"),
            google_redirect_uri=get("JARVIS_GOOGLE_REDIRECT_URI", "https://localhost/oauth/google/callback") or "https://localhost/oauth/google/callback",
            whatsapp_token=get("JARVIS_WHATSAPP_TOKEN"),
            whatsapp_phone_number_id=get("JARVIS_WHATSAPP_PHONE_NUMBER_ID"),
            instagram_token=get("JARVIS_INSTAGRAM_TOKEN"),
            search_api_key=get("JARVIS_SEARCH_API_KEY"),
            github_token=get("JARVIS_GITHUB_TOKEN"),
            dispatch_webhook=get("JARVIS_DISPATCH_WEBHOOK"),
            log_level=(get("JARVIS_LOG_LEVEL", "info") or "info").lower(),
        )
        settings.validate()
        return settings

    def validate(self) -> None:
        """Refuse unsafe starts. Called by load(); also called by tests directly."""
        if not self.is_loopback and not self.auth_token:
            raise ConfigurationError(
                "JARVIS_BACKEND_TOKEN must be set before binding to a non-loopback "
                "address; refusing to expose an unauthenticated service."
            )
        if not self.is_loopback and self.require_https is False:
            # Not fatal (many free platforms terminate TLS in front of the app),
            # but the operator must acknowledge it explicitly.
            if not self.trust_proxy_tls:
                raise ConfigurationError(
                    "Binding to a public address requires either JARVIS_REQUIRE_HTTPS=1 "
                    "or JARVIS_TRUST_PROXY_TLS=1 to acknowledge that TLS is terminated "
                    "in front of this process."
                )
        if self.rate_limit_per_minute < 1:
            raise ConfigurationError("JARVIS_RATE_LIMIT_PER_MINUTE must be at least 1")
        if self.max_request_bytes < 1024:
            raise ConfigurationError("JARVIS_MAX_REQUEST_BYTES must be at least 1024")
