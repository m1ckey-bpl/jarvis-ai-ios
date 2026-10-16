"""A very small HTTP toolkit: Request, Response, Router and a threading server.

Written against the standard library only so the backend can be deployed on any
free tier (and audited) without a framework. It implements exactly what the API
needs: JSON in, JSON out, bearer auth, size limits, CORS allow-listing and
per-route policies.
"""

from __future__ import annotations

import json
import re
import threading
from dataclasses import dataclass, field
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any, Callable
from urllib.parse import parse_qs, urlparse

from .errors import BadRequest, JarvisBackendError


@dataclass
class Request:
    method: str
    path: str
    query: dict[str, list[str]]
    headers: dict[str, str]
    body: bytes
    remote: str
    path_params: dict[str, str] = field(default_factory=dict)

    # -- helpers -----------------------------------------------------------
    def header(self, name: str, default: str | None = None) -> str | None:
        return self.headers.get(name.lower(), default)

    def json(self) -> Any:
        if not self.body:
            return {}
        try:
            return json.loads(self.body.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError) as error:
            raise BadRequest(f"request body is not valid JSON: {error}") from error

    def param(self, name: str, default: str | None = None) -> str | None:
        values = self.query.get(name)
        return values[0] if values else default


@dataclass
class Response:
    status: int = 200
    body: bytes = b""
    content_type: str = "application/json; charset=utf-8"
    headers: dict[str, str] = field(default_factory=dict)

    @classmethod
    def json(cls, payload: Any, status: int = 200) -> "Response":
        return cls(status=status, body=json.dumps(payload, ensure_ascii=False).encode("utf-8"))

    @classmethod
    def text(cls, body: str, status: int = 200, content_type: str = "text/plain; charset=utf-8") -> "Response":
        return cls(status=status, body=body.encode("utf-8"), content_type=content_type)

    @classmethod
    def bytes(cls, payload: bytes, status: int = 200, content_type: str = "application/octet-stream") -> "Response":
        return cls(status=status, body=payload, content_type=content_type)

    @classmethod
    def empty(cls, status: int = 204) -> "Response":
        return cls(status=status, body=b"", content_type="text/plain")

    @classmethod
    def error(cls, status: int, code: str, message: str, details: dict | None = None) -> "Response":
        body: dict[str, Any] = {"error": {"code": code, "message": message}}
        if details:
            body["error"]["details"] = details
        return cls.json(body, status=status)


Handler = Callable[[Request], Response]


@dataclass
class Route:
    method: str
    pattern: str
    handler: Handler
    authenticated: bool = True
    description: str = ""
    _regex: re.Pattern[str] = field(init=False, repr=False)

    def __post_init__(self) -> None:
        expression = re.sub(r"\{([a-zA-Z_][a-zA-Z0-9_]*)\}", r"(?P<\1>[^/]+)", self.pattern)
        self._regex = re.compile(f"^{expression}$")

    def match(self, method: str, path: str) -> dict[str, str] | None:
        if method != self.method:
            return None
        found = self._regex.match(path)
        return found.groupdict() if found else None


class Router:
    def __init__(self, prefix: str = "") -> None:
        self.prefix = prefix
        self.routes: list[Route] = []

    def route(self, method: str, pattern: str, authenticated: bool = True, description: str = "") -> Callable[[Handler], Handler]:
        def decorator(handler: Handler) -> Handler:
            self.routes.append(Route(method.upper(), self.prefix + pattern, handler,
                                     authenticated=authenticated, description=description))
            return handler
        return decorator

    def get(self, pattern: str, **kwargs: Any) -> Callable[[Handler], Handler]:
        return self.route("GET", pattern, **kwargs)

    def post(self, pattern: str, **kwargs: Any) -> Callable[[Handler], Handler]:
        return self.route("POST", pattern, **kwargs)

    def delete(self, pattern: str, **kwargs: Any) -> Callable[[Handler], Handler]:
        return self.route("DELETE", pattern, **kwargs)

    def resolve(self, method: str, path: str) -> tuple[Route | None, dict[str, str]]:
        for candidate in self.routes:
            params = candidate.match(method, path)
            if params is not None:
                return candidate, params
        return None, {}

    def allowed_methods(self, path: str) -> list[str]:
        return sorted({route.method for route in self.routes if route.match(route.method, path) is not None})


class Server:
    """Threading HTTP server that dispatches into a `Router` plus a policy layer."""

    def __init__(self, router: Router, policy: "RequestPolicy", host: str = "127.0.0.1", port: int = 8787) -> None:
        self.router = router
        self.policy = policy
        self.host = host
        self.port = port
        self._server: ThreadingHTTPServer | None = None
        self._thread: threading.Thread | None = None

    # -- request handling --------------------------------------------------
    def handle(self, request: Request) -> Response:
        try:
            self.policy.before(request)
        except JarvisBackendError as error:
            self.policy.record_failure(request, error)
            return self._with_cors(Response.json(error.payload(), status=error.status), request)

        route, params = self.router.resolve(request.method, request.path)
        if route is None:
            methods = self.router.allowed_methods(request.path)
            if methods:
                return self._with_cors(
                    Response.error(405, "method_not_allowed",
                                   f"{request.method} is not allowed on {request.path}",
                                   {"allowed": methods}), request)
            return self._with_cors(Response.error(404, "not_found", f"no route for {request.path}"), request)

        request.path_params = params
        try:
            if route.authenticated:
                self.policy.authenticate(request)
            self.policy.check_rate_limit(request)
            response = route.handler(request)
            if not isinstance(response, Response):  # defensive: handlers must return Response
                raise JarvisBackendError("handler returned an unexpected type")
        except JarvisBackendError as error:
            self.policy.record_failure(request, error)
            response = Response.json(error.payload(), status=error.status)
        except Exception as error:  # noqa: BLE001 - never leak a traceback to a client
            self.policy.record_failure(request, error)
            response = Response.error(500, "internal_error", "the backend failed to handle the request")
        return self._with_cors(response, request)

    def _with_cors(self, response: Response, request: Request) -> Response:
        origin = request.header("origin")
        allowed = self.policy.origin_allowed(origin)
        if origin and allowed:
            response.headers["Access-Control-Allow-Origin"] = origin
            response.headers["Vary"] = "Origin"
            response.headers["Access-Control-Allow-Headers"] = "authorization, content-type"
            response.headers["Access-Control-Allow-Methods"] = "GET, POST, DELETE, OPTIONS"
        response.headers.setdefault("X-Content-Type-Options", "nosniff")
        response.headers.setdefault("Referrer-Policy", "no-referrer")
        response.headers.setdefault("Cache-Control", "no-store")
        return response

    # -- lifecycle ---------------------------------------------------------
    def make_handler(self) -> type[BaseHTTPRequestHandler]:
        server = self

        class Handler(BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"
            server_version = "jarvis-backend"

            def log_message(self, fmt: str, *args: Any) -> None:  # pragma: no cover - noisy
                if server.policy.log_requests:
                    server.policy.log(f"{self.address_string()} {fmt % args}")

            def _to_request(self) -> Request:
                parsed = urlparse(self.path)
                length = int(self.headers.get("content-length") or 0)
                if length > server.policy.max_request_bytes:
                    raise BadRequest(f"request body exceeds {server.policy.max_request_bytes} bytes")
                body = self.rfile.read(length) if length else b""
                headers = {key.lower(): value for key, value in self.headers.items()}
                return Request(method=self.command.upper(),
                               path=parsed.path,
                               query=parse_qs(parsed.query),
                               headers=headers,
                               body=body,
                               remote=self.client_address[0])

            def _respond(self) -> None:
                if self.command == "OPTIONS":
                    response = server._with_cors(Response.empty(204), self._to_request())
                else:
                    response = server.handle(self._to_request())
                self.send_response(response.status)
                self.send_header("Content-Type", response.content_type)
                self.send_header("Content-Length", str(len(response.body)))
                for key, value in response.headers.items():
                    self.send_header(key, value)
                self.end_headers()
                if response.body:
                    self.wfile.write(response.body)

            do_GET = do_POST = do_DELETE = do_PUT = do_PATCH = _respond  # type: ignore[assignment]

        return Handler

    def start(self) -> None:
        self._server = ThreadingHTTPServer((self.host, self.port), self.make_handler())
        self._server.daemon_threads = True
        self.port = self._server.server_address[1]
        self._thread = threading.Thread(target=self._server.serve_forever, name="jarvis-http", daemon=True)
        self._thread.start()

    def stop(self) -> None:
        if self._server is not None:
            self._server.shutdown()
            self._server.server_close()
        if self._thread is not None:
            self._thread.join(timeout=5)
        self._server = None
        self._thread = None
