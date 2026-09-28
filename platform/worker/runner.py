"""Executes one role run: prepares the workspace, calls the engine, validates and records the result."""

import json
import logging
import os
import re
import shutil
import subprocess
import time
from pathlib import Path

import yaml

import metrics
import schemas

ROLE_DIR = Path(os.environ.get("ROLE_DIR", "/role"))
ENGINES_DIR = Path(os.environ.get("ENGINES_DIR", "/opt/worker/engines"))
WORKSPACES_DIR = Path(os.environ.get("WORKSPACES_DIR", "/workspaces"))
MEMORY_DIR = Path(os.environ.get("MEMORY_DIR", "/memory"))
LOGS_DIR = Path(os.environ.get("LOGS_DIR", "/logs"))
GITLAB_URL = os.environ.get("GITLAB_URL", "").rstrip("/")

DEFAULT_TIMEOUT_S = 3600
DURATION = re.compile(r"^(\d+)([smh])$")
GITLAB_REF = re.compile(r"^gitlab:([^!#@]+)(?:@([^!#]+))?")
ENV_VAR = re.compile(r"\$\{([A-Z0-9_]+)\}")

log = logging.getLogger("worker.runner")


def load_role() -> dict:
    role = yaml.safe_load((ROLE_DIR / "role.yaml").read_text(encoding="utf-8"))
    engine = (role.get("runtime") or {}).get("engine")
    if not role.get("id") or not engine:
        raise ValueError("role.yaml must define id and runtime.engine")
    if not (ENGINES_DIR / engine / "run").exists():
        raise ValueError(f"unknown engine: {engine}")
    return role


def parse_duration(value) -> int:
    if value is None:
        return DEFAULT_TIMEOUT_S
    match = DURATION.match(str(value))
    if not match:
        raise ValueError(f"invalid duration: {value}")
    return int(match[1]) * {"s": 1, "m": 60, "h": 3600}[match[2]]


def repositories(command: dict) -> list[dict]:
    refs = list(command.get("refs", []))
    for previous in (command.get("context") or {}).get("previous", []):
        refs += previous.get("refs", [])
    repos: list[dict] = []
    for ref in refs:
        match = GITLAB_REF.match(ref)
        if match and all(repo["project"] != match[1] for repo in repos):
            repos.append({"project": match[1], "ref": match[2]})
    return repos


def git(args: list[str], cwd: Path | None = None) -> None:
    try:
        subprocess.run(["git", *args], cwd=cwd, check=True, capture_output=True, text=True, timeout=600)
    except subprocess.CalledProcessError as e:
        raise RuntimeError(f"git {args[0]} failed: {e.stderr.strip()}") from None


def clone(repo: dict, path: Path) -> None:
    if (path / ".git").exists():
        git(["fetch", "--prune", "origin"], cwd=path)
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    args = ["clone", "--filter=blob:none"]
    if repo["ref"]:
        args += ["--branch", repo["ref"]]
    git([*args, f"{GITLAB_URL}/{repo['project']}.git", str(path)])


def instructions(memory_project: Path | None) -> str:
    parts = []
    for folder in ("instructions", "rules"):
        parts += [f.read_text(encoding="utf-8") for f in sorted((ROLE_DIR / folder).glob("*.md"))]
    memory_files = sorted((MEMORY_DIR / "_global").glob("*.md"))
    if memory_project:
        memory_files += sorted(memory_project.glob("*.md"))
    if memory_files:
        parts.append("# Memory")
        parts += [f"## {f.relative_to(MEMORY_DIR)}\n\n{f.read_text(encoding='utf-8')}" for f in memory_files]
    return "\n\n".join(part.strip() for part in parts) + "\n"


def render_mcp() -> dict | None:
    source = ROLE_DIR / "tools" / "mcp.yaml"
    if not source.exists():
        return None
    text = ENV_VAR.sub(lambda m: os.environ.get(m[1], ""), source.read_text(encoding="utf-8"))
    return yaml.safe_load(text)


def prepare(role: dict, command: dict, workspace: Path) -> Path:
    agent = workspace / ".agent"
    agent.mkdir(parents=True, exist_ok=True)

    repos = repositories(command)
    if (role.get("workspace") or {}).get("clone", False):
        for repo in repos:
            clone(repo, workspace / repo["project"])
    for repo in repos:
        repo["path"] = str(workspace / repo["project"])

    memory_project = MEMORY_DIR / repos[0]["project"].replace("/", "__") if repos else None
    for directory in (MEMORY_DIR / "_global", memory_project):
        if directory:
            directory.mkdir(parents=True, exist_ok=True)

    (agent / "instructions.md").write_text(instructions(memory_project), encoding="utf-8")
    for folder in ("skills", "tools"):
        if (ROLE_DIR / folder).is_dir():
            shutil.copytree(ROLE_DIR / folder, agent / folder, dirs_exist_ok=True)
    shutil.copy(ROLE_DIR / "role.yaml", agent / "role.yaml")
    mcp = render_mcp()
    if mcp is not None:
        (agent / "mcp.json").write_text(json.dumps(mcp, indent=2), encoding="utf-8")
    (agent / "command.json").write_text(json.dumps(command, ensure_ascii=False, indent=2), encoding="utf-8")

    context = {
        "run_id": command["run_id"],
        "role": role["id"],
        "role_dir": str(ROLE_DIR),
        "workspace": str(workspace),
        "agent_dir": str(agent),
        "command": str(agent / "command.json"),
        "instructions": str(agent / "instructions.md"),
        "skills_dir": str(agent / "skills") if (agent / "skills").is_dir() else None,
        "mcp_config": str(agent / "mcp.json") if mcp is not None else None,
        "repos": repos,
        "memory_dir": str(MEMORY_DIR),
        "memory_project_dir": str(memory_project) if memory_project else None,
        "result_path": str(agent / "result.json"),
        "result_schema": str(schemas.PROTOCOL_DIR / "result.schema.json"),
        "limits": role.get("limits") or {},
    }
    (agent / "context.json").write_text(json.dumps(context, ensure_ascii=False, indent=2), encoding="utf-8")
    return agent


def failed(summary: str, error: str) -> dict:
    return {"status": "failed", "summary": summary, "error": error}


def run_engine(engine: str, agent: Path, workspace: Path, timeout_s: int, log_path: Path) -> dict:
    result_path = agent / "result.json"
    result_path.unlink(missing_ok=True)
    with log_path.open("a", encoding="utf-8") as out:
        try:
            proc = subprocess.run(
                [str(ENGINES_DIR / engine / "run"), str(agent / "context.json")],
                cwd=workspace, stdout=out, stderr=subprocess.STDOUT, timeout=timeout_s,
            )
        except subprocess.TimeoutExpired:
            return failed("Engine timed out.", f"no result after {timeout_s}s")
    if not result_path.exists():
        return failed("Engine returned no result.", f"engine exited with code {proc.returncode}; log: {log_path.name}")
    return json.loads(result_path.read_text(encoding="utf-8"))


def memory_snapshot() -> dict[str, int]:
    return {str(p): p.stat().st_mtime_ns for p in MEMORY_DIR.rglob("*") if p.is_file()}


def execute(command: dict) -> dict:
    started = time.monotonic()
    run_id = command["run_id"]
    key = f"{command['task_id']}-{command['step_id']}" if command.get("step_id") else run_id
    workspace = WORKSPACES_DIR / key
    LOGS_DIR.mkdir(parents=True, exist_ok=True)
    log_path = LOGS_DIR / f"{run_id}.log"

    engine = None
    memory_before = memory_snapshot()
    try:
        role = load_role()
        engine = role["runtime"]["engine"]
        metrics.run_started(command, engine)
        agent = prepare(role, command, workspace)
        result = run_engine(engine, agent, workspace, parse_duration((role.get("limits") or {}).get("timeout")), log_path)
    except Exception as e:
        log.exception("run %s failed", run_id)
        if engine is None:
            metrics.run_started(command, "unknown")
        result = failed("Run failed before the engine returned a result.", f"{type(e).__name__}: {e}")

    result.update(run_id=run_id, role=command["role"])
    problems = schemas.errors("result", result)
    if problems:
        result = {"run_id": run_id, "role": command["role"],
                  **failed("Engine returned an invalid result.", "; ".join(problems[:5]))}
    result.setdefault("usage", {})["duration_ms"] = int((time.monotonic() - started) * 1000)

    memory_after = memory_snapshot()
    changed = sum(1 for path, mtime in memory_after.items() if memory_before.get(path) != mtime)
    repos = repositories(command)
    memory_project = repos[0]["project"].replace("/", "__") if repos else None
    metrics.run_finished(command, result, memory_project, changed)

    if result["status"] == "completed":
        shutil.rmtree(workspace, ignore_errors=True)
    return result
