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
| Grafana | http://localhost:3000 |

Run `make help` for all commands.

## Repository layout

| Path | Purpose |
|---|---|
| `roles/` | Independent roles. Each directory holds everything the role needs: instructions, rules, skills, tools, runtime, contracts, memory settings, evals |
| `playbooks/` | Recommended pipelines the coordinator may use as a basis for a plan |
| `platform/protocol/` | Formats shared by all components: task, plan, command, result, events |
| `platform/worker/` | Common runtime for role containers and engine adapters |
| `platform/orchestrator/` | Exported n8n workflows |
| `platform/metrics/` | Metrics schema and Grafana dashboards |
| `platform/deploy/` | docker-compose, environment example, Grafana provisioning |
| `data/` | Local runtime data, not tracked: `memory/` (clone of `ai-memory`), `workspaces/`, `logs/` |

## Repositories and connections

| What | Where |
|---|---|
| Pipeline configuration | this repository (personal GitHub) |
| Role memory | `ai-memory` (personal GitHub), cloned into `data/memory/` |
| Work repositories | work GitLab, accessed by roles through GitLab MCP and git |
| Jira, Confluence | Atlassian Rovo MCP, API token |
| Approvals, notifications | Telegram bot via n8n |
