"""Shared fixtures. No test in this suite touches the network."""

from __future__ import annotations

import json
import pathlib
import sqlite3
import sys

import pytest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))

from app.api import Application  # noqa: E402
from app.config import Settings  # noqa: E402
from app.http import Request  # noqa: E402
from app.transport import HTTPResponse, RecordingTransport  # noqa: E402

TOKEN = "test-token-0123456789abcdef"


@pytest.fixture
def settings(tmp_path: pathlib.Path) -> Settings:
    return Settings(host="127.0.0.1", port=0, auth_token=TOKEN, data_dir=tmp_path,
                    rate_limit_per_minute=1000, max_request_bytes=64 * 1024,
                    provider_api_key="test-key", provider_base_url="https://provider.invalid/v1",
                    provider_model="test-model")


@pytest.fixture
def transport() -> RecordingTransport:
    return RecordingTransport()


@pytest.fixture
def app(settings: Settings, transport: RecordingTransport) -> Application:
    connection = sqlite3.connect(":memory:", check_same_thread=False)
    return Application(settings, transport=transport, connection=connection)


class Client:
    """Drives the application in-process — fast, and it exercises the same code
    path the socket server uses (router, policy, audit)."""

    def __init__(self, application: Application, token: str | None = TOKEN) -> None:
        self.application = application
        self.token = token
        self.last_response = None

    @property
    def transport(self):
        return self.application.transport

    def call(self, method: str, path: str, *, body: dict | None = None, token: str | None = "__default__",
             headers: dict[str, str] | None = None, query: str = ""):
        payload = b"" if body is None else json.dumps(body).encode("utf-8")
        request_headers = {"content-type": "application/json"}
        effective = self.token if token == "__default__" else token
        if effective:
            request_headers["authorization"] = f"Bearer {effective}"
        request_headers.update(headers or {})
        request = Request(method=method.upper(), path=path, query=_parse(query), headers=request_headers,
                          body=payload, remote="127.0.0.1")
        response = self.application.handle(request)
        self.last_response = response
        return response

    def json(self, method: str, path: str, **kwargs):
        response = self.call(method, path, **kwargs)
        return response.status, json.loads(response.body.decode("utf-8"))


def _parse(query: str) -> dict[str, list[str]]:
    from urllib.parse import parse_qs

    return parse_qs(query)


@pytest.fixture
def client(app: Application) -> Client:
    return Client(app)


@pytest.fixture
def request_factory(app: Application):
    def factory(method: str, path: str, *, body: bytes | None = None, token: str | None = TOKEN,
                headers: dict[str, str] | None = None, query: dict | None = None, remote: str = "127.0.0.1"):
        request_headers = dict(headers or {})
        if token:
            request_headers.setdefault("authorization", f"Bearer {token}")
        return Request(method=method, path=path, query=query or {}, headers=request_headers,
                       body=body or b"", remote=remote)

    return factory


def ok(response) -> dict:
    assert response.status < 400, f"unexpected status {response.status}: {response.body[:300]!r}"
    return json.loads(response.body.decode("utf-8"))


def reply(payload: dict) -> HTTPResponse:
    return HTTPResponse(status=200, headers={}, body=json.dumps(payload).encode("utf-8"))
