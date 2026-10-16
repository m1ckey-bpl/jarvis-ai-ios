"""Entry point: `python3 -m app.main [--host HOST] [--port PORT] [--check]`.

`--check` validates configuration, opens the database, applies migrations,
registers every tool and prints a report — the same work CI does, without
listening on a socket.
"""

from __future__ import annotations

import argparse
import json
import signal
import sys
import time

from .api import Application
from .config import ConfigurationError, Settings


def build_settings(arguments: argparse.Namespace) -> Settings:
    settings = Settings.load()
    if arguments.host:
        settings.host = arguments.host
    if arguments.port:
        settings.port = arguments.port
    if arguments.data_dir:
        import pathlib

        settings.data_dir = pathlib.Path(arguments.data_dir).expanduser()
    settings.validate()
    return settings


def self_check(settings: Settings) -> int:
    """Non-networking startup check used by CI and by `--check`."""
    report: dict[str, object] = {"host": settings.host, "port": settings.port,
                                 "authConfigured": bool(settings.auth_token),
                                 "dataDir": str(settings.data_dir)}
    application = Application(settings)
    report["database"] = str(settings.database_path)
    report["memorySchemaVersion"] = application.memory.migrator.current_version
    report["tools"] = application.registry.names()
    report["capabilities"] = application.integrations.capability_report()
    report["memoryRecords"] = application.memory.count()
    application.stop()
    report["ok"] = True
    print(json.dumps(report, indent=2))
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="jarvis-backend")
    parser.add_argument("--host", help="bind address (default from JARVIS_HOST, 127.0.0.1)")
    parser.add_argument("--port", type=int, help="bind port (default from JARVIS_PORT, 8787)")
    parser.add_argument("--data-dir", help="directory for the SQLite database")
    parser.add_argument("--check", action="store_true", help="validate configuration and exit")
    arguments = parser.parse_args(argv)

    try:
        settings = build_settings(arguments)
    except ConfigurationError as error:
        print(f"configuration error: {error}", file=sys.stderr)
        return 2

    if arguments.check:
        return self_check(settings)

    application = Application(settings)
    application.start()

    scheme = "https" if settings.require_https else "http"
    banner = f"JARVIS backend listening on {scheme}://{settings.host}:{application.server.port}"
    print(banner)
    if not settings.auth_token:
        print("auth: DISABLED (loopback only) — set JARVIS_BACKEND_TOKEN to enable authenticated routes")
    else:
        print("auth: bearer token required")
    capabilities = settings.capability_report()
    print("capabilities: " + ", ".join(f"{key}={value}" for key, value in capabilities.items()))
    sys.stdout.flush()

    stopping = {"flag": False}

    def handle_signal(_signum, _frame):
        stopping["flag"] = True

    signal.signal(signal.SIGINT, handle_signal)
    signal.signal(signal.SIGTERM, handle_signal)
    try:
        while not stopping["flag"]:
            time.sleep(0.25)
    finally:
        application.stop()
        print("JARVIS backend stopped")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
