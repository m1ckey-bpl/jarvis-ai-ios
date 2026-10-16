"""Memory persistence, correction chains, retention and retrieval behaviour."""

from __future__ import annotations

import json
import sqlite3

import pytest

from app.errors import BadRequest
from app.memory import KIND_WEIGHTS, MemoryRecord, MemoryStore, Migrator, SCHEMA_VERSIONS


@pytest.fixture
def store() -> MemoryStore:
    return MemoryStore(sqlite3.connect(":memory:"))


def record(**overrides) -> MemoryRecord:
    payload = {"kind": "fact", "text": "Lives in Shimla"}
    payload.update(overrides)
    return MemoryRecord.from_payload(payload)


def test_create_and_persist(store: MemoryStore) -> None:
    created = store.add(record())
    assert created.id
    assert store.count() == 1
    fetched = store.get(created.id)
    assert fetched is not None and fetched.text == "Lives in Shimla"
    assert fetched.kind == "fact"


def test_kind_and_source_validation(store: MemoryStore) -> None:
    with pytest.raises(BadRequest):
        store.add(record(kind="vibes"))
    with pytest.raises(BadRequest):
        store.add(record(source="guesswork"))
    with pytest.raises(BadRequest):
        store.add(record(text="   "))


def test_confidence_is_clamped_and_validated(store: MemoryStore) -> None:
    assert store.add(record(confidence=4.2, importance=-3)).confidence == 1.0
    assert store.all()[0].importance == 0.0
    with pytest.raises(BadRequest):
        store.add(record(confidence="high"))


def test_instructions_are_pinned(store: MemoryStore) -> None:
    store.add(record(kind="instruction", text="Always answer in English"))
    assert store.all()[0].locked is True
    hits = store.search("weather in a city nobody mentioned")
    assert [entry.kind for entry, _ in hits] == ["instruction"]


def test_correction_supersedes_and_keeps_history(store: MemoryStore) -> None:
    original = store.add(record())
    replacement = store.correct(original.id, "Lives in Dharamshala")
    assert store.get(original.id).status == "superseded"
    assert store.get(original.id).superseded_by == replacement.id
    assert store.get(replacement.id).kind == "correction"
    assert len(store.all(include_inactive=True)) == 2
    assert len(store.all()) == 1


def test_forget_marks_deleted_and_is_reported(store: MemoryStore) -> None:
    created = store.add(record())
    assert store.forget(created.id) is True
    assert store.forget("missing-id") is False
    assert store.count() == 0


def test_retention_expires_records(store: MemoryStore) -> None:
    store.add(record(kind="summary", text="Conversation summary", ttl_seconds=-1))
    assert store.expire() == 1
    assert store.count() == 0


def test_retrieval_ranks_relevant_first(store: MemoryStore) -> None:
    store.add(record(text="Lives in Shimla"))
    store.add(record(text="Prefers concise answers", kind="preference"))
    hits = store.search("shimla")
    assert hits and hits[0][0].text == "Lives in Shimla"
    assert hits[0][1] > (hits[1][1] if len(hits) > 1 else 0)


def test_retrieval_access_is_recorded(store: MemoryStore) -> None:
    created = store.add(record())
    store.search("shimla")
    assert store.get(created.id).access_count == 1
    assert store.get(created.id).last_accessed_at is not None


def test_strict_search_returns_nothing_for_unrelated_query(store: MemoryStore) -> None:
    store.add(record(text="Lives in Shimla"))
    assert store.search("what is the capital of Peru") == []


def test_context_fallback_surfaces_strong_records(store: MemoryStore) -> None:
    store.add(record(text="Lives in Shimla", importance=0.9))
    store.add(record(text="Dislikes long meetings", kind="preference", importance=0.8))
    hits = store.search("what do you know about me?", fallback=True)
    assert len(hits) == 2
    assert all(score > 0.3 for _, score in hits)


def test_kind_weights_put_instructions_first() -> None:
    assert KIND_WEIGHTS["instruction"] > KIND_WEIGHTS["fact"] > KIND_WEIGHTS["inference"]


def test_export_formats(store: MemoryStore) -> None:
    store.add(record())
    payload = json.loads(store.export("json"))
    assert payload[0]["text"] == "Lives in Shimla"
    assert "kind,text" in store.export("csv").splitlines()[0]
    assert store.export("markdown").startswith("# JARVIS memory export")
    with pytest.raises(BadRequest):
        store.export("xml")


def test_migrations_are_versioned_and_idempotent() -> None:
    connection = sqlite3.connect(":memory:")
    migrator = Migrator(connection, SCHEMA_VERSIONS)
    assert migrator.current_version == 0
    assert migrator.migrate() == [1, 2]
    assert migrator.current_version == 2
    assert migrator.migrate() == []          # nothing to do a second time
    rows = connection.execute("SELECT version FROM schema_version ORDER BY version").fetchall()
    assert [row[0] for row in rows] == [1, 2]


def test_migration_failure_is_reported_not_ignored() -> None:
    connection = sqlite3.connect(":memory:")
    broken = [(1, "CREATE TABLE ok (id TEXT);"), (2, "THIS IS NOT SQL;")]
    migrator = Migrator(connection, broken)
    with pytest.raises(RuntimeError) as error:
        migrator.migrate()
    assert "migration 2 failed" in str(error.value)
    assert migrator.current_version == 1      # the applied version is preserved
