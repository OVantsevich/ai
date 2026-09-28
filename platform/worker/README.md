# Worker

Common runtime of role containers. A role image is built `FROM ai-worker-base` and adds the role directory at `/role` plus the role's CLI tools.

## HTTP API (port 9000)

| Method | Path | Response |
|---|---|---|
| `GET` | `/health` | role id, engine, current run |
| `POST` | `/runs` | body: [command](../protocol/command.schema.json). `202` started, `400` invalid command or other role, `409` busy or duplicate `run_id` |
| `GET` | `/runs/<run_id>` | status and result of a run (last 200 runs, in memory) |

One run at a time. When the run finishes, the worker posts the [result](../protocol/result.schema.json) to `callback_url` (3 attempts). If the callback is lost, the result stays available at `GET /runs/<run_id>`.

## Run

1. Reads `/role/role.yaml` (`id`, `runtime.engine`, `limits.timeout`, `workspace.clone`).
2. Workspace `/workspaces/<task_id>-<step_id>` (`<run_id>` for runs without a step). Runs of the same step share it, so `continue` after approval sees the previous state.
3. With `workspace.clone: true`, clones every `gitlab:` reference from `refs` and `context.previous[].refs` into `<workspace>/<project>`, or fetches if already cloned. Git auth uses `GITLAB_TOKEN` as an HTTP header; the token is not written to remote URLs.
4. Builds `<workspace>/.agent/`:

   | File | Content |
   |---|---|
   | `instructions.md` | `instructions/*.md`, `rules/*.md`, then memory: `_global/*.md` and the project's `*.md` |
   | `skills/`, `tools/`, `role.yaml` | copies from the role |
   | `mcp.json` | `tools/mcp.yaml` with `${VAR}` replaced from the environment |
   | `command.json` | the command |
   | `context.json` | paths and data for the engine |

5. Runs `engines/<engine>/run <context.json>` in the workspace; output goes to `/logs/<run_id>.log`.
6. Reads `.agent/result.json`, sets `run_id` and `role`, validates it. Timeout, a missing or invalid result becomes `failed`. Adds `usage.duration_ms`.
7. Deletes the workspace when the result is `completed`.

With `DATABASE_URL` set, the worker writes the `runs` row and the `run.started`, `run.finished`, `llm.usage` and `memory.updated` events. Database errors are logged and do not stop the run.

## Engines

An engine is an executable `engines/<name>/run` that takes the path to `context.json`, works in the workspace and writes a result to `context.result_path`.

`context.json` fields: `run_id`, `role`, `role_dir`, `workspace`, `agent_dir`, `command`, `instructions`, `skills_dir`, `mcp_config`, `repos` (`project`, `ref`, `path`), `memory_dir`, `memory_project_dir`, `result_path`, `result_schema`, `limits`.

| Engine | Description |
|---|---|
| `stub` | Scripted results without an LLM. Markers in the command text: `[stub:blocked]`, `[stub:needs_approval]`, `[stub:failed]`, `[stub:crash]`, `[stub:invalid]`, `[stub:sleep=N]`, `[stub:memory]`. A completed result is taken from `<role>/runtime/stub/<command>.json` if present |

## Environment

| Variable | Purpose |
|---|---|
| `ROLE_DIR` | role directory, default `/role` |
| `GITLAB_URL`, `GITLAB_TOKEN` | cloning work repositories |
| `GIT_WORK_NAME`, `GIT_WORK_EMAIL` | commit author in work repositories |
| `DATABASE_URL` | metrics; optional |
| `MEMORY_DIR`, `WORKSPACES_DIR`, `LOGS_DIR` | mounts, default `/memory`, `/workspaces`, `/logs` |

## Test

```bash
make test-worker                          # all scenarios on the stub engine, with database checks
make test-worker project=group/repo       # also clone of a real repository and memory
```
