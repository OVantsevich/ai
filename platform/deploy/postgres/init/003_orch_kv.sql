-- Key/value for orchestrator helpers (Telegram getUpdates offset, etc.).
CREATE TABLE IF NOT EXISTS orch_kv (
    key        text PRIMARY KEY,
    value      text        NOT NULL,
    updated_at timestamptz NOT NULL DEFAULT now()
);
