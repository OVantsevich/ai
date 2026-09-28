"""Worker smoke test.

Runs inside a worker container started with ROLE_DIR=/opt/worker/tests/role while the worker listens on :9000.
Optional: DATABASE_URL checks recorded runs and events; SMOKE_GITLAB_PROJECT checks clone and memory.
"""

import json
import os
import sys
import threading
import time
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

WORKER = "http://127.0.0.1:9000"
CALLBACK_PORT = 9100
DATABASE_URL = os.environ.get("DATABASE_URL")
GITLAB_PROJECT = os.environ.get("SMOKE_GITLAB_PROJECT")
WORKSPACES = Path(os.environ.get("WORKSPACES_DIR", "/workspaces"))
MEMORY = Path(os.environ.get("MEMORY_DIR", "/memory"))

callbacks: dict[str, dict] = {}
arrived = threading.Condition()
failures = 0
started_runs = 0
task_id = 1
counter = 0


class CallbackHandler(BaseHTTPRequestHandler):
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        with arrived:
            callbacks[body["run_id"]] = body
            arrived.notify_all()
        self.send_response(200)
        self.end_headers()

    def log_message(self, *args):
        pass


def check(name: str, ok: bool, detail="") -> None:
    global failures
    if not ok:
        failures += 1
    print(f"{'ok  ' if ok else 'FAIL'}  {name}" + (f"  ({detail})" if detail and not ok else ""))


def request(method: str, path: str, body=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(WORKER + path, data=data, method=method, headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=10) as response:
            return response.status, json.loads(response.read())
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read())


def command(text: str, step: str, name: str = "echo", **extra) -> dict:
    global counter
    counter += 1
    body = {
        "run_id": f"smoke-{os.getpid()}-{counter}", "task_id": task_id, "step_id": step,
        "role": "test-role", "command": name, "text": text,
        "callback_url": f"http://127.0.0.1:{CALLBACK_PORT}/callback",
    }
    body.update(extra)
    return body


def start(cmd: dict) -> int:
    global started_runs
    status, _ = request("POST", "/runs", cmd)
    if status == 202:
        started_runs += 1
    return status


def run(cmd: dict, timeout: float = 60) -> dict:
    status = start(cmd)
    if status != 202:
        return {"status": f"http {status}"}
    with arrived:
        arrived.wait_for(lambda: cmd["run_id"] in callbacks, timeout=timeout)
    return callbacks.get(cmd["run_id"], {"status": "no callback"})


def wait_for_worker() -> None:
    for _ in range(50):
        try:
            if request("GET", "/health")[0] == 200:
                return
        except OSError:
            pass
        time.sleep(0.2)
    sys.exit("worker did not start")


def create_task() -> int:
    import psycopg

    with psycopg.connect(DATABASE_URL, autocommit=True) as conn:
        return conn.execute("INSERT INTO tasks (title, text) VALUES ('worker smoke test', 'smoke') RETURNING id").fetchone()[0]


def check_database() -> None:
    import psycopg

    with psycopg.connect(DATABASE_URL, autocommit=True) as conn:
        runs = conn.execute("SELECT count(*), count(finished_at) FROM runs WHERE task_id = %s", (task_id,)).fetchone()
        types = {row[0] for row in conn.execute("SELECT DISTINCT type FROM events WHERE task_id = %s", (task_id,))}
        durations = conn.execute("SELECT count(*) FROM runs WHERE task_id = %s AND duration_ms >= 0", (task_id,)).fetchone()[0]
        check("db: every started run recorded and finished", runs == (started_runs, started_runs), f"{runs} vs {started_runs}")
        check("db: duration computed", durations == started_runs)
        expected = {"run.started", "run.finished", "llm.usage"} | ({"memory.updated"} if GITLAB_PROJECT else set())
        check("db: events written", expected <= types, f"{sorted(types)}")
        conn.execute("DELETE FROM tasks WHERE id = %s", (task_id,))


def main() -> None:
    global task_id
    threading.Thread(target=HTTPServer(("127.0.0.1", CALLBACK_PORT), CallbackHandler).serve_forever, daemon=True).start()
    wait_for_worker()
    if DATABASE_URL:
        task_id = create_task()

    status, health = request("GET", "/health")
    check("health", status == 200 and health["role"] == "test-role" and health["engine"] == "stub", health)

    invalid = command("x", "s0")
    del invalid["text"]
    check("invalid command rejected", request("POST", "/runs", invalid)[0] == 400)
    check("other role rejected", request("POST", "/runs", command("x", "s0", role="coordinator"))[0] == 400)

    result = run(command("completed with fixture", "s1"))
    check("completed uses fixture", result.get("summary") == f"echo for task {task_id}"
          and result.get("refs") == [f"jira:TEST-{task_id}"], result)
    check("duration reported", result.get("usage", {}).get("duration_ms", -1) >= 0)
    check("workspace removed after completed", not (WORKSPACES / f"{task_id}-s1").exists())
    check("result stored", request("GET", f"/runs/{result.get('run_id')}")[1].get("status") == "completed")

    slow = command("[stub:sleep=3]", "s2")
    check("slow run started", start(slow) == 202)
    check("busy while running", start(command("second", "s2b")) == 409)
    check("duplicate run_id rejected", start(dict(slow)) == 409)
    with arrived:
        arrived.wait_for(lambda: slow["run_id"] in callbacks, timeout=30)
    check("slow run finished", callbacks.get(slow["run_id"], {}).get("status") == "completed")

    result = run(command("[stub:needs_approval]", "s3"))
    check("needs_approval", result.get("status") == "needs_approval" and "pending_approval" in result, result)
    agent = WORKSPACES / f"{task_id}-s3" / ".agent"
    instructions = (agent / "instructions.md").read_text() if (agent / "instructions.md").exists() else ""
    check("workspace kept for approval", agent.is_dir())
    check("instructions assembled", "SYSTEM-INSTRUCTIONS-MARKER" in instructions and "RULES-MARKER" in instructions)
    check("skills copied", (agent / "skills" / "example" / "SKILL.md").exists())
    mcp = json.loads((agent / "mcp.json").read_text()) if (agent / "mcp.json").exists() else {}
    check("mcp config env expanded",
          mcp.get("servers", {}).get("gitlab", {}).get("headers", {}).get("Authorization") == "Bearer smoke-token", mcp)
    result = run(command("continue", "s3", name="continue", approval={"decision": "approved"}))
    check("continue after approval completes", result.get("status") == "completed", result)
    check("workspace removed after continue", not agent.exists())

    result = run(command("[stub:needs_approval]", "s4"))
    result = run(command("continue", "s4", name="continue", approval={"decision": "rejected", "comment": "no"}))
    check("continue after rejection blocks", result.get("status") == "blocked" and result.get("questions"), result)

    result = run(command("[stub:blocked]", "s5"))
    check("blocked with questions", result.get("status") == "blocked" and result.get("questions"), result)
    result = run(command("[stub:failed]", "s6"))
    check("failed with error", result.get("status") == "failed" and result.get("error"), result)
    result = run(command("[stub:crash]", "s7"))
    check("engine crash reported", result.get("status") == "failed" and "no result" in result.get("summary", ""), result)
    result = run(command("[stub:invalid]", "s8"))
    check("invalid engine result reported", result.get("status") == "failed" and "invalid" in result.get("summary", ""), result)

    if GITLAB_PROJECT:
        step = "s9"
        result = run(command("[stub:needs_approval] [stub:memory]", step, refs=[f"gitlab:{GITLAB_PROJECT}"]), timeout=300)
        repo = WORKSPACES / f"{task_id}-{step}" / GITLAB_PROJECT
        check("repository cloned", (repo / ".git").is_dir(), result)
        remote = os.popen(f"git -C {repo} remote get-url origin").read().strip()
        check("token not stored in remote url", remote.startswith("https://") and "@" not in remote, remote)
        memory_file = MEMORY / GITLAB_PROJECT.replace("/", "__") / "stub.md"
        check("memory written", memory_file.exists())
        run(command("continue", step, name="continue", approval={"decision": "approved"}), timeout=300)
    else:
        print("skip  clone and memory (SMOKE_GITLAB_PROJECT not set)")

    if DATABASE_URL:
        check_database()
    else:
        print("skip  database (DATABASE_URL not set)")

    print(f"\n{'FAILED: ' + str(failures) if failures else 'all checks passed'}")
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
