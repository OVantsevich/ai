# Protocol

Formats shared by the orchestrator (n8n), the coordinator and all roles. Every message between components conforms to one of the schemas below.

| Schema | Who writes | Who reads |
|---|---|---|
| [task.schema.json](task.schema.json) | task form (manual input) | coordinator, orchestrator |
| [plan.schema.json](plan.schema.json) | coordinator | validator, orchestrator, human (approval) |
| [command.schema.json](command.schema.json) | orchestrator | role worker |
| [result.schema.json](result.schema.json) | role worker | orchestrator, coordinator |
| [event.schema.json](event.schema.json) | orchestrator, role workers | metrics (postgres, Grafana) |

Examples for each schema are in [examples/](examples/). `make check-protocol` validates them.

## Flow

```text
task ──► coordinator ──► plan (proposed) ──► validator ──► approval ──► plan (approved)
                                                                           │
             ┌─────────────────────────────────────────────────────────────┘
             ▼
  orchestrator: for each ready step ──► command ──► role ──► result
             ▲                                                  │
             └──── completed: next steps                       │
                   needs_approval: Telegram, then continue ◄───┤
                   blocked / failed: coordinator revises plan ◄┘
```

## References

Roles communicate through shared resources. A reference is a string `<system>:<locator>`:

| Prefix | Locator | Example |
|---|---|---|
| `gitlab` | project path, optionally `!MR`, `#issue`, `@ref` | `gitlab:payments-and-transfers/pat_online_payment_service!123` |
| `jira` | issue key | `jira:PAT-42` |
| `confluence` | page id | `confluence:123456789` |
| `url` | any URL | `url:https://example.com/doc` |

## Statuses

**Task**

| Status | Meaning |
|---|---|
| `new` | entered, not planned yet |
| `planning` | coordinator is building or revising the plan |
| `awaiting_approval` | plan sent for human approval |
| `running` | approved plan is being executed |
| `blocked` | cannot continue without human input |
| `done` | all steps completed |
| `failed` | stopped because of an error |
| `cancelled` | stopped by a human |

**Plan**: `proposed` → `approved` or `rejected`; a revision marks the previous version `superseded`.

**Step**

| Status | Meaning |
|---|---|
| `pending` | waits for steps in `after` |
| `ready` | dependencies completed, may start |
| `running` | a role run is in progress |
| `needs_approval` | role or plan requires a human decision |
| `blocked` | role reported missing information |
| `completed` | finished successfully |
| `failed` | finished with an error |
| `skipped` | removed by a plan revision or not needed |

**Run** (one execution of a role for a step; a step may have several runs: retries, continuation after approval): `running` → `completed`, `needs_approval`, `blocked` or `failed`.

## Approvals

- **Plan level**: the coordinator adds steps of type `human_approval`; the whole plan is always approved before execution.
- **Role level**: a role returns `needs_approval` with `pending_approval`. After the decision the orchestrator sends the role a `continue` command with the decision in `approval`.
- A plan may add approvals, but not remove approvals required by a role.
