"""Tool registry and executor.

The rule that matters: a language model may *propose* a tool call, and this
module decides whether it happens. Validation, authorization, confirmation and
auditing all live here — never in the provider adapter, and never in the client.
"""

from __future__ import annotations

import time
from dataclasses import dataclass, field
from typing import Any, Callable, Iterable

from .errors import BadRequest, Forbidden, JarvisBackendError, NotFound
from .security import AuditLog, RequestPolicy, redact

MAX_STRING_ARRAY = 50


@dataclass
class ToolParameter:
    name: str
    type: str = "string"                      # string | number | integer | boolean | stringArray
    required: bool = False
    description: str = ""
    minimum: float | None = None
    maximum: float | None = None
    allowed: list[str] = field(default_factory=list)
    default: Any = None

    def json_schema(self) -> dict[str, Any]:
        schema: dict[str, Any] = {"type": "array" if self.type == "stringArray" else self.type,
                                 "description": self.description}
        if self.type == "stringArray":
            schema = {"type": "array", "items": {"type": "string"}, "description": self.description}
        if self.minimum is not None:
            schema["minimum"] = self.minimum
        if self.maximum is not None:
            schema["maximum"] = self.maximum
        if self.allowed:
            schema["enum"] = self.allowed
        return schema


@dataclass
class ToolDefinition:
    name: str
    summary: str
    risk: str = "safe"                        # safe | modifying | communicating | irreversible
    parameters: list[ToolParameter] = field(default_factory=list)
    required_scopes: list[str] = field(default_factory=list)
    timeout_seconds: float = 20.0
    confirmation_prompt: str = ""
    environment: str = "server"               # server | on-device

    def schema(self) -> dict[str, Any]:
        return {
            "name": self.name,
            "description": self.summary,
            "parameters": {
                "type": "object",
                "properties": {parameter.name: parameter.json_schema() for parameter in self.parameters},
                "required": [parameter.name for parameter in self.parameters if parameter.required],
                "additionalProperties": False,
            },
        }

    def catalogue_entry(self) -> dict[str, Any]:
        return {
            "name": self.name,
            "summary": self.summary,
            "risk": self.risk,
            "requiredScopes": self.required_scopes,
            "confirmationPrompt": self.confirmation_prompt,
            "environment": self.environment,
        }


ToolFunction = Callable[[dict[str, Any], "ToolContext"], dict[str, Any]]


@dataclass
class ToolContext:
    """Everything a tool may touch. Tools never reach outside this."""
    settings: Any
    memory: Any = None
    transport: Any = None
    scheduler: Any = None
    integrations: Any = None
    actor: str = "unknown"
    user_approved: bool = False


@dataclass
class ToolResult:
    tool: str
    success: bool
    summary: str
    data: dict[str, Any] = field(default_factory=dict)
    verified: bool = False
    duration: float = 0.0


class ToolRegistry:
    def __init__(self) -> None:
        self._tools: dict[str, tuple[ToolDefinition, ToolFunction]] = {}

    def register(self, definition: ToolDefinition, function: ToolFunction) -> None:
        if definition.name in self._tools:
            raise ValueError(f"tool '{definition.name}' is already registered")
        self._tools[definition.name] = (definition, function)

    def definition(self, name: str) -> ToolDefinition:
        if name not in self._tools:
            raise NotFound(f"no tool named '{name}'")
        return self._tools[name][0]

    def catalogue(self) -> list[dict[str, Any]]:
        return [definition.catalogue_entry() for definition, _ in self._tools.values()]

    def provider_schemas(self, *, environment: str | None = "server") -> list[dict[str, Any]]:
        return [definition.schema() for definition, _ in self._tools.values()
                if environment is None or definition.environment == environment]

    def names(self) -> list[str]:
        return sorted(self._tools)


class ToolExecutor:
    def __init__(self, registry: ToolRegistry, policy: RequestPolicy, audit: AuditLog) -> None:
        self.registry = registry
        self.policy = policy
        self.audit = audit

    # -- validation --------------------------------------------------------
    @staticmethod
    def validate(arguments: dict[str, Any], definition: ToolDefinition) -> dict[str, Any]:
        if not isinstance(arguments, dict):
            raise BadRequest("tool arguments must be an object")
        known = {parameter.name for parameter in definition.parameters}
        unknown = sorted(set(arguments) - known)
        if unknown:
            raise BadRequest(f"unknown argument(s) for {definition.name}: {', '.join(unknown)}")
        validated: dict[str, Any] = {}
        for parameter in definition.parameters:
            if parameter.name not in arguments or arguments[parameter.name] is None:
                if parameter.required:
                    raise BadRequest(f"{definition.name} requires '{parameter.name}'")
                if parameter.default is not None:
                    validated[parameter.name] = parameter.default
                continue
            value = arguments[parameter.name]
            validated[parameter.name] = _coerce(value, parameter, definition.name)
        return validated

    # -- execution ---------------------------------------------------------
    def execute(self, name: str, arguments: dict[str, Any], context: ToolContext,
                *, scopes: Iterable[str] = (), user_approved: bool = False) -> ToolResult:
        definition, function = self.registry._tools.get(name, (None, None))  # noqa: SLF001 - registry owns its table
        if definition is None or function is None:
            raise NotFound(f"no tool named '{name}'")

        validated = self.validate(arguments, definition)
        try:
            self.policy.authorize_tool(name, definition.risk, user_approved=user_approved,
                                       scopes=scopes, required_scopes=definition.required_scopes)
        except (Forbidden,) as error:
            self.audit.record(actor=context.actor, action="tool.execute", target=name,
                              risk=definition.risk, outcome="forbidden", detail={"reason": error.message})
            raise

        context.user_approved = user_approved
        started = time.monotonic()
        try:
            data = function(validated, context) or {}
            duration = time.monotonic() - started
            summary = str(data.get("summary") or f"{name} completed")
            verified = bool(data.get("verified", False))
            self.audit.record(actor=context.actor, action="tool.execute", target=name, risk=definition.risk,
                              outcome="succeeded", detail={"arguments": redact(validated), "summary": summary,
                                                           "duration": round(duration, 3)})
            return ToolResult(tool=name, success=True, summary=summary, data=data, verified=verified, duration=duration)
        except JarvisBackendError as error:
            # Configuration and policy problems keep their own status code (503 for
            # "not configured", 403 for policy) so the client can act on them.
            duration = time.monotonic() - started
            self.audit.record(actor=context.actor, action="tool.execute", target=name, risk=definition.risk,
                              outcome="failed", detail={"arguments": redact(validated),
                                                        "error": redact(str(error)), "code": error.code})
            raise
        except Exception as error:  # noqa: BLE001 - reported, audited, wrapped with context
            duration = time.monotonic() - started
            self.audit.record(actor=context.actor, action="tool.execute", target=name, risk=definition.risk,
                              outcome="failed", detail={"arguments": redact(validated), "error": redact(str(error))})
            raise BadRequest(f"{name} failed: {error}") from error


def _coerce(value: Any, parameter: ToolParameter, tool: str) -> Any:
    """Reject anything that is not exactly what the schema promised."""
    if parameter.type == "string":
        if not isinstance(value, str):
            raise BadRequest(f"{tool}.{parameter.name} must be a string")
        if len(value) > 8000:
            raise BadRequest(f"{tool}.{parameter.name} is too long")
        if parameter.allowed and value not in parameter.allowed:
            raise BadRequest(f"{tool}.{parameter.name} must be one of {', '.join(parameter.allowed)}")
        return value
    if parameter.type in {"number", "integer"}:
        if isinstance(value, bool) or not isinstance(value, (int, float)):
            raise BadRequest(f"{tool}.{parameter.name} must be a number")
        number = int(value) if parameter.type == "integer" else float(value)
        if parameter.minimum is not None and number < parameter.minimum:
            raise BadRequest(f"{tool}.{parameter.name} must be ≥ {parameter.minimum}")
        if parameter.maximum is not None and number > parameter.maximum:
            raise BadRequest(f"{tool}.{parameter.name} must be ≤ {parameter.maximum}")
        return number
    if parameter.type == "boolean":
        if not isinstance(value, bool):
            raise BadRequest(f"{tool}.{parameter.name} must be true or false")
        return value
    if parameter.type == "stringArray":
        if not isinstance(value, list) or not all(isinstance(item, str) for item in value):
            raise BadRequest(f"{tool}.{parameter.name} must be a list of strings")
        if len(value) > MAX_STRING_ARRAY:
            raise BadRequest(f"{tool}.{parameter.name} accepts at most {MAX_STRING_ARRAY} items")
        return value
    raise BadRequest(f"{tool}.{parameter.name} has an unsupported type")


# --------------------------------------------------------------- built-ins ----
def register_builtin_tools(registry: ToolRegistry) -> None:
    """Server-side tools. Gmail/WhatsApp/Instagram live in integrations.py."""

    def now_tool(_arguments: dict[str, Any], _context: ToolContext) -> dict[str, Any]:
        import datetime

        stamp = datetime.datetime.now(datetime.timezone.utc).isoformat()
        return {"summary": f"The server clock reads {stamp}", "utc": stamp, "verified": True}

    registry.register(
        ToolDefinition(name="time.now", summary="Current UTC time on the server", risk="safe"),
        now_tool,
    )

    def memory_remember(arguments: dict[str, Any], context: ToolContext) -> dict[str, Any]:
        from .memory import MemoryRecord

        if context.memory is None:
            raise RuntimeError("memory is not configured on this server")
        record = MemoryRecord.from_payload({"kind": arguments.get("kind", "fact"),
                                            "text": arguments["text"],
                                            "source": "assistant" if context.actor == "model" else "user"})
        context.memory.add(record)
        return {"summary": f"Remembered ({record.kind}): {record.text}", "id": record.id, "verified": True}

    registry.register(
        ToolDefinition(
            name="memory.remember",
            summary="Store a durable memory record",
            risk="modifying",
            parameters=[
                ToolParameter("text", required=True, description="The fact, preference or instruction to remember"),
                ToolParameter("kind", allowed=["fact", "preference", "goal", "instruction", "importantDate", "decision", "task"],
                              default="fact", description="Category of the record"),
            ],
            confirmation_prompt="Store this in JARVIS memory?",
        ),
        memory_remember,
    )

    def memory_search(arguments: dict[str, Any], context: ToolContext) -> dict[str, Any]:
        if context.memory is None:
            raise RuntimeError("memory is not configured on this server")
        hits = context.memory.search(arguments["query"], limit=int(arguments.get("limit", 8)))
        return {
            "summary": f"{len(hits)} memory record(s) matched “{arguments['query']}”",
            "records": [{"id": record.id, "kind": record.kind, "text": record.text, "score": score}
                        for record, score in hits],
            "verified": True,
        }

    registry.register(
        ToolDefinition(
            name="memory.search",
            summary="Search durable memory",
            risk="safe",
            parameters=[ToolParameter("query", required=True),
                        ToolParameter("limit", type="integer", minimum=1, maximum=25, default=8)],
        ),
        memory_search,
    )

    def memory_forget(arguments: dict[str, Any], context: ToolContext) -> dict[str, Any]:
        if context.memory is None:
            raise RuntimeError("memory is not configured on this server")
        removed = context.memory.forget(arguments["id"])
        if not removed:
            raise RuntimeError(f"no memory with id {arguments['id']}")
        return {"summary": f"Forgot memory {arguments['id']}", "verified": True}

    registry.register(
        ToolDefinition(
            name="memory.forget",
            summary="Delete a memory record permanently",
            risk="irreversible",
            parameters=[ToolParameter("id", required=True)],
            confirmation_prompt="Delete this memory permanently?",
        ),
        memory_forget,
    )

    def reminder_schedule(arguments: dict[str, Any], context: ToolContext) -> dict[str, Any]:
        if context.scheduler is None:
            raise RuntimeError("the scheduler is not configured on this server")
        reminder = context.scheduler.schedule(title=arguments["title"],
                                             due_at=float(arguments["due_at"]),
                                             recurrence=arguments.get("recurrence"))
        return {"summary": f"Scheduled “{reminder['title']}” for {reminder['dueAt']}", "id": reminder["id"], "verified": True}

    registry.register(
        ToolDefinition(
            name="reminder.schedule",
            summary="Schedule a server-side reminder (used when the phone is asleep)",
            risk="modifying",
            parameters=[
                ToolParameter("title", required=True),
                ToolParameter("due_at", type="number", required=True, description="Unix timestamp (UTC)"),
                ToolParameter("recurrence", allowed=["", "daily", "weekly", "monthly"], default=""),
            ],
            confirmation_prompt="Schedule this reminder on the server?",
        ),
        reminder_schedule,
    )

    def reminder_list(_arguments: dict[str, Any], context: ToolContext) -> dict[str, Any]:
        if context.scheduler is None:
            raise RuntimeError("the scheduler is not configured on this server")
        reminders = context.scheduler.upcoming(limit=20)
        return {"summary": f"{len(reminders)} upcoming server reminder(s)", "reminders": reminders, "verified": True}

    registry.register(
        ToolDefinition(name="reminder.list", summary="List upcoming server-side reminders", risk="safe"),
        reminder_list,
    )

    def web_search(arguments: dict[str, Any], context: ToolContext) -> dict[str, Any]:
        if context.integrations is None:
            raise RuntimeError("integrations are not configured on this server")
        results = context.integrations.web_search(arguments["query"], limit=int(arguments.get("limit", 5)))
        return {"summary": f"{len(results)} web result(s) for “{arguments['query']}”",
                "results": results, "verified": True, "untrusted": True}

    registry.register(
        ToolDefinition(
            name="web.search",
            summary="Search the web through your own search API key",
            risk="safe",
            parameters=[ToolParameter("query", required=True),
                        ToolParameter("limit", type="integer", minimum=1, maximum=10, default=5)],
        ),
        web_search,
    )

    def github_issues(arguments: dict[str, Any], context: ToolContext) -> dict[str, Any]:
        if context.integrations is None:
            raise RuntimeError("integrations are not configured on this server")
        issues = context.integrations.github_issues(arguments["repository"], state=arguments.get("state", "open"))
        return {"summary": f"{len(issues)} {arguments.get('state', 'open')} issue(s) in {arguments['repository']}",
                "issues": issues, "verified": True}

    registry.register(
        ToolDefinition(
            name="github.list_issues",
            summary="List issues in a repository (owner/name)",
            risk="safe",
            parameters=[ToolParameter("repository", required=True),
                        ToolParameter("state", allowed=["open", "closed", "all"], default="open")],
            required_scopes=["github"],
        ),
        github_issues,
    )

    def whatsapp_send(arguments: dict[str, Any], context: ToolContext) -> dict[str, Any]:
        if context.integrations is None:
            raise RuntimeError("integrations are not configured on this server")
        result = context.integrations.whatsapp_send(arguments["to"], arguments["text"])
        return {"summary": f"WhatsApp message accepted for {arguments['to']} (id {result.get('id', 'n/a')})",
                "provider": result, "verified": True}

    registry.register(
        ToolDefinition(
            name="whatsapp.send",
            summary="Send a WhatsApp message through the official Business Platform (template messages only)",
            risk="irreversible",
            parameters=[ToolParameter("to", required=True, description="E.164 phone number"),
                        ToolParameter("text", required=True, description="Message body")],
            required_scopes=["whatsapp"],
            confirmation_prompt="Send this WhatsApp message now? It cannot be unsent.",
            environment="server",
        ),
        whatsapp_send,
    )

    def instagram_profile(_arguments: dict[str, Any], context: ToolContext) -> dict[str, Any]:
        if context.integrations is None:
            raise RuntimeError("integrations are not configured on this server")
        profile = context.integrations.instagram_profile()
        return {"summary": f"Instagram profile for @{profile.get('username', 'unknown')}", "profile": profile, "verified": True}

    registry.register(
        ToolDefinition(
            name="instagram.profile",
            summary="Read the connected Instagram professional account's profile",
            risk="safe",
            required_scopes=["instagram"],
        ),
        instagram_profile,
    )

    def gmail_send(arguments: dict[str, Any], context: ToolContext) -> dict[str, Any]:
        if context.integrations is None:
            raise RuntimeError("integrations are not configured on this server")
        result = context.integrations.gmail_send(arguments["to"], arguments["subject"], arguments["body"])
        return {"summary": f"Gmail accepted the message for {arguments['to']}",
                "message": result, "verified": True}

    registry.register(
        ToolDefinition(
            name="gmail.send",
            summary="Send an email through Google's Gmail API with the connected account",
            risk="irreversible",
            parameters=[ToolParameter("to", required=True),
                        ToolParameter("subject", required=True),
                        ToolParameter("body", required=True)],
            required_scopes=["gmail"],
            confirmation_prompt="Send this email now? It cannot be unsent.",
        ),
        gmail_send,
    )
