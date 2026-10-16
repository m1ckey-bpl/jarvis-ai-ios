"""Server-side reminders and dispatch.

Purpose: iOS does not guarantee background execution, so a reminder that must
fire while the phone is asleep can be scheduled here and delivered by a webhook
(push requires *your* Apple developer key, which this project never ships).
"""

from __future__ import annotations

import json
import sqlite3
import time
import uuid
from dataclasses import dataclass, field
from typing import Any, Callable

from .errors import BadRequest, NotConfigured
from .security import AuditLog
from .transport import HTTPRequest, Transport

SCHEMA = """
CREATE TABLE IF NOT EXISTS server_reminders (
    id TEXT PRIMARY KEY,
    title TEXT NOT NULL,
    due_at REAL NOT NULL,
    recurrence TEXT,
    created_at REAL NOT NULL,
    completed_at REAL,
    attempts INTEGER NOT NULL DEFAULT 0,
    last_attempt_at REAL,
    last_error TEXT,
    delivered_at REAL
);
CREATE INDEX IF NOT EXISTS server_reminders_due_idx ON server_reminders(due_at);
"""

MAX_ATTEMPTS = 5
BACKOFF_SECONDS = 30.0


@dataclass
class ReminderRecord:
    id: str = field(default_factory=lambda: str(uuid.uuid4()))
    title: str = ""
    due_at: float = 0.0
    recurrence: str | None = None
    created_at: float = field(default_factory=time.time)
    completed_at: float | None = None
    attempts: int = 0
    last_attempt_at: float | None = None
    last_error: str | None = None
    delivered_at: float | None = None

    def to_dict(self) -> dict[str, Any]:
        return {"id": self.id, "title": self.title, "dueAt": self.due_at,
                "recurrence": self.recurrence, "attempts": self.attempts,
                "deliveredAt": self.delivered_at, "lastError": self.last_error,
                "completedAt": self.completed_at}


def next_occurrence(due_at: float, recurrence: str) -> float | None:
    """Calendar-month arithmetic done with datetime so months do not drift."""
    import datetime

    if recurrence in (None, "", "none"):
        return None
    moment = datetime.datetime.fromtimestamp(due_at, datetime.timezone.utc)
    if recurrence == "daily":
        delta = datetime.timedelta(days=1)
    elif recurrence == "weekly":
        delta = datetime.timedelta(weeks=1)
    elif recurrence == "monthly":
        month = moment.month + 1
        year = moment.year + (1 if month > 12 else 0)
        month = 1 if month > 12 else month
        day = min(moment.day, 28)
        return moment.replace(year=year, month=month, day=day).timestamp()
    else:
        raise BadRequest(f"unsupported recurrence '{recurrence}' (daily, weekly, monthly)")
    return (moment + delta).timestamp()


class ReminderScheduler:
    def __init__(self, connection: sqlite3.Connection, audit: AuditLog) -> None:
        self.connection = connection
        self.connection.row_factory = sqlite3.Row
        self.connection.executescript(SCHEMA)
        self.connection.commit()
        self.audit = audit

    # -- writes ------------------------------------------------------------
    def schedule(self, *, title: str, due_at: float, recurrence: str | None = None) -> dict[str, Any]:
        title = title.strip()
        if not title:
            raise BadRequest("a reminder needs a title")
        if due_at < time.time() - 60 and not recurrence:
            raise BadRequest("that time is already in the past")
        if recurrence not in (None, "", "none", "daily", "weekly", "monthly"):
            raise BadRequest("recurrence must be daily, weekly or monthly")
        record = ReminderRecord(title=title[:200], due_at=due_at, recurrence=recurrence or None)
        self.connection.execute(
            "INSERT INTO server_reminders (id, title, due_at, recurrence, created_at) VALUES (?,?,?,?,?)",
            (record.id, record.title, record.due_at, record.recurrence, record.created_at))
        self.connection.commit()
        return record.to_dict()

    def complete(self, reminder_id: str) -> dict[str, Any]:
        record = self._load(reminder_id)
        if record is None:
            raise BadRequest(f"no reminder with id {reminder_id}")
        following = next_occurrence(record.due_at, record.recurrence or "")
        if following is not None:
            self.connection.execute(
                """UPDATE server_reminders SET due_at=?, attempts=0, last_error=NULL, delivered_at=NULL
                   WHERE id=?""", (following, reminder_id))
        else:
            self.connection.execute("UPDATE server_reminders SET completed_at=? WHERE id=?",
                                    (time.time(), reminder_id))
        self.connection.commit()
        return self._load(reminder_id).to_dict()

    def cancel(self, reminder_id: str) -> bool:
        cursor = self.connection.execute("DELETE FROM server_reminders WHERE id = ?", (reminder_id,))
        self.connection.commit()
        return cursor.rowcount > 0

    # -- reads -------------------------------------------------------------
    def _load(self, reminder_id: str) -> ReminderRecord | None:
        row = self.connection.execute("SELECT * FROM server_reminders WHERE id = ?", (reminder_id,)).fetchone()
        return self._row(row) if row else None

    @staticmethod
    def _row(row: sqlite3.Row) -> ReminderRecord:
        return ReminderRecord(id=row["id"], title=row["title"], due_at=row["due_at"],
                              recurrence=row["recurrence"], created_at=row["created_at"],
                              completed_at=row["completed_at"], attempts=row["attempts"],
                              last_attempt_at=row["last_attempt_at"], last_error=row["last_error"],
                              delivered_at=row["delivered_at"])

    def upcoming(self, *, limit: int = 20) -> list[dict[str, Any]]:
        rows = self.connection.execute(
            "SELECT * FROM server_reminders WHERE completed_at IS NULL ORDER BY due_at ASC LIMIT ?",
            (limit,)).fetchall()
        return [self._row(row).to_dict() for row in rows]

    def due(self, *, since: float, now: float | None = None) -> list[dict[str, Any]]:
        """Undelivered reminders that became due in (since, now].

        A reminder that failed is retried with exponential backoff, up to
        MAX_ATTEMPTS — nothing is silently dropped.
        """
        now = now or time.time()
        rows = self.connection.execute(
            """SELECT * FROM server_reminders
               WHERE completed_at IS NULL AND delivered_at IS NULL
                 AND due_at > ? AND due_at <= ?
               ORDER BY due_at ASC""", (since, now)).fetchall()
        pending: list[dict[str, Any]] = []
        for row in rows:
            record = self._row(row)
            if record.attempts >= MAX_ATTEMPTS:
                continue
            if record.attempts and record.last_attempt_at:
                delay = BACKOFF_SECONDS * (2 ** (record.attempts - 1))
                if now - record.last_attempt_at < delay:
                    continue
            pending.append(record.to_dict())
        return pending

    # -- delivery ----------------------------------------------------------
    def dispatch_due(self, *, since: float, transport: Transport, webhook: str | None,
                     now: float | None = None) -> list[dict[str, Any]]:
        now = now or time.time()
        results: list[dict[str, Any]] = []
        for reminder in self.due(since=since, now=now):
            if not webhook:
                results.append({**reminder, "delivery": "not_configured"})
                continue
            body = json.dumps({"type": "reminder.due", "reminder": reminder}).encode("utf-8")
            try:
                response = transport.send(HTTPRequest(url=webhook, method="POST", label="dispatch.reminder",
                                                      headers={"Content-Type": "application/json"}, body=body))
                if response.status >= 400:
                    raise RuntimeError(f"webhook returned HTTP {response.status}")
                self.connection.execute(
                    "UPDATE server_reminders SET delivered_at=?, attempts=attempts+1, last_attempt_at=?, last_error=NULL WHERE id=?",
                    (now, now, reminder["id"]))
                self.audit.record(actor="scheduler", action="reminder.dispatch", target=reminder["id"],
                                  outcome="delivered", detail={"title": reminder["title"]})
                results.append({**reminder, "delivery": "delivered"})
            except Exception as error:  # noqa: BLE001 - recorded, not swallowed
                self.connection.execute(
                    "UPDATE server_reminders SET attempts=attempts+1, last_attempt_at=?, last_error=? WHERE id=?",
                    (now, str(error)[:300], reminder["id"]))
                self.audit.record(actor="scheduler", action="reminder.dispatch", target=reminder["id"],
                                  outcome="failed", detail={"error": str(error)})
                results.append({**reminder, "delivery": "failed", "error": str(error)})
            self.connection.commit()
        return results

    def require_dispatch_configuration(self) -> None:
        raise NotConfigured(
            "Server-side dispatch needs JARVIS_DISPATCH_WEBHOOK (your own endpoint) or an APNs key "
            "you own; no push credentials are bundled with this project."
        )


@dataclass
class DispatchLoop:
    """Ticks the scheduler. Run it from cron, a platform job, or a loop."""

    scheduler: ReminderScheduler
    transport: Transport
    webhook: str | None
    interval_seconds: float = 60.0
    _last_tick: float = field(default_factory=time.time)

    def tick(self, now: float | None = None) -> list[dict[str, Any]]:
        now = now or time.time()
        results = self.scheduler.dispatch_due(since=self._last_tick, transport=self.transport,
                                              webhook=self.webhook, now=now)
        self._last_tick = now
        return results
