"""Tool validation, authorization and auditing.

synthetic-credential-fixture: the key-shaped string below is fake and exists to prove
that tool arguments are redacted before they reach the audit log.
"""

from __future__ import annotations

import sqlite3

import pytest

from app.errors import BadRequest, ConfirmationRequired, Forbidden
from app.memory import MemoryStore
from app.security import AuditLog, RequestPolicy
from app.tools import ToolContext, ToolExecutor, ToolParameter, ToolDefinition, ToolRegistry, register_builtin_tools

TOKEN = "t" * 32


@pytest.fixture
def stack():
    connection = sqlite3.connect(":memory:")
    registry = ToolRegistry()
    register_builtin_tools(registry)
    policy = RequestPolicy(auth_token=TOKEN)
    audit = AuditLog(connection)
    executor = ToolExecutor(registry, policy, audit)
    memory = MemoryStore(connection)
    context = ToolContext(settings=None, memory=memory, actor="model")
    return registry, executor, audit, memory, context


def test_catalogue_exposes_risk_and_scopes(stack) -> None:
    registry, *_ = stack
    by_name = {entry["name"]: entry for entry in registry.catalogue()}
    assert by_name["time.now"]["risk"] == "safe"
    assert by_name["gmail.send"]["risk"] == "irreversible"
    assert by_name["github.list_issues"]["requiredScopes"] == ["github"]


def test_provider_schema_is_well_formed(stack) -> None:
    registry, *_ = stack
    schema = next(item for item in registry.provider_schemas() if item["name"] == "memory.remember")
    assert schema["parameters"]["type"] == "object"
    assert "text" in schema["parameters"]["required"]
    assert schema["parameters"]["properties"]["kind"]["enum"]


def test_unknown_argument_is_rejected(stack) -> None:
    _, executor, _, _, context = stack
    with pytest.raises(BadRequest) as error:
        executor.execute("time.now", {"timezone": "UTC"}, context)
    assert "unknown argument" in str(error.value)


def test_required_argument_is_enforced(stack) -> None:
    _, executor, _, _, context = stack
    with pytest.raises(BadRequest):
        executor.execute("memory.remember", {}, context)


def test_types_limits_and_enums_are_enforced(stack) -> None:
    _, executor, _, _, context = stack
    with pytest.raises(BadRequest):
        executor.execute("memory.search", {"query": "x", "limit": "many"}, context)
    with pytest.raises(BadRequest):
        executor.execute("memory.search", {"query": "x", "limit": 99}, context)
    with pytest.raises(BadRequest):
        executor.execute("memory.remember", {"text": "x", "kind": "rumour"}, context)


def test_safe_tool_runs_and_is_audited(stack) -> None:
    _, executor, audit, _, context = stack
    result = executor.execute("time.now", {}, context)
    assert result.success and result.verified
    entries = audit.recent()
    assert entries[0]["target"] == "time.now"
    assert entries[0]["outcome"] == "succeeded"


def test_scope_gate_blocks_unconfigured_integration(stack) -> None:
    _, executor, audit, _, context = stack
    with pytest.raises(Forbidden):
        executor.execute("github.list_issues", {"repository": "owner/name"}, context, scopes=set())
    assert audit.recent()[0]["outcome"] == "forbidden"


def test_irreversible_tool_requires_confirmation(stack) -> None:
    registry, executor, _, _, context = stack

    def fake_send(arguments, _context):
        return {"summary": "sent", "verified": True}

    registry.register(ToolDefinition(name="test.send", summary="test", risk="irreversible",
                                     confirmation_prompt="Send?"),
                      fake_send)
    with pytest.raises(ConfirmationRequired) as error:
        executor.execute("test.send", {}, context, user_approved=False)
    assert error.value.status == 409
    assert executor.execute("test.send", {}, context, user_approved=True).success


def test_memory_tools_round_trip(stack) -> None:
    _, executor, _, memory, context = stack
    stored = executor.execute("memory.remember", {"text": "Prefers tea", "kind": "preference"}, context)
    found = executor.execute("memory.search", {"query": "tea"}, context)
    assert len(found.data["records"]) == 1
    executor.execute("memory.forget", {"id": stored.data["id"]}, context, user_approved=True)
    assert memory.count() == 0


def test_tool_failure_is_reported_and_audited(stack) -> None:
    _, executor, audit, _, context = stack
    with pytest.raises(BadRequest) as error:
        executor.execute("memory.forget", {"id": "does-not-exist"}, context, user_approved=True)
    assert "failed" in str(error.value)
    assert audit.recent()[0]["outcome"] == "failed"


def test_arguments_are_redacted_in_the_audit_trail(stack) -> None:
    registry, executor, audit, _, context = stack

    def echo(arguments, _context):
        return {"summary": "ok", "verified": True}

    registry.register(ToolDefinition(name="test.echo", summary="echo",
                                     parameters=[ToolParameter("value", required=True)]), echo)
    executor.execute("test.echo", {"value": "gsk_abcdefghijklmnopqrstuvwxyz"}, context)
    assert "gsk_abcdefghijklmnopqrstuvwxyz" not in str(audit.recent()[0]["detail"])


def test_duplicate_registration_is_refused(stack) -> None:
    registry, *_ = stack
    with pytest.raises(ValueError):
        register_builtin_tools(registry)


def test_memory_tool_requires_memory_configured() -> None:
    registry = ToolRegistry()
    register_builtin_tools(registry)
    executor = ToolExecutor(registry, RequestPolicy(auth_token=TOKEN), AuditLog(sqlite3.connect(":memory:")))
    context = ToolContext(settings=None, memory=None, actor="model")
    with pytest.raises(BadRequest):
        executor.execute("memory.search", {"query": "x"}, context)
