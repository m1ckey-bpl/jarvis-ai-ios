"""HTTP surface of the companion backend.

Every route is thin: validation and authorization happen in `security`/`tools`,
state lives in `memory`/`scheduler`, and the response is JSON. The model-facing
route (`/v1/chat`) is just another client of those layers — it has no extra power.
"""

from __future__ import annotations

import sqlite3
import time
from typing import Any

from . import __version__ as version
from .agent import AgentOrchestrator, build_provider
from .config import Settings
from .errors import BadRequest, NotConfigured
from .http import Request, Response, Router, Server
from .integrations import CredentialStore, IntegrationHub, SecretBox
from .memory import MemoryRecord, MemoryStore
from .scheduler import DispatchLoop, ReminderScheduler
from .security import AuditLog, RequestPolicy, wrap_untrusted
from .tools import ToolContext, ToolExecutor, ToolRegistry, register_builtin_tools
from .transport import Transport, UrllibTransport

MAX_HISTORY_MESSAGES = 40


class Application:
    """Wires the pieces together and owns the process-wide objects."""

    def __init__(self, settings: Settings, *, transport: Transport | None = None,
                 connection: sqlite3.Connection | None = None) -> None:
        self.settings = settings
        self.started_at = time.time()
        self.transport = transport or UrllibTransport()
        if connection is not None:
            self.connection = connection
        else:
            settings.data_dir.mkdir(parents=True, exist_ok=True)
            self.connection = sqlite3.connect(settings.database_path, check_same_thread=False)
            self.connection.execute("PRAGMA journal_mode=WAL")
            self.connection.execute("PRAGMA foreign_keys=ON")

        self.audit = AuditLog(self.connection)
        self.memory = MemoryStore(self.connection)
        self.scheduler = ReminderScheduler(self.connection, self.audit)
        self.credentials = CredentialStore(self.connection, SecretBox(settings.auth_token or "local-development-key"))
        self.integrations = IntegrationHub(settings, self.transport, self.credentials)

        self.registry = ToolRegistry()
        register_builtin_tools(self.registry)
        self.policy = RequestPolicy(
            auth_token=settings.auth_token,
            rate_limit_per_minute=settings.rate_limit_per_minute,
            max_request_bytes=settings.max_request_bytes,
            allowed_origins=settings.allowed_origins,
        )
        self.executor = ToolExecutor(self.registry, self.policy, self.audit)
        self.dispatch = DispatchLoop(self.scheduler, self.transport, settings.dispatch_webhook)
        self.router = Router()
        self._register_routes()
        self.server = Server(self.router, self.policy, host=settings.host, port=settings.port)

    # -- lifecycle ---------------------------------------------------------
    def start(self) -> None:
        self.server.start()

    def stop(self) -> None:
        self.server.stop()

    def handle(self, request: Request) -> Response:
        """In-process dispatch (used by tests and by `main --check`)."""
        return self.server.handle(request)

    @property
    def uptime(self) -> float:
        return time.time() - self.started_at

    def context(self, actor: str) -> ToolContext:
        return ToolContext(settings=self.settings, memory=self.memory, transport=self.transport,
                           scheduler=self.scheduler, integrations=self.integrations, actor=actor)

    # -- helpers -----------------------------------------------------------
    def _scopes(self, request: Request) -> set[str]:
        """Which integration scopes a caller may use.

        Derived from the server's own configuration, never from the request body:
        a client cannot grant itself access to an integration by asking for it.
        """
        scopes: set[str] = set()
        if self.settings.github_token:
            scopes.add("github")
        if self.settings.google_client_id or self.credentials.get("google.refresh_token"):
            scopes.add("gmail")
        if self.settings.whatsapp_token:
            scopes.add("whatsapp")
        if self.settings.instagram_token:
            scopes.add("instagram")
        return scopes

    # -- routes ------------------------------------------------------------
    def _register_routes(self) -> None:
        router = self.router

        @router.get("/health", authenticated=False, description="liveness and configuration report")
        def health(request: Request) -> Response:
            return Response.json({
                "status": "ok",
                "version": version,
                "uptimeSeconds": round(self.uptime, 1),
                "authRequired": self.policy.configured,
                "memoryRecords": self.memory.count(),
                "capabilities": self.integrations.capability_report(),
                "clock": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            })

        # ---- memory ------------------------------------------------------
        @router.get("/v1/memory", description="list or search memory")
        def list_memory(request: Request) -> Response:
            query = request.param("query")
            limit = min(50, max(1, int(request.param("limit", "25") or 25)))
            if query:
                hits = self.memory.search(query, limit=limit)
                return Response.json({"query": query,
                                      "records": [{**record.to_dict(), "score": score} for record, score in hits]})
            records = self.memory.all()
            return Response.json({"count": len(records), "records": [record.to_dict() for record in records[:limit]]})

        @router.post("/v1/memory", description="store a memory record")
        def create_memory(request: Request) -> Response:
            payload = request.json()
            record = MemoryRecord.from_payload(payload)
            self.audit.record(actor="api", action="memory.create", target=record.id, outcome="succeeded",
                              detail={"kind": record.kind})
            return Response.json({"record": self.memory.add(record).to_dict()}, status=201)

        @router.post("/v1/memory/{record_id}/correct", description="correct a memory record")
        def correct_memory(request: Request) -> Response:
            payload = request.json()
            text = str(payload.get("text", "")).strip()
            if not text:
                raise BadRequest("a replacement text is required")
            replacement = self.memory.correct(request.path_params["record_id"], text)
            self.audit.record(actor="api", action="memory.correct", target=replacement.id, outcome="succeeded")
            return Response.json({"record": replacement.to_dict()})

        @router.delete("/v1/memory/{record_id}", description="forget a memory record")
        def delete_memory(request: Request) -> Response:
            removed = self.memory.forget(request.path_params["record_id"])
            if not removed:
                raise BadRequest(f"no memory with id {request.path_params['record_id']}")
            self.audit.record(actor="api", action="memory.forget", target=request.path_params["record_id"],
                              outcome="succeeded")
            return Response.json({"forgotten": True})

        @router.get("/v1/memory/export", description="export memory as json, csv or markdown")
        def export_memory(request: Request) -> Response:
            fmt = request.param("format", "json") or "json"
            body = self.memory.export(fmt)
            content_type = {"json": "application/json; charset=utf-8",
                            "csv": "text/csv; charset=utf-8",
                            "markdown": "text/markdown; charset=utf-8"}[fmt]
            return Response.text(body, content_type=content_type)

        # ---- chat --------------------------------------------------------
        @router.post("/v1/chat", description="provider-proxied completion with tool authorization")
        def chat(request: Request) -> Response:
            payload = request.json()
            text = str(payload.get("text", "")).strip()
            if not text:
                raise BadRequest("a non-empty 'text' field is required")
            if len(text) > 8000:
                raise BadRequest("the message is longer than 8000 characters")
            history = self._history(payload.get("history"))
            approved = {str(name) for name in payload.get("approvedTools", [])}
            provider = build_provider(self.settings, self.transport)
            orchestrator = AgentOrchestrator(provider, self.executor, self.context(actor="model"),
                                             allow_tools=bool(payload.get("allowTools", True)))
            run = orchestrator.run(text, history=history, approved_tools=approved, scopes=self._scopes(request))
            self.audit.record(actor="api", action="chat.complete", outcome="succeeded",
                              detail={"provider": run.provider, "iterations": run.iterations,
                                      "tools": [entry["tool"] for entry in run.tool_results]})
            return Response.json({
                "text": run.text,
                "provider": run.provider,
                "model": run.model,
                "iterations": run.iterations,
                "usage": run.usage,
                "toolResults": run.tool_results,
                "usedMemories": run.used_memories,
            })

        @router.post("/v1/chat/untrusted", description="wrap external text as untrusted data")
        def wrap(request: Request) -> Response:
            payload = request.json()
            text = str(payload.get("text", ""))
            if not text:
                raise BadRequest("a non-empty 'text' field is required")
            label = str(payload.get("label", "external"))
            from .security import scan_for_injection

            return Response.json({"wrapped": wrap_untrusted(text, label),
                                  "findings": [finding.__dict__ for finding in scan_for_injection(text)]})

        # ---- tools -------------------------------------------------------
        @router.get("/v1/tools", description="tool catalogue with risk and scopes")
        def tools(request: Request) -> Response:
            return Response.json({
                "tools": self.registry.catalogue(),
                "policy": {
                    "confirmationThreshold": self.policy.confirmation_threshold,
                    "scopes": sorted(self._scopes(request)),
                },
            })

        @router.post("/v1/tools/{name}", description="execute a tool after server-side authorization")
        def run_tool(request: Request) -> Response:
            payload = request.json()
            arguments = payload.get("arguments") or {}
            approved = bool(payload.get("userApproved", False))
            result = self.executor.execute(request.path_params["name"], arguments, self.context(actor="api"),
                                           scopes=self._scopes(request), user_approved=approved)
            return Response.json({"tool": result.tool, "success": result.success, "summary": result.summary,
                                  "data": result.data, "verified": result.verified,
                                  "durationSeconds": round(result.duration, 3)})

        # ---- reminders ---------------------------------------------------
        @router.get("/v1/reminders", description="upcoming server-side reminders")
        def upcoming(request: Request) -> Response:
            return Response.json({"reminders": self.scheduler.upcoming(limit=50)})

        @router.post("/v1/reminders", description="schedule a server-side reminder")
        def create_reminder(request: Request) -> Response:
            payload = request.json()
            if "due_at" not in payload:
                raise BadRequest("'due_at' (unix timestamp, UTC) is required")
            reminder = self.scheduler.schedule(title=str(payload.get("title", "")),
                                               due_at=float(payload["due_at"]),
                                               recurrence=payload.get("recurrence"))
            self.audit.record(actor="api", action="reminder.create", target=reminder["id"], outcome="succeeded")
            return Response.json({"reminder": reminder}, status=201)

        @router.post("/v1/reminders/{reminder_id}/complete", description="complete or roll a reminder forward")
        def complete_reminder(request: Request) -> Response:
            return Response.json({"reminder": self.scheduler.complete(request.path_params["reminder_id"])})

        @router.delete("/v1/reminders/{reminder_id}", description="cancel a reminder")
        def cancel_reminder(request: Request) -> Response:
            if not self.scheduler.cancel(request.path_params["reminder_id"]):
                raise BadRequest(f"no reminder with id {request.path_params['reminder_id']}")
            return Response.json({"cancelled": True})

        @router.get("/v1/reminders/due", description="reminders due in a window (for device polling)")
        def due(request: Request) -> Response:
            since = float(request.param("since", str(time.time() - 3600)) or (time.time() - 3600))
            return Response.json({"since": since, "reminders": self.scheduler.due(since=since)})

        @router.post("/v1/reminders/dispatch", description="deliver due reminders through the configured webhook")
        def dispatch(request: Request) -> Response:
            if not self.settings.dispatch_webhook:
                raise NotConfigured(
                    "no dispatch target is configured. Set JARVIS_DISPATCH_WEBHOOK to your own endpoint, "
                    "or poll /v1/reminders/due from the app."
                )
            results = self.dispatch.tick()
            return Response.json({"dispatched": len(results), "results": results})

        # ---- integrations ------------------------------------------------
        @router.get("/v1/integrations", description="integration configuration report (no secrets)")
        def integrations(request: Request) -> Response:
            return Response.json({"capabilities": self.integrations.capability_report(),
                                  "scopes": sorted(self._scopes(request)),
                                  "credentials": self.credentials.names()})

        @router.get("/v1/integrations/oauth/google/start", description="begin Google OAuth with PKCE")
        def oauth_start(request: Request) -> Response:
            scopes = request.param("scopes")
            requested = [item for item in (scopes or "").split(",") if item] or None
            return Response.json(self.integrations.google.start(requested))

        @router.post("/v1/integrations/oauth/google/callback", description="complete Google OAuth")
        def oauth_callback(request: Request) -> Response:
            payload = request.json()
            if not payload.get("code") or not payload.get("state"):
                raise BadRequest("both 'code' and 'state' are required")
            result = self.integrations.google.callback(str(payload["code"]), str(payload["state"]))
            self.audit.record(actor="api", action="integration.google.connect", outcome="succeeded",
                              detail={"scopes": result.get("scopes")})
            return Response.json(result)

        @router.post("/v1/integrations/whatsapp/send", description="send through WhatsApp Business Platform")
        def whatsapp(request: Request) -> Response:
            payload = request.json()
            arguments = {"to": str(payload.get("to", "")), "text": str(payload.get("text", ""))}
            result = self.executor.execute("whatsapp.send", arguments, self.context(actor="api"),
                                           scopes=self._scopes(request),
                                           user_approved=bool(payload.get("userApproved", False)))
            return Response.json({"result": result.data, "summary": result.summary, "verified": result.verified})

        @router.get("/v1/integrations/instagram/profile", description="Instagram professional-account profile")
        def instagram(request: Request) -> Response:
            result = self.executor.execute("instagram.profile", {}, self.context(actor="api"),
                                           scopes=self._scopes(request), user_approved=True)
            return Response.json({"profile": result.data.get("profile", {}), "summary": result.summary})

        @router.post("/v1/integrations/search", description="web search through your own key")
        def search(request: Request) -> Response:
            payload = request.json()
            result = self.executor.execute("web.search", {"query": str(payload.get("query", ""))},
                                           self.context(actor="api"), scopes=self._scopes(request))
            return Response.json({"results": result.data.get("results", []), "summary": result.summary})

        @router.post("/v1/integrations/gmail/send", description="send mail through the connected Google account")
        def gmail_send(request: Request) -> Response:
            payload = request.json()
            result = self.executor.execute("gmail.send",
                                           {"to": str(payload.get("to", "")), "subject": str(payload.get("subject", "")),
                                            "body": str(payload.get("body", ""))},
                                           self.context(actor="api"), scopes=self._scopes(request),
                                           user_approved=bool(payload.get("userApproved", False)))
            return Response.json({"message": result.data.get("message", {}), "summary": result.summary,
                                  "verified": result.verified})

        # ---- admin -------------------------------------------------------
        @router.get("/v1/admin/audit", description="recent audit entries")
        def audit(request: Request) -> Response:
            limit = min(500, max(1, int(request.param("limit", "100") or 100)))
            return Response.json({"entries": self.audit.recent(limit),
                                  "rejectedRequests": self.policy.failures[-limit:]})

    def _history(self, raw: Any) -> list[Any]:
        from .agent import ChatMessage

        if not raw:
            return []
        if not isinstance(raw, list):
            raise BadRequest("'history' must be a list of {role, content} objects")
        history: list[Any] = []
        for item in raw[-MAX_HISTORY_MESSAGES:]:
            if not isinstance(item, dict) or "role" not in item or "content" not in item:
                raise BadRequest("each history entry needs 'role' and 'content'")
            role = str(item["role"])
            if role not in {"user", "assistant"}:
                raise BadRequest("history roles must be 'user' or 'assistant'")
            history.append(ChatMessage(role=role, content=str(item["content"])[:8000]))
        return history
