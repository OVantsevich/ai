# Architecture

## Principles

- **Independent roles.** A role directory contains everything the role uses. Roles do not reference each other or shared skills.
- **Coordinator plans, orchestrator executes.** The coordinator role builds a plan for each task, using playbooks only as recommendations. n8n executes the approved plan and asks the coordinator to re-plan on `BLOCKED`, `FAILED`, or new information.
- **Communication through shared resources.** Roles exchange results via GitLab, Jira and Confluence, and via short text commands routed through the orchestrator.
- **Repository-agnostic process.** The target repository is task data. Roles discover build and check commands from the repository itself.
- **Engine-agnostic roles.** The worker prepares the workspace and calls `platform/worker/engines/<engine>`. The `stub` engine allows running the whole process without an LLM.
- **Everything is measured.** Every component writes events in one format; Grafana builds dashboards from them.

## Components

```text
n8n (orchestrator)
  ├── task form (manual input)
  ├── plan approval and role approvals (Telegram)
  └── plan executor ──► role containers (HTTP: /hooks/run)
                           ├── role-coordinator
                           ├── role-business-analyst
                           ├── role-go-developer
                           └── role-qa-engineer
                                 │
                                 ├── gitlab-mcp-ro / gitlab-mcp-rw ──► work GitLab
                                 ├── Atlassian Rovo MCP ──► Jira, Confluence
                                 └── data/memory/<role>/   (only its own)
postgres: plan and step state, events
grafana:  dashboards over postgres
```

## Task lifecycle

1. Task is entered manually in the n8n form.
2. Coordinator reads Jira/GitLab, picks a playbook as a basis, and proposes a plan.
3. The plan is validated: roles exist, commands are supported, role approvals are kept.
4. The plan is sent to Telegram for approval.
5. n8n executes steps; a role may request approval for actions listed in its `role.yaml`.
6. On `BLOCKED` or `FAILED` the coordinator revises the plan.
7. The final report with links is sent to Telegram.

## Approvals

| Level | Defined in |
|---|---|
| Role | `approvals` in `roles/<role>/role.yaml` |
| Process | `human-approval` steps added by the coordinator to the plan |

The stricter rule wins: a plan may add approvals but not remove those required by a role.

## Memory

- Accumulated memory lives in `data/memory/<role>/{_global,<group>__<project>}/*.md`.
- `data/memory/` is a separate git repository (`ai-memory`); `run.sh` commits after each run, `make memory-push` pushes.
- Each role container mounts only its own memory directory.
- `roles/<role>/memory/` holds the memory format description and seed knowledge.
