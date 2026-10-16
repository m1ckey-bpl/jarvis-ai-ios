"""HTTP transport used by providers and integrations.

Injectable on purpose: production uses `urllib`, tests inject a recording
transport, so no test ever touches the network.
"""

from __future__ import annotations

import json
import urllib.error
import urllib.request
from dataclasses import dataclass, field
from typing import Any, Protocol

from .errors import ProviderUnavailable


@dataclass
class HTTPRequest:
    url: str
    method: str = "GET"
    headers: dict[str, str] = field(default_factory=dict)
    body: bytes | None = None
    timeout: float = 30.0
    label: str = "request"


@dataclass
class HTTPResponse:
    status: int
    headers: dict[str, str]
    body: bytes

    def json(self) -> Any:
        if not self.body:
            return {}
        try:
            return json.loads(self.body.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError) as error:
            raise ProviderUnavailable(f"the service returned a non-JSON response: {error}") from error


class Transport(Protocol):
    def send(self, request: HTTPRequest) -> HTTPResponse:  # pragma: no cover - protocol
        ...


class UrllibTransport:
    """Standard-library HTTP. Retries only idempotent failures, with backoff."""

    def __init__(self, attempts: int = 3, backoff: float = 0.5) -> None:
        self.attempts = attempts
        self.backoff = backoff

    def send(self, request: HTTPRequest) -> HTTPResponse:
        last_error: Exception | None = None
        for attempt in range(self.attempts):
            try:
                req = urllib.request.Request(request.url, data=request.body, method=request.method)
                for key, value in request.headers.items():
                    req.add_header(key, value)
                with urllib.request.urlopen(req, timeout=request.timeout) as response:  # noqa: S310 - URLs come from configuration
                    return HTTPResponse(status=response.status,
                                        headers={k.lower(): v for k, v in response.headers.items()},
                                        body=response.read())
            except urllib.error.HTTPError as error:
                body = error.read()
                if error.code in (429, 500, 502, 503, 504) and attempt + 1 < self.attempts:
                    last_error = error
                    import time

                    time.sleep(self.backoff * (2 ** attempt))
                    continue
                return HTTPResponse(status=error.code,
                                    headers={k.lower(): v for k, v in error.headers.items()},
                                    body=body)
            except (urllib.error.URLError, TimeoutError, OSError) as error:
                last_error = error
                if attempt + 1 < self.attempts:
                    import time

                    time.sleep(self.backoff * (2 ** attempt))
                    continue
        raise ProviderUnavailable(f"{request.label} failed after {self.attempts} attempts: {last_error}")


class RecordingTransport:
    """Test double: records requests and replays scripted responses."""

    def __init__(self, responses: list[HTTPResponse] | None = None) -> None:
        self.requests: list[HTTPRequest] = []
        self.responses: list[HTTPResponse] = list(responses or [])

    def queue(self, status: int, payload: Any, headers: dict[str, str] | None = None) -> None:
        body = payload if isinstance(payload, bytes) else json.dumps(payload).encode("utf-8")
        self.responses.append(HTTPResponse(status=status, headers=headers or {}, body=body))

    def send(self, request: HTTPRequest) -> HTTPResponse:
        self.requests.append(request)
        if not self.responses:
            raise AssertionError(f"unexpected request to {request.url} ({request.label})")
        return self.responses.pop(0)
