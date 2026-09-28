"""Role worker HTTP API. Executes one run at a time.

GET  /health          role id, engine, current run
GET  /role            role card: id, summary, commands, approvals (for the role catalog)
POST /runs            start a run; body is a command (protocol/command.schema.json)
                      202 started, 400 invalid, 409 busy or duplicate run_id
GET  /runs/<run_id>   status and result of a run started by this worker
"""

import json
import logging
import os
import re
import threading
import time
import urllib.request
from collections import OrderedDict
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import runner
import schemas

PORT = int(os.environ.get("PORT", "9000"))
KEEP_RESULTS = 200

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s: %(message)s")
log = logging.getLogger("worker")

ROLE = runner.load_role()
lock = threading.Lock()
active_run: str | None = None
runs: OrderedDict[str, dict] = OrderedDict()


def send_callback(url: str, result: dict) -> None:
    body = json.dumps(result, ensure_ascii=False).encode()
    for attempt in range(1, 4):
        try:
            request = urllib.request.Request(url, data=body, headers={"Content-Type": "application/json"}, method="POST")
            with urllib.request.urlopen(request, timeout=30):
                return
        except Exception as e:
            log.warning("callback attempt %d for %s failed: %s", attempt, result["run_id"], e)
            time.sleep(2 * attempt)
    log.error("callback for %s not delivered; result available at GET /runs/%s", result["run_id"], result["run_id"])


def run_in_background(command: dict) -> None:
    global active_run
    try:
        result = runner.execute(command)
    except Exception as e:
        log.exception("unexpected error in run %s", command["run_id"])
        result = {"run_id": command["run_id"], "role": command["role"], "status": "failed",
                  "summary": "Worker error.", "error": f"{type(e).__name__}: {e}"}
    with lock:
        runs[command["run_id"]] = {"status": result["status"], "result": result}
        active_run = None
    log.info("run %s finished: %s", command["run_id"], result["status"])
    if command.get("callback_url"):
        send_callback(command["callback_url"], result)


class Handler(BaseHTTPRequestHandler):
    def _send(self, status: int, payload: dict) -> None:
        body = json.dumps(payload, ensure_ascii=False).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == "/health":
            self._send(200, {"role": ROLE["id"], "engine": ROLE["runtime"]["engine"], "active_run": active_run})
            return
        if self.path == "/role":
            role = runner.load_role()
            self._send(200, {key: role.get(key) for key in ("id", "summary", "commands", "approvals")})
            return
        match = re.fullmatch(r"/runs/([^/]+)", self.path)
        if match and match[1] in runs:
            self._send(200, {"run_id": match[1], **runs[match[1]]})
            return
        self._send(404, {"error": "not found"})

    def do_POST(self):
        global active_run
        if self.path != "/runs":
            self._send(404, {"error": "not found"})
            return
        try:
            command = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))))
        except (ValueError, json.JSONDecodeError):
            self._send(400, {"error": "body must be JSON"})
            return
        problems = schemas.errors("command", command)
        if problems:
            self._send(400, {"error": "invalid command", "details": problems})
            return
        if command["role"] != ROLE["id"]:
            self._send(400, {"error": f"this worker serves role {ROLE['id']}"})
            return
        with lock:
            if active_run:
                self._send(409, {"error": "busy", "active_run": active_run})
                return
            if command["run_id"] in runs:
                self._send(409, {"error": "duplicate run_id"})
                return
            active_run = command["run_id"]
            runs[command["run_id"]] = {"status": "running"}
            while len(runs) > KEEP_RESULTS:
                runs.popitem(last=False)
        threading.Thread(target=run_in_background, args=(command,), daemon=True).start()
        self._send(202, {"run_id": command["run_id"], "status": "running"})

    def log_message(self, fmt, *args):
        log.info("%s %s", self.address_string(), fmt % args)


if __name__ == "__main__":
    log.info("role %s, engine %s, listening on :%d", ROLE["id"], ROLE["runtime"]["engine"], PORT)
    ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
