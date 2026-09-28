# Orchestrator

n8n turns triggers into events and executes actions; the decisions are made by `orch(event)` in PostgreSQL ([002_orchestrator.sql](../deploy/postgres/init/002_orchestrator.sql)), so the state machine is tested without n8n (`make test-orch`).

| Workflow | Trigger | Event |
|---|---|---|
| `AI: task form` | form http://localhost:5678/form/task | `roles` (catalog from `GET /role`), `task.create` |
| `AI: role result` | `POST /webhook/role-result` (worker `callback_url`) | `result` |
| `AI: telegram` | every 3 s, `getUpdates` | `decision` (buttons), `reply` (reply to an approval message) |
| `AI: engine` | called by the workflows above | runs `orch()`, sends commands to roles and Telegram messages, feeds follow-up events back |

Telegram is polled, not a webhook, so buttons and replies work from a phone without a tunnel.

## Flow

1. Form → task → `coordinator plan` with the role catalog.
2. Plan is validated (roles, commands, `after`, cycles) → Telegram with buttons. A reply to the message rejects it with a comment.
3. Approved plan → steps whose `after` are completed start; `human_approval` steps ask in Telegram.
4. `needs_approval` from a role → Telegram → `continue` with the decision.
5. `blocked` / `failed` / rejected plan → `coordinator replan`; completed steps with the same id are kept. At most 5 plan versions per task.
6. A coordinator failure, an invalid plan or an undelivered command becomes a question in Telegram; the reply goes to the coordinator.
7. All steps completed → final report.

## Deploy

```bash
make n8n-import   # imports the Postgres credential and workflows, publishes them, restarts n8n
make test-orch    # state machine test, rolled back
```

Workflows are edited in this directory; changes made in the n8n editor are lost on the next import.
