"""Server-side reminders: recurrence arithmetic, retry/backoff and dispatch."""

from __future__ import annotations

import datetime
import sqlite3
import time

import pytest

from app.errors import BadRequest
from app.scheduler import MAX_ATTEMPTS, DispatchLoop, ReminderScheduler, next_occurrence
from app.security import AuditLog
from app.transport import RecordingTransport


@pytest.fixture
def scheduler() -> ReminderScheduler:
    connection = sqlite3.connect(":memory:")
    return ReminderScheduler(connection, AuditLog(connection))


def test_schedule_and_list(scheduler: ReminderScheduler) -> None:
    due = time.time() + 3600
    created = scheduler.schedule(title="Standup", due_at=due)
    assert created["title"] == "Standup"
    assert scheduler.upcoming()[0]["id"] == created["id"]


def test_past_reminders_without_recurrence_are_refused(scheduler: ReminderScheduler) -> None:
    with pytest.raises(BadRequest):
        scheduler.schedule(title="Yesterday", due_at=time.time() - 7200)
    # A recurring reminder that already started is fine — its next occurrence is in the future.
    scheduler.schedule(title="Daily standup", due_at=time.time() - 7200, recurrence="daily")


def test_invalid_recurrence_is_refused(scheduler: ReminderScheduler) -> None:
    with pytest.raises(BadRequest):
        scheduler.schedule(title="Hourly", due_at=time.time() + 60, recurrence="hourly")


def test_one_off_completion_closes_the_reminder(scheduler: ReminderScheduler) -> None:
    reminder = scheduler.schedule(title="Call home", due_at=time.time() + 60)
    completed = scheduler.complete(reminder["id"])
    assert completed["completedAt"] is not None
    assert scheduler.upcoming() == []


def test_recurring_completion_rolls_forward(scheduler: ReminderScheduler) -> None:
    due = time.time() + 60
    reminder = scheduler.schedule(title="Weekly review", due_at=due, recurrence="weekly")
    rolled = scheduler.complete(reminder["id"])
    assert rolled["completedAt"] is None
    assert rolled["dueAt"] == pytest.approx(due + 7 * 86400, abs=1)
    assert rolled["attempts"] == 0


def test_cancel_removes_the_reminder(scheduler: ReminderScheduler) -> None:
    reminder = scheduler.schedule(title="Temp", due_at=time.time() + 60)
    assert scheduler.cancel(reminder["id"]) is True
    assert scheduler.cancel(reminder["id"]) is False


def test_due_window_respects_since_and_now(scheduler: ReminderScheduler) -> None:
    now = time.time()
    scheduler.schedule(title="Soon", due_at=now + 10)
    assert scheduler.due(since=now, now=now + 5) == []
    assert [item["title"] for item in scheduler.due(since=now, now=now + 20)] == ["Soon"]
    assert scheduler.due(since=now + 15, now=now + 20) == []


def test_failed_delivery_retries_with_backoff_then_gives_up(scheduler: ReminderScheduler) -> None:
    now = time.time()
    reminder = scheduler.schedule(title="Flaky", due_at=now + 1)
    transport = RecordingTransport()
    webhook = "https://hooks.invalid/reminder"

    outcomes: list[str] = []
    clock = now + 5
    for step in range(MAX_ATTEMPTS + 2):
        transport.queue(500, {"error": "boom"})
        results = scheduler.dispatch_due(since=now, transport=transport, webhook=webhook, now=clock)
        if not results:
            break
        outcomes.append(results[0]["delivery"])
        clock += 30 * (2 ** step) + 5          # wait out the exponential backoff

    assert outcomes and all(outcome == "failed" for outcome in outcomes)
    assert len(outcomes) == MAX_ATTEMPTS
    row = scheduler._load(reminder["id"])
    assert row.attempts == MAX_ATTEMPTS
    assert row.last_error
    # Once the attempt budget is exhausted the reminder stops being retried —
    # it stays visible in the log with its error instead of disappearing.
    assert scheduler.due(since=now, now=clock + 86_400) == []
    assert scheduler._load(reminder["id"]).completed_at is None


def test_backoff_prevents_immediate_retry(scheduler: ReminderScheduler) -> None:
    now = time.time()
    scheduler.schedule(title="Once", due_at=now + 1)
    transport = RecordingTransport()
    transport.queue(500, {})
    first = scheduler.dispatch_due(since=now, transport=transport, webhook="https://hooks.invalid/x", now=now + 5)
    assert first[0]["delivery"] == "failed"
    # One second later the backoff window has not elapsed, so nothing is retried yet.
    assert scheduler.due(since=now, now=now + 6) == []


def test_successful_delivery_is_recorded_and_not_repeated(scheduler: ReminderScheduler) -> None:
    now = time.time()
    reminder = scheduler.schedule(title="Deliver me", due_at=now + 1)
    transport = RecordingTransport()
    transport.queue(200, {"ok": True})
    results = scheduler.dispatch_due(since=now, transport=transport, webhook="https://hooks.invalid/x", now=now + 5)
    assert results[0]["delivery"] == "delivered"
    assert scheduler._load(reminder["id"]).delivered_at is not None
    assert scheduler.due(since=now, now=now + 60) == []


def test_dispatch_without_webhook_reports_not_configured(scheduler: ReminderScheduler) -> None:
    now = time.time()
    scheduler.schedule(title="No target", due_at=now + 1)
    results = scheduler.dispatch_due(since=now, transport=RecordingTransport(), webhook=None, now=now + 5)
    assert results[0]["delivery"] == "not_configured"


def test_audit_trail_records_dispatch_attempts(scheduler: ReminderScheduler) -> None:
    now = time.time()
    scheduler.schedule(title="Audited", due_at=now + 1)
    transport = RecordingTransport()
    transport.queue(200, {})
    scheduler.dispatch_due(since=now, transport=transport, webhook="https://hooks.invalid/x", now=now + 5)
    entries = scheduler.audit.recent()
    assert entries[0]["action"] == "reminder.dispatch"
    assert entries[0]["outcome"] == "delivered"


def test_next_occurrence_arithmetic() -> None:
    january_31 = datetime.datetime(2026, 1, 31, 9, 0, tzinfo=datetime.timezone.utc).timestamp()
    february = next_occurrence(january_31, "monthly")
    assert datetime.datetime.fromtimestamp(february, datetime.timezone.utc).month == 2
    assert datetime.datetime.fromtimestamp(february, datetime.timezone.utc).day == 28

    assert next_occurrence(january_31, "daily") == january_31 + 86400
    assert next_occurrence(january_31, "weekly") == january_31 + 7 * 86400
    assert next_occurrence(january_31, "none") is None
    with pytest.raises(BadRequest):
        next_occurrence(january_31, "fortnightly")
