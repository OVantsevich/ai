# Metrics

Grafana dashboards over the platform PostgreSQL. Datasource `ai-postgres` and folder **AI Pipeline** are provisioned from `platform/deploy/grafana/`.

| Dashboard | File | Shows |
|---|---|---|
| [Overview](http://localhost:3000/d/ai-overview) | `dashboards/overview.json` | tasks by status, where each task is, created over time, role time per finished task |
| [Roles](http://localhost:3000/d/ai-roles) | `dashboards/roles.json` | duration, success / blocked / failed, p50/p95, LLM usage |
| [Bottlenecks](http://localhost:3000/d/ai-bottlenecks) | `dashboards/bottlenecks.json` | approval wait, step queue, role↔role handoffs, blocked/failed steps |
| [Planning](http://localhost:3000/d/ai-planning) | `dashboards/planning.json` | playbooks, revisions, first-plan approve rate, plan vs actual |

Dashboards are mounted read-only. Edit the JSON here and restart Grafana (`docker compose … restart grafana`), or change them in the UI and export back into this directory.
