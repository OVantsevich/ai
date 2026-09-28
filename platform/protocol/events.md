# Events

Every component writes events to the `events` table. Grafana dashboards are built from events and from the state tables (`tasks`, `plans`, `steps`, `runs`, `approvals`).

| Type | Written by | Payload |
|---|---|---|
| `task.created` | orchestrator | `title` |
| `task.status_changed` | orchestrator | `from`, `to` |
| `plan.proposed` | orchestrator | `basis`, `steps` (count) |
| `plan.approved` | orchestrator | `wait_ms` (time from proposal) |
| `plan.rejected` | orchestrator | `comment` |
| `plan.revised` | orchestrator | `from_version`, `trigger` (`blocked`, `failed`, `rejected`, `new_info`) |
| `step.ready` | orchestrator | — |
| `step.started` | orchestrator | `queue_ms` (time from ready) |
| `step.completed` | orchestrator | `duration_ms`, `runs` |
| `step.blocked` | orchestrator | `questions` (count) |
| `step.failed` | orchestrator | `error` |
| `step.skipped` | orchestrator | `reason` |
| `run.started` | role worker | `command`, `engine`, `attempt` |
| `run.finished` | role worker | `status`, `duration_ms` |
| `approval.requested` | orchestrator | `level` (`plan`, `step`, `role`), `action` |
| `approval.granted` | orchestrator | `level`, `action`, `wait_ms` |
| `approval.rejected` | orchestrator | `level`, `action`, `wait_ms`, `comment` |
| `command.sent` | orchestrator | `from` (role or `human`), `to`, `command` |
| `llm.usage` | role worker | `model`, `tokens_in`, `tokens_out`, `cost_usd`, `turns` |
| `memory.updated` | role worker | `project`, `files` (count) |

## Derived metrics

| Metric | Source |
|---|---|
| Time per role, success rate, share of `blocked` | `runs` |
| Queue time, approval wait | `step.started.queue_ms`, `approval.*.wait_ms` |
| Loops between roles (review → dev → review) | `command.sent` pairs within a task |
| Plan vs actual, revisions per task | `plans`, `plan.revised` |
| Playbook usage | `plans.basis` |
| Cost and tokens per role and task | `llm.usage` |
