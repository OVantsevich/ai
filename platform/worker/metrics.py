"""Run state and events in the platform database. Failures are logged and never stop a run."""

import logging
import os

import psycopg
from psycopg.types.json import Jsonb

DATABASE_URL = os.environ.get("DATABASE_URL")

log = logging.getLogger("worker.metrics")


def _event(cur, event_type: str, command: dict, payload: dict) -> None:
    cur.execute(
        "INSERT INTO events (type, task_id, step_key, run_id, role, payload) VALUES (%s, %s, %s, %s, %s, %s)",
        (event_type, command["task_id"], command.get("step_id"), command["run_id"], command["role"], Jsonb(payload)),
    )


def run_started(command: dict, engine: str) -> None:
    if not DATABASE_URL:
        return
    try:
        with psycopg.connect(DATABASE_URL, autocommit=True) as conn, conn.cursor() as cur:
            step_pk = None
            if command.get("step_id"):
                cur.execute(
                    """SELECT s.id FROM steps s JOIN plans p ON p.id = s.plan_id
                       WHERE s.task_id = %s AND s.step_key = %s ORDER BY p.version DESC LIMIT 1""",
                    (command["task_id"], command["step_id"]),
                )
                row = cur.fetchone()
                step_pk = row[0] if row else None
            cur.execute(
                "SELECT count(*) FROM runs WHERE task_id = %s AND role = %s AND step_id IS NOT DISTINCT FROM %s",
                (command["task_id"], command["role"], step_pk),
            )
            attempt = cur.fetchone()[0] + 1
            cur.execute(
                "INSERT INTO runs (id, step_id, task_id, role, command, engine, attempt) VALUES (%s, %s, %s, %s, %s, %s, %s)",
                (command["run_id"], step_pk, command["task_id"], command["role"], command["command"], engine, attempt),
            )
            _event(cur, "run.started", command, {"command": command["command"], "engine": engine, "attempt": attempt})
    except Exception:
        log.exception("run.started not recorded for %s", command["run_id"])


def run_finished(command: dict, result: dict, memory_project: str | None, memory_files: int) -> None:
    if not DATABASE_URL:
        return
    usage = result.get("usage", {})
    try:
        with psycopg.connect(DATABASE_URL, autocommit=True) as conn, conn.cursor() as cur:
            cur.execute(
                """UPDATE runs SET status = %s, finished_at = now(), model = %s, tokens_in = %s,
                       tokens_out = %s, cost_usd = %s, turns = %s, result = %s
                   WHERE id = %s""",
                (
                    result["status"], usage.get("model"), usage.get("tokens_in"), usage.get("tokens_out"),
                    usage.get("cost_usd"), usage.get("turns"), Jsonb(result), command["run_id"],
                ),
            )
            _event(cur, "run.finished", command, {"status": result["status"], "duration_ms": usage.get("duration_ms")})
            if usage.get("model"):
                _event(cur, "llm.usage", command, {
                    key: usage.get(key) for key in ("model", "tokens_in", "tokens_out", "cost_usd", "turns")
                })
            if memory_files:
                _event(cur, "memory.updated", command, {"project": memory_project, "files": memory_files})
    except Exception:
        log.exception("run.finished not recorded for %s", command["run_id"])
