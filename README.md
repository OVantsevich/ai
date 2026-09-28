# AI Delivery Pipeline

Personal AI development pipeline: independent roles coordinated by a coordinator role, orchestrated by n8n, with human approvals in Telegram and process metrics in Grafana.

- Architecture: [docs/architecture.md](docs/architecture.md)
- Deferred work: [docs/backlog.md](docs/backlog.md)

## Quick start

Requirements: Docker with Compose v2, make.

```bash
make init        # creates platform/deploy/.env and data/ directories
# fill in platform/deploy/.env
make up
make ps
```

| Service | URL |
|---|---|
| n8n | http://localhost:5678 |
| Grafana | http://localhost:3000 (folder AI Pipeline) |

Run `make help` for all commands.

## Repository layout

| Path | Purpose |
|---|---|
| `roles/` | Independent roles. Each directory holds everything the role needs: instructions, rules, skills, tools, runtime, contracts, memory settings, evals |
| `playbooks/` | Recommended pipelines the coordinator may use as a basis for a plan |
| `platform/protocol/` | Formats shared by all components: task, plan, command, result, events (`make check-protocol`) |
| `platform/worker/` | Common runtime for role containers and engine adapters |
| `platform/orchestrator/` | Exported n8n workflows |
| `platform/metrics/` | Grafana dashboards ([Overview](http://localhost:3000/d/ai-overview), [Roles](http://localhost:3000/d/ai-roles), [Bottlenecks](http://localhost:3000/d/ai-bottlenecks), [Planning](http://localhost:3000/d/ai-planning)) |
| `platform/deploy/` | docker-compose, environment example, Grafana provisioning, PostgreSQL schema (`postgres/init/`) |
| `data/` | Local runtime data, not tracked: `memory/` (clone of `ai-memory`), `workspaces/`, `logs/` |

## Roles

Each role runs as container `role-<id>` (`http://role-<id>:9000`, API in [platform/worker/README.md](platform/worker/README.md)). The role directory is mounted read-only at `/role`, so changes apply on the next run without a rebuild.

| Path in `roles/<id>/` | Purpose |
|---|---|
| `role.yaml` | id, summary, commands, approvals, engine, limits, clone of repositories |
| `instructions/`, `rules/`, `skills/` | what the agent receives |
| `tools/mcp.yaml` | MCP servers; `${VAR}` is taken from the container environment |
| `runtime/Dockerfile` | image `FROM ai-worker-base` plus the role's CLI tools |
| `runtime/stub/<command>.json` | result of the `stub` engine for a command |

A role is enabled by its service in `platform/deploy/docker-compose.yaml`; the orchestrator builds the role catalog for the coordinator from `GET /role`.

## Repositories and connections

| What | Where |
|---|---|
| Pipeline configuration | this repository (personal GitHub) |
| Role memory | `ai-memory` (personal GitHub), cloned into `data/memory/` |
| Work repositories | work GitLab, accessed by roles through GitLab MCP and git |
| Jira, Confluence | Atlassian Rovo MCP, API token |
| Approvals, notifications | Telegram bot via n8n |
