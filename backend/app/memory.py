"""Server-side memory store.

Mirrors the on-device model so that a record can move between phone and server
without loss: the same kinds, the same confidence/importance fields, the same
retention rules, and the same "explicit instructions outrank inferences" rule.
"""

from __future__ import annotations

import json
import sqlite3
import time
import uuid
from dataclasses import asdict, dataclass, field
from typing import Any

from .errors import BadRequest

KINDS = (
    "fact", "preference", "goal", "importantDate", "decision", "task",
    "instruction", "inference", "correction", "summary",
)
KIND_WEIGHTS = {
    "instruction": 1.00, "correction": 0.95, "fact": 0.85, "decision": 0.85,
    "importantDate": 0.82, "preference": 0.80, "goal": 0.75, "task": 0.70,
    "summary": 0.45, "inference": 0.35,
}
STATUSES = ("active", "superseded", "expired", "deleted")
SOURCES = ("user", "assistant", "importedExternal", "system")


@dataclass
class MemoryRecord:
    id: str = field(default_factory=lambda: str(uuid.uuid4()))
    kind: str = "fact"
    text: str = ""
    subject: str | None = None
    tags: list[str] = field(default_factory=list)
    source: str = "user"
    confidence: float = 0.9
    importance: float = 0.5
    created_at: float = field(default_factory=time.time)
    updated_at: float = field(default_factory=time.time)
    last_accessed_at: float | None = None
    access_count: int = 0
    expires_at: float | None = None
    status: str = "active"
    superseded_by: str | None = None
    locked: bool = False

    @classmethod
    def from_payload(cls, payload: dict[str, Any]) -> "MemoryRecord":
        text = str(payload.get("text", "")).strip()
        if not text:
            raise BadRequest("memory text is required")
        kind = str(payload.get("kind", "fact"))
        if kind not in KINDS:
            raise BadRequest(f"unknown memory kind '{kind}'; expected one of {', '.join(KINDS)}")
        source = str(payload.get("source", "user"))
        if source not in SOURCES:
            raise BadRequest(f"unknown memory source '{source}'")
        record = cls(kind=kind, text=text[:4000], source=source)
        record.subject = payload.get("subject")
        record.tags = [str(tag)[:64] for tag in payload.get("tags", [])][:20]
        record.confidence = _clamp(payload.get("confidence", 0.9))
        record.importance = _clamp(payload.get("importance", 0.5))
        record.locked = kind == "instruction" or bool(payload.get("locked", False))
        ttl = payload.get("ttl_seconds")
        if ttl is not None:
            record.expires_at = time.time() + float(ttl)
        return record

    def to_dict(self) -> dict[str, Any]:
        payload = asdict(self)
        payload["kindWeight"] = KIND_WEIGHTS.get(self.kind, 0.5)
        return payload


def _clamp(value: Any, low: float = 0.0, high: float = 1.0) -> float:
    try:
        number = float(value)
    except (TypeError, ValueError) as error:
        raise BadRequest(f"expected a number between {low} and {high}") from error
    return max(low, min(high, number))


SCHEMA_VERSIONS: list[tuple[int, str]] = [
    (1, """
        CREATE TABLE IF NOT EXISTS memory (
            id TEXT PRIMARY KEY,
            kind TEXT NOT NULL,
            text TEXT NOT NULL,
            subject TEXT,
            tags TEXT NOT NULL DEFAULT '[]',
            source TEXT NOT NULL,
            confidence REAL NOT NULL,
            importance REAL NOT NULL,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL,
            last_accessed_at REAL,
            access_count INTEGER NOT NULL DEFAULT 0,
            expires_at REAL,
            status TEXT NOT NULL DEFAULT 'active',
            superseded_by TEXT,
            locked INTEGER NOT NULL DEFAULT 0
        );
        CREATE INDEX IF NOT EXISTS memory_kind_idx ON memory(kind, status);
    """),
    (2, """
        CREATE VIRTUAL TABLE IF NOT EXISTS memory_fts USING fts5(
            text, subject, tags, content='memory', content_rowid='rowid'
        );
        INSERT INTO memory_fts(rowid, text, subject, tags)
            SELECT rowid, text, IFNULL(subject, ''), tags FROM memory;
    """),
]


class Migrator:
    """Applies schema versions in order and records every one in the database."""

    def __init__(self, connection: sqlite3.Connection, versions: list[tuple[int, str]]) -> None:
        self.connection = connection
        self.versions = versions
        self.connection.execute(
            "CREATE TABLE IF NOT EXISTS schema_version (version INTEGER PRIMARY KEY, applied_at REAL NOT NULL)"
        )
        self.connection.commit()

    @property
    def current_version(self) -> int:
        row = self.connection.execute("SELECT MAX(version) FROM schema_version").fetchone()
        return int(row[0] or 0)

    def migrate(self) -> list[int]:
        applied: list[int] = []
        for version, script in sorted(self.versions):
            if version <= self.current_version:
                continue
            try:
                self.connection.executescript(script)
                self.connection.execute("INSERT INTO schema_version (version, applied_at) VALUES (?, ?)",
                                        (version, time.time()))
                self.connection.commit()
            except sqlite3.Error as error:
                self.connection.rollback()
                raise RuntimeError(f"migration {version} failed: {error}") from error
            applied.append(version)
        return applied


class MemoryStore:
    def __init__(self, connection: sqlite3.Connection) -> None:
        self.connection = connection
        self.connection.row_factory = sqlite3.Row
        self.migrator = Migrator(connection, SCHEMA_VERSIONS)
        self.migrator.migrate()

    # -- writes ------------------------------------------------------------
    def add(self, record: MemoryRecord) -> MemoryRecord:
        # Instructions are pinned by definition: they must survive every retrieval
        # pass even when the query has no lexical overlap with them.
        record.locked = record.locked or record.kind == "instruction"
        self.connection.execute(
            """INSERT OR REPLACE INTO memory
               (id, kind, text, subject, tags, source, confidence, importance, created_at,
                updated_at, last_accessed_at, access_count, expires_at, status, superseded_by, locked)
               VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)""",
            (record.id, record.kind, record.text, record.subject, json.dumps(record.tags),
             record.source, record.confidence, record.importance, record.created_at, record.updated_at,
             record.last_accessed_at, record.access_count, record.expires_at, record.status,
             record.superseded_by, int(record.locked)),
        )
        self.connection.commit()
        return record

    def correct(self, record_id: str, new_text: str) -> MemoryRecord:
        existing = self.get(record_id)
        if existing is None:
            raise BadRequest(f"no memory with id {record_id}")
        if existing.locked and existing.source == "importedExternal":
            raise BadRequest("a record imported from an external service cannot be corrected by a model")
        replacement = MemoryRecord(kind="correction", text=new_text, source="user",
                                   confidence=min(1.0, existing.confidence + 0.05),
                                   importance=existing.importance, subject=existing.subject,
                                   tags=existing.tags)
        self.add(replacement)
        self.connection.execute("UPDATE memory SET status='superseded', superseded_by=? WHERE id=?",
                                (replacement.id, record_id))
        self.connection.commit()
        return replacement

    def forget(self, record_id: str) -> bool:
        cursor = self.connection.execute(
            "UPDATE memory SET status='deleted', updated_at=? WHERE id=? AND status != 'deleted'",
            (time.time(), record_id))
        self.connection.commit()
        return cursor.rowcount > 0

    def expire(self, now: float | None = None) -> int:
        now = now or time.time()
        cursor = self.connection.execute(
            "UPDATE memory SET status='expired' WHERE status='active' AND expires_at IS NOT NULL AND expires_at <= ?",
            (now,))
        self.connection.commit()
        return cursor.rowcount

    # -- reads -------------------------------------------------------------
    def get(self, record_id: str) -> MemoryRecord | None:
        row = self.connection.execute("SELECT * FROM memory WHERE id = ?", (record_id,)).fetchone()
        return self._row_to_record(row) if row else None

    def all(self, *, include_inactive: bool = False) -> list[MemoryRecord]:
        query = "SELECT * FROM memory" if include_inactive else "SELECT * FROM memory WHERE status='active'"
        rows = self.connection.execute(query + " ORDER BY updated_at DESC").fetchall()
        return [self._row_to_record(row) for row in rows]

    def search(self, query: str, *, limit: int = 8, now: float | None = None,
               fallback: bool = False) -> list[tuple[MemoryRecord, float]]:
        """Weighted retrieval: keyword overlap, recency, kind weight, confidence.

        Mirrors the on-device scorer closely enough that results feel consistent
        between phone and server.

        `fallback=True` is the *context* mode used when assembling a prompt: if the
        message has no lexical overlap with anything stored, the strongest records
        (instructions, high-importance facts) are still offered, because "what do you
        know about me?" contains no keywords worth matching. A user-issued search
        must stay strict, which is why the default is False and unrelated records are
        never returned to an explicit query.
        """
        now = now or time.time()
        terms = {term for term in _tokenize(query) if term not in STOPWORDS}
        scored: list[tuple[MemoryRecord, float]] = []
        lexical_hits = 0
        for record in self.all():
            keywords = _tokenize(record.text) | _tokenize(record.subject or "")
            overlap = len(terms & keywords)
            lexical_hits += overlap
            if terms and overlap == 0 and not record.locked:
                continue
            keyword_score = overlap / max(1, len(terms))
            age_days = max(0.0, (now - record.updated_at) / 86400)
            recency = 0.5 ** (age_days / 30.0)
            score = (0.42 * keyword_score
                     + 0.16 * recency
                     + 0.14 * KIND_WEIGHTS.get(record.kind, 0.5)
                     + 0.10 * record.confidence
                     + 0.10 * record.importance
                     + 0.04 * min(1.0, record.access_count / 10)
                     + (0.20 if record.locked else 0.0))
            if record.source == "importedExternal":
                score *= 0.9
            if score >= 0.12:
                scored.append((record, round(score, 4)))
        scored.sort(key=lambda item: item[1], reverse=True)
        if fallback and terms and lexical_hits == 0:
            seen = {record.id for record, _ in scored}
            for record in self.all():
                if record.id in seen:
                    continue
                strength = (0.28 * KIND_WEIGHTS.get(record.kind, 0.5)
                            + 0.22 * record.importance
                            + 0.18 * record.confidence
                            + 0.16 * (0.5 ** (max(0.0, (now - record.updated_at) / 86400) / 30.0))
                            + (0.16 if record.locked else 0.0))
                if record.locked or strength >= 0.30:
                    scored.append((record, round(strength, 4)))
            scored.sort(key=lambda item: item[1], reverse=True)
        selected = scored[:limit]
        if selected:
            self.connection.executemany(
                "UPDATE memory SET last_accessed_at=?, access_count=access_count+1 WHERE id=?",
                [(now, record.id) for record, _ in selected],
            )
            self.connection.commit()
        return selected

    def export(self, fmt: str = "json") -> str:
        records = [record.to_dict() for record in self.all(include_inactive=True)]
        if fmt == "json":
            return json.dumps(records, indent=2)
        if fmt == "csv":
            import csv
            import io

            buffer = io.StringIO()
            writer = csv.writer(buffer)
            writer.writerow(["id", "kind", "text", "subject", "tags", "source", "confidence", "importance", "created_at", "status"])
            for record in records:
                writer.writerow([record["id"], record["kind"], record["text"], record["subject"] or "",
                                 ",".join(record["tags"]), record["source"], record["confidence"],
                                 record["importance"], record["created_at"], record["status"]])
            return buffer.getvalue()
        if fmt == "markdown":
            lines = ["# JARVIS memory export", ""]
            for record in records:
                lines.append(f"- **{record['kind']}** ({record['confidence']:.2f}) — {record['text']}")
            return "\n".join(lines)
        raise BadRequest("format must be one of json, csv, markdown")

    def count(self) -> int:
        row = self.connection.execute("SELECT COUNT(*) FROM memory WHERE status='active'").fetchone()
        return int(row[0])

    @staticmethod
    def _row_to_record(row: sqlite3.Row) -> MemoryRecord:
        return MemoryRecord(
            id=row["id"], kind=row["kind"], text=row["text"], subject=row["subject"],
            tags=json.loads(row["tags"] or "[]"), source=row["source"], confidence=row["confidence"],
            importance=row["importance"], created_at=row["created_at"], updated_at=row["updated_at"],
            last_accessed_at=row["last_accessed_at"], access_count=row["access_count"],
            expires_at=row["expires_at"], status=row["status"], superseded_by=row["superseded_by"],
            locked=bool(row["locked"]),
        )


STOPWORDS = {
    "a", "an", "the", "is", "are", "was", "were", "be", "to", "of", "and", "or", "in", "on",
    "for", "with", "my", "me", "i", "you", "your", "it", "that", "this", "at", "as", "by",
    "do", "does", "did", "what", "when", "where", "who", "how", "please", "about",
}


def _tokenize(text: str) -> set[str]:
    cleaned = "".join(character.lower() if character.isalnum() else " " for character in text)
    return {token for token in cleaned.split() if len(token) > 1}
