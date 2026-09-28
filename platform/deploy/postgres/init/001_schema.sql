-- Platform state and metrics events. Statuses: platform/protocol/README.md.
-- Idempotent: applied on first start (docker-entrypoint-initdb.d) and by `make db-apply`.

SET client_min_messages = warning;

CREATE TABLE IF NOT EXISTS tasks (
    id          bigserial PRIMARY KEY,
    title       text        NOT NULL,
    text        text        NOT NULL,
    refs        jsonb       NOT NULL DEFAULT '[]',
    status      text        NOT NULL DEFAULT 'new'
                CHECK (status IN ('new', 'planning', 'awaiting_approval', 'running',
                                  'blocked', 'done', 'failed', 'cancelled')),
    created_at  timestamptz NOT NULL DEFAULT now(),
    updated_at  timestamptz NOT NULL DEFAULT now(),
    finished_at timestamptz
);

CREATE TABLE IF NOT EXISTS plans (
    id          bigserial PRIMARY KEY,
    task_id     bigint      NOT NULL REFERENCES tasks (id) ON DELETE CASCADE,
    version     int         NOT NULL,
    basis       text,
    reason      text        NOT NULL,
    body        jsonb       NOT NULL,
    status      text        NOT NULL DEFAULT 'proposed'
                CHECK (status IN ('proposed', 'approved', 'rejected', 'superseded')),
    trigger     text
                CHECK (trigger IN ('blocked', 'failed', 'rejected', 'new_info')),
    created_at  timestamptz NOT NULL DEFAULT now(),
    decided_at  timestamptz,
    UNIQUE (task_id, version)
);

CREATE TABLE IF NOT EXISTS steps (
    id          bigserial PRIMARY KEY,
    plan_id     bigint      NOT NULL REFERENCES plans (id) ON DELETE CASCADE,
    task_id     bigint      NOT NULL REFERENCES tasks (id) ON DELETE CASCADE,
    step_key    text        NOT NULL,
    type        text        NOT NULL CHECK (type IN ('role', 'human_approval')),
    role        text,
    command     text,
    text        text        NOT NULL,
    refs        jsonb       NOT NULL DEFAULT '[]',
    after       text[]      NOT NULL DEFAULT '{}',
    status      text        NOT NULL DEFAULT 'pending'
                CHECK (status IN ('pending', 'ready', 'running', 'needs_approval',
                                  'blocked', 'completed', 'failed', 'skipped')),
    summary     text,
    result_refs jsonb       NOT NULL DEFAULT '[]',
    ready_at    timestamptz,
    started_at  timestamptz,
    finished_at timestamptz,
    UNIQUE (plan_id, step_key),
    CHECK (type = 'human_approval' OR (role IS NOT NULL AND command IS NOT NULL))
);

CREATE TABLE IF NOT EXISTS runs (
    id          text PRIMARY KEY,
    step_id     bigint      REFERENCES steps (id) ON DELETE CASCADE,
    task_id     bigint      NOT NULL REFERENCES tasks (id) ON DELETE CASCADE,
    role        text        NOT NULL,
    command     text        NOT NULL,
    engine      text,
    attempt     int         NOT NULL DEFAULT 1,
    status      text        NOT NULL DEFAULT 'running'
                CHECK (status IN ('running', 'completed', 'needs_approval', 'blocked', 'failed')),
    started_at  timestamptz NOT NULL DEFAULT now(),
    finished_at timestamptz,
    duration_ms bigint GENERATED ALWAYS AS
                ((extract(epoch FROM finished_at - started_at) * 1000)::bigint) STORED,
    model       text,
    tokens_in   bigint,
    tokens_out  bigint,
    cost_usd    numeric(12, 4),
    turns       int,
    result      jsonb
);

CREATE TABLE IF NOT EXISTS approvals (
    id           bigserial PRIMARY KEY,
    task_id      bigint      NOT NULL REFERENCES tasks (id) ON DELETE CASCADE,
    plan_id      bigint      REFERENCES plans (id) ON DELETE CASCADE,
    step_id      bigint      REFERENCES steps (id) ON DELETE CASCADE,
    run_id       text        REFERENCES runs (id) ON DELETE CASCADE,
    level        text        NOT NULL CHECK (level IN ('plan', 'step', 'role')),
    action       text,
    description  text        NOT NULL,
    status       text        NOT NULL DEFAULT 'pending'
                 CHECK (status IN ('pending', 'approved', 'rejected')),
    comment      text,
    requested_at timestamptz NOT NULL DEFAULT now(),
    decided_at   timestamptz,
    wait_ms      bigint GENERATED ALWAYS AS
                 ((extract(epoch FROM decided_at - requested_at) * 1000)::bigint) STORED
);

CREATE TABLE IF NOT EXISTS events (
    id           bigserial PRIMARY KEY,
    ts           timestamptz NOT NULL DEFAULT now(),
    type         text        NOT NULL,
    task_id      bigint      REFERENCES tasks (id) ON DELETE CASCADE,
    plan_version int,
    step_key     text,
    run_id       text,
    role         text,
    payload      jsonb       NOT NULL DEFAULT '{}'
);

CREATE INDEX IF NOT EXISTS steps_task_status_idx   ON steps (task_id, status);
CREATE INDEX IF NOT EXISTS runs_role_started_idx   ON runs (role, started_at);
CREATE INDEX IF NOT EXISTS runs_task_idx           ON runs (task_id);
CREATE INDEX IF NOT EXISTS approvals_pending_idx   ON approvals (status) WHERE status = 'pending';
CREATE INDEX IF NOT EXISTS events_type_ts_idx      ON events (type, ts);
CREATE INDEX IF NOT EXISTS events_task_idx         ON events (task_id);
CREATE INDEX IF NOT EXISTS events_role_ts_idx      ON events (role, ts);

CREATE OR REPLACE FUNCTION touch_updated_at() RETURNS trigger AS $$
BEGIN
    NEW.updated_at := now();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS tasks_touch_updated_at ON tasks;
CREATE TRIGGER tasks_touch_updated_at
    BEFORE UPDATE ON tasks
    FOR EACH ROW EXECUTE FUNCTION touch_updated_at();
