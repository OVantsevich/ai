-- Orchestrator state machine test. Runs in a transaction and rolls back (`make test-orch`).
\set ON_ERROR_STOP on
SET client_min_messages = warning;
BEGIN;

CREATE FUNCTION pg_temp.result(p_run text, p_status text, p_extra jsonb DEFAULT '{}') RETURNS jsonb
LANGUAGE sql AS $$
    SELECT orch(jsonb_build_object('type', 'result', 'result',
        jsonb_build_object('run_id', p_run, 'role', 'x', 'status', p_status, 'summary', 'test ' || p_status) || p_extra));
$$;

CREATE FUNCTION pg_temp.runs(p_actions jsonb) RETURNS text
LANGUAGE sql AS $$
    SELECT coalesce(string_agg(a->'command'->>'run_id' || ':' || (a->'command'->>'command'), ',' ORDER BY n), '')
      FROM jsonb_array_elements(p_actions) WITH ORDINALITY e(a, n) WHERE a->>'type' = 'run';
$$;

CREATE FUNCTION pg_temp.approval(p_actions jsonb) RETURNS bigint
LANGUAGE sql AS $$
    SELECT (a->>'approval_id')::bigint FROM jsonb_array_elements(p_actions) a WHERE a ? 'approval_id' LIMIT 1;
$$;

DO $$
DECLARE
    a jsonb;
    t bigint;
    ap bigint;
    plan jsonb := '{
      "task_id": 1, "version": 1, "reason": "test",
      "steps": [
        {"id": "analyze", "type": "role", "role": "business-analyst", "command": "analyze", "text": "req"},
        {"id": "implement", "type": "role", "role": "go-developer", "command": "implement", "text": "code", "after": ["analyze"]},
        {"id": "check", "type": "human_approval", "text": "look", "after": ["implement"]},
        {"id": "verify", "type": "role", "role": "qa-engineer", "command": "verify", "text": "qa", "after": ["check"]}
      ]}';
BEGIN
    PERFORM orch('{"type": "roles", "cards": [
        {"id": "coordinator", "commands": [{"name": "plan"}, {"name": "replan"}]},
        {"id": "business-analyst", "commands": [{"name": "analyze"}]},
        {"id": "go-developer", "commands": [{"name": "implement"}], "approvals": [{"action": "gitlab.create_mr"}]},
        {"id": "qa-engineer", "commands": [{"name": "verify"}]}]}');

    -- task -> coordinator plan
    a := orch('{"type": "task.create", "title": "Test", "text": "do it", "refs": ["gitlab:g/p", "PAT-1", "https://x.y/z"]}');
    SELECT max(id) INTO t FROM tasks;
    ASSERT (SELECT refs FROM tasks WHERE id = t) = '["gitlab:g/p", "url:https://x.y/z"]', 'refs normalized';
    ASSERT pg_temp.runs(a) = format('t%s-plan-1:plan', t), 'plan command: ' || pg_temp.runs(a);
    ASSERT a->1->'command'->'context'->'roles' IS NOT NULL, 'roles catalog in context';

    -- invalid plan -> question
    a := pg_temp.result(format('t%s-plan-1', t), 'completed',
        jsonb_build_object('plan', jsonb_set(plan, '{steps,0,role}', '"designer"')));
    ASSERT a->0->>'text' LIKE '%unknown role designer%', 'invalid plan reported';
    ASSERT (SELECT status FROM tasks WHERE id = t) = 'blocked';
    a := orch(jsonb_build_object('type', 'decision', 'approval_id', pg_temp.approval(a), 'decision', 'approved', 'comment', 'use known roles'));
    ASSERT pg_temp.runs(a) = format('t%s-plan-2:plan', t), 'plan asked again: ' || pg_temp.runs(a);

    -- valid plan -> approval with buttons
    a := pg_temp.result(format('t%s-plan-2', t), 'completed', jsonb_build_object('plan', plan));
    ap := pg_temp.approval(a);
    ASSERT a->0 ? 'buttons', 'plan approval has buttons';
    ASSERT (SELECT status FROM tasks WHERE id = t) = 'awaiting_approval';
    PERFORM orch(jsonb_build_object('type', 'message', 'approval_id', ap, 'message_id', 555));

    -- approve -> first step starts
    a := orch(jsonb_build_object('type', 'decision', 'approval_id', ap, 'decision', 'approved'));
    ASSERT pg_temp.runs(a) = format('t%s-analyze-1:analyze', t), 'analyze started: ' || pg_temp.runs(a);
    ASSERT a->1->'command'->'refs' = '["gitlab:g/p", "url:https://x.y/z"]', 'task refs passed to step';
    ASSERT orch(jsonb_build_object('type', 'decision', 'approval_id', ap, 'decision', 'approved')) = '[]', 'decision is idempotent';

    a := pg_temp.result(format('t%s-analyze-1', t), 'completed', '{"refs": ["jira:PAT-1"]}');
    ASSERT pg_temp.runs(a) = format('t%s-implement-1:implement', t), 'implement started';
    ASSERT a->1->'command'->'context'->'previous'->0->>'step_id' = 'analyze', 'previous results passed';

    -- role approval -> continue
    a := pg_temp.result(format('t%s-implement-1', t), 'needs_approval',
        '{"pending_approval": {"action": "gitlab.create_mr", "description": "open MR"}}');
    ap := pg_temp.approval(a);
    ASSERT ap IS NOT NULL AND a->0 ? 'buttons', 'role approval requested';
    a := orch(jsonb_build_object('type', 'decision', 'approval_id', ap, 'decision', 'approved'));
    ASSERT pg_temp.runs(a) = format('t%s-implement-2:continue', t), 'continue sent: ' || pg_temp.runs(a);
    ASSERT a->1->'command'->'approval'->>'decision' = 'approved';

    -- blocked -> replan
    a := pg_temp.result(format('t%s-implement-2', t), 'blocked', '{"questions": ["which API?"]}');
    ASSERT pg_temp.runs(a) = format('t%s-plan-3:replan', t), 'replan asked: ' || pg_temp.runs(a);
    ASSERT (SELECT payload->>'trigger' FROM events WHERE run_id = format('t%s-plan-3', t)) = 'blocked';

    a := pg_temp.result(format('t%s-plan-3', t), 'completed', jsonb_build_object('plan', plan));
    ASSERT (SELECT trigger FROM plans WHERE task_id = t AND version = 2) = 'blocked', 'revision trigger stored';
    a := orch(jsonb_build_object('type', 'decision', 'approval_id', pg_temp.approval(a), 'decision', 'approved'));
    ASSERT pg_temp.runs(a) = format('t%s-implement-3:implement', t), 'completed analyze kept, implement retried: ' || pg_temp.runs(a);

    -- human approval step, answered by a reply
    a := pg_temp.result(format('t%s-implement-3', t), 'completed');
    ap := pg_temp.approval(a);
    ASSERT (SELECT level FROM approvals WHERE id = ap) = 'step', 'human step asks approval';
    PERFORM orch(jsonb_build_object('type', 'message', 'approval_id', ap, 'message_id', 777));
    a := orch('{"type": "decision", "approval_id": 0, "decision": "approved"}');
    ASSERT a = '[]';
    a := orch(jsonb_build_object('type', 'decision', 'approval_id', ap, 'decision', 'approved', 'comment', 'ok'));
    ASSERT pg_temp.runs(a) = format('t%s-verify-1:verify', t), 'verify started';

    -- last step -> done with report
    a := pg_temp.result(format('t%s-verify-1', t), 'completed');
    ASSERT (SELECT status FROM tasks WHERE id = t) = 'done', 'task done';
    ASSERT a->1->>'text' LIKE '🏁%', 'final report sent';

    -- reply to an unknown message, dispatch failure on a new task
    ASSERT orch('{"type": "reply", "message_id": 1, "text": "?"}')->0->>'text' LIKE '%не ждёт%';
    a := orch('{"type": "task.create", "title": "Second", "text": "x"}');
    a := orch(jsonb_build_object('type', 'dispatch_failed', 'run_id', a->1->'command'->>'run_id', 'role', 'coordinator', 'error', 'connection refused'));
    ASSERT a->0->>'text' LIKE '❓%connection refused%', 'dispatch failure asks human';
    ASSERT orch(jsonb_build_object('type', 'reply', 'message_id', 0, 'text', 'retry')) IS NOT NULL;

END;
$$;

ROLLBACK;
\echo orchestrator test passed
