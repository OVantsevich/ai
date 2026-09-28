-- Orchestrator state machine. n8n turns triggers into events, calls orch(event)
-- and executes the returned actions:
--   {"type": "run", "url": ..., "command": {...}}          POST the command to a role worker
--   {"type": "telegram", "text": ..., "approval_id": ...}  send a message; approval messages get buttons
-- Input events:
--   roles            {"cards": [GET /role of each worker]}
--   task.create      {"title", "text", "refs"}
--   result           {"result": <result from a worker callback>}
--   dispatch_failed  {"run_id", "role", "error"}            the command could not be delivered
--   decision         {"approval_id", "decision": approved|rejected, "comment"}
--   reply            {"message_id", "text"}                 Telegram reply to an approval message
--   message          {"approval_id", "message_id"}          Telegram message id of an approval
-- Idempotent: applied on first start and by `make db-apply`.

SET client_min_messages = warning;

ALTER TABLE approvals ADD COLUMN IF NOT EXISTS tg_message_id bigint;
CREATE INDEX IF NOT EXISTS approvals_tg_message_idx ON approvals (tg_message_id);
CREATE INDEX IF NOT EXISTS events_run_idx ON events (run_id);

CREATE TABLE IF NOT EXISTS roles (
    id         text PRIMARY KEY,
    card       jsonb       NOT NULL,
    updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE OR REPLACE FUNCTION orch_callback_url() RETURNS text
LANGUAGE sql IMMUTABLE AS $$ SELECT 'http://n8n:5678/webhook/role-result' $$;

CREATE OR REPLACE FUNCTION orch_max_plan_versions() RETURNS int
LANGUAGE sql IMMUTABLE AS $$ SELECT 5 $$;

CREATE OR REPLACE FUNCTION orch_event(
    p_type text, p_task bigint, p_payload jsonb DEFAULT '{}',
    p_step text DEFAULT NULL, p_run text DEFAULT NULL, p_role text DEFAULT NULL, p_plan_version int DEFAULT NULL
) RETURNS void LANGUAGE sql AS $$
    INSERT INTO events (type, task_id, plan_version, step_key, run_id, role, payload)
    VALUES (p_type, p_task, p_plan_version, p_step, p_run, p_role, coalesce(p_payload, '{}'));
$$;

CREATE OR REPLACE FUNCTION orch_task_status(p_task bigint, p_status text) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
    v_from text;
BEGIN
    SELECT status INTO v_from FROM tasks WHERE id = p_task FOR UPDATE;
    IF v_from IS DISTINCT FROM p_status THEN
        UPDATE tasks
           SET status = p_status,
               finished_at = CASE WHEN p_status IN ('done', 'failed', 'cancelled') THEN now() END
         WHERE id = p_task;
        PERFORM orch_event('task.status_changed', p_task, jsonb_build_object('from', v_from, 'to', p_status));
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION orch_tg(p_text text, p_approval bigint DEFAULT NULL, p_buttons boolean DEFAULT false)
RETURNS jsonb LANGUAGE sql AS $$
    SELECT jsonb_strip_nulls(jsonb_build_object(
        'type', 'telegram',
        'text', left(p_text, 4000),
        'approval_id', p_approval,
        'buttons', CASE WHEN p_buttons THEN jsonb_build_array(jsonb_build_array(
            jsonb_build_object('text', '✅ Одобрить', 'callback_data', format('ap:%s:a', p_approval)),
            jsonb_build_object('text', '❌ Отклонить', 'callback_data', format('ap:%s:r', p_approval))
        )) END
    ));
$$;

CREATE OR REPLACE FUNCTION orch_task_json(p_task bigint) RETURNS jsonb
LANGUAGE sql STABLE AS $$
    SELECT jsonb_build_object('id', id, 'title', title, 'text', text, 'refs', refs,
                              'created_at', to_char(created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'))
      FROM tasks WHERE id = p_task;
$$;

CREATE OR REPLACE FUNCTION orch_current_plan(p_task bigint) RETURNS plans
LANGUAGE sql STABLE AS $$
    SELECT * FROM plans WHERE task_id = p_task AND status = 'approved' ORDER BY version DESC LIMIT 1;
$$;

CREATE OR REPLACE FUNCTION orch_previous(p_task bigint) RETURNS jsonb
LANGUAGE sql STABLE AS $$
    SELECT coalesce(jsonb_agg(jsonb_build_object(
               'step_id', s.step_key,
               'role', coalesce(s.role, 'human'),
               'status', s.status,
               'summary', coalesce(s.summary, ''),
               'refs', s.result_refs) ORDER BY s.finished_at NULLS LAST, s.id), '[]')
      FROM steps s
     WHERE s.plan_id = (orch_current_plan(p_task)).id
       AND s.status IN ('completed', 'blocked', 'failed', 'skipped');
$$;

-- Distinct refs of both arrays, order kept.
CREATE OR REPLACE FUNCTION orch_refs(a jsonb, b jsonb) RETURNS jsonb
LANGUAGE sql IMMUTABLE AS $$
    SELECT coalesce(jsonb_agg(ref ORDER BY first), '[]')
      FROM (SELECT ref, min(n) AS first
              FROM jsonb_array_elements(coalesce(a, '[]') || coalesce(b, '[]')) WITH ORDINALITY AS e(ref, n)
             GROUP BY ref) x;
$$;

CREATE OR REPLACE FUNCTION orch_run_action(p_kind text, p_task bigint, p_step text, p_role text,
                                           p_from text, p_command jsonb, p_trigger text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_run text;
    v_n int;
BEGIN
    SELECT count(*) + 1 INTO v_n FROM events
     WHERE type = 'command.sent' AND task_id = p_task
       AND payload->>'kind' = p_kind AND step_key IS NOT DISTINCT FROM p_step;
    v_run := format('t%s-%s-%s', p_task, coalesce(p_step, 'plan'), v_n);
    PERFORM orch_event('command.sent', p_task,
        jsonb_strip_nulls(jsonb_build_object('from', p_from, 'to', p_role, 'command', p_command->>'command',
                                             'kind', p_kind, 'trigger', p_trigger)),
        p_step, v_run, p_role);
    RETURN jsonb_build_object(
        'type', 'run',
        'url', format('http://role-%s:9000/runs', p_role),
        'command', p_command || jsonb_build_object('run_id', v_run, 'task_id', p_task, 'role', p_role,
                                                   'callback_url', orch_callback_url()));
END;
$$;

CREATE OR REPLACE FUNCTION orch_coordinator(p_task bigint, p_text text, p_trigger text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_plan plans;
    v_context jsonb;
BEGIN
    IF (SELECT count(*) FROM plans WHERE task_id = p_task) >= orch_max_plan_versions() THEN
        PERFORM orch_task_status(p_task, 'failed');
        RETURN jsonb_build_array(orch_tg(format('🛑 Задача #%s остановлена: достигнут лимит в %s версий плана.',
                                                p_task, orch_max_plan_versions())));
    END IF;
    PERFORM orch_task_status(p_task, 'planning');
    v_plan := orch_current_plan(p_task);
    v_context := jsonb_build_object(
        'task', orch_task_json(p_task),
        'roles', (SELECT coalesce(jsonb_agg(card ORDER BY id), '[]') FROM roles));
    IF v_plan.id IS NOT NULL THEN
        v_context := v_context || jsonb_build_object('plan', v_plan.body, 'previous', orch_previous(p_task));
    END IF;
    RETURN jsonb_build_array(orch_run_action('plan', p_task, NULL, 'coordinator', 'orchestrator',
        jsonb_build_object(
            'command', CASE WHEN v_plan.id IS NULL THEN 'plan' ELSE 'replan' END,
            'text', p_text,
            'refs', (SELECT refs FROM tasks WHERE id = p_task),
            'context', v_context),
        p_trigger));
END;
$$;

CREATE OR REPLACE FUNCTION orch_validate_plan(p_plan jsonb) RETURNS text[]
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_errors text[] := '{}';
    v_step jsonb;
    v_card jsonb;
    v_ids text[];
    v_done text[] := '{}';
    v_progress boolean := true;
BEGIN
    SELECT array_agg(s->>'id') INTO v_ids FROM jsonb_array_elements(p_plan->'steps') s;
    IF (SELECT count(DISTINCT x) FROM unnest(v_ids) x) <> cardinality(v_ids) THEN
        v_errors := v_errors || 'step ids are not unique'::text;
    END IF;
    FOR v_step IN SELECT * FROM jsonb_array_elements(p_plan->'steps') LOOP
        IF v_step->>'type' = 'role' THEN
            SELECT card INTO v_card FROM roles WHERE id = v_step->>'role';
            IF v_card IS NULL THEN
                v_errors := v_errors || format('step %s: unknown role %s', v_step->>'id', v_step->>'role');
            ELSIF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_card->'commands') c
                               WHERE c->>'name' = v_step->>'command') THEN
                v_errors := v_errors || format('step %s: role %s has no command %s',
                                               v_step->>'id', v_step->>'role', v_step->>'command');
            END IF;
        END IF;
        IF EXISTS (SELECT 1 FROM jsonb_array_elements_text(coalesce(v_step->'after', '[]')) a
                    WHERE a = v_step->>'id' OR NOT a = ANY (v_ids)) THEN
            v_errors := v_errors || format('step %s: after refers to itself or an unknown step', v_step->>'id');
        END IF;
    END LOOP;
    WHILE v_progress LOOP
        v_progress := false;
        FOR v_step IN SELECT * FROM jsonb_array_elements(p_plan->'steps') LOOP
            IF NOT (v_step->>'id') = ANY (v_done)
               AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements_text(coalesce(v_step->'after', '[]')) a
                                WHERE NOT a = ANY (v_done)) THEN
                v_done := v_done || (v_step->>'id');
                v_progress := true;
            END IF;
        END LOOP;
    END LOOP;
    IF cardinality(v_done) < cardinality(v_ids) THEN
        v_errors := v_errors || 'steps form a cycle'::text;
    END IF;
    RETURN v_errors;
END;
$$;

CREATE OR REPLACE FUNCTION orch_plan_text(p_task bigint, p_plan plans) RETURNS text
LANGUAGE sql STABLE AS $$
    SELECT format(E'📋 Задача #%s: %s\nПлан v%s%s\n%s\n\n%s%s\n\nОдобрить план? Ответ на сообщение = отклонить с комментарием.',
        t.id, t.title, p_plan.version,
        CASE WHEN p_plan.basis IS NOT NULL THEN format(' (основа: %s)', p_plan.basis) ELSE '' END,
        p_plan.reason,
        (SELECT string_agg(format('%s. %s — %s%s%s', n, s->>'id',
                    CASE WHEN s->>'type' = 'role' THEN format('%s %s: ', s->>'role', s->>'command')
                         ELSE 'человек: ' END,
                    s->>'text',
                    CASE WHEN jsonb_array_length(coalesce(s->'after', '[]')) > 0
                         THEN format(' [после: %s]', (SELECT string_agg(a, ', ')
                                                        FROM jsonb_array_elements_text(s->'after') a))
                         ELSE '' END), E'\n' ORDER BY n)
           FROM jsonb_array_elements(p_plan.body->'steps') WITH ORDINALITY AS e(s, n)),
        coalesce(E'\n\nОдобрения ролей: ' || (
            SELECT string_agg(DISTINCT format('%s: %s', r.id, a->>'action'), '; ')
              FROM jsonb_array_elements(p_plan.body->'steps') s
              JOIN roles r ON r.id = s->>'role'
              CROSS JOIN jsonb_array_elements(coalesce(r.card->'approvals', '[]')) a), ''))
      FROM tasks t WHERE t.id = p_task;
$$;

CREATE OR REPLACE FUNCTION orch_ask(p_task bigint, p_text text) RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
    v_approval bigint;
BEGIN
    PERFORM orch_task_status(p_task, 'blocked');
    INSERT INTO approvals (task_id, level, action, description)
    VALUES (p_task, 'plan', 'coordinator.question', p_text) RETURNING id INTO v_approval;
    PERFORM orch_event('approval.requested', p_task, jsonb_build_object('level', 'plan', 'action', 'coordinator.question'));
    RETURN jsonb_build_array(orch_tg(format(E'❓ Задача #%s: %s\n\nОтветь на это сообщение, чтобы coordinator перепланировал задачу.',
                                            p_task, p_text), v_approval));
END;
$$;

CREATE OR REPLACE FUNCTION orch_on_plan_result(p_task bigint, p_result jsonb, p_trigger text) RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
    v_errors text[];
    v_version int;
    v_plan plans;
    v_approval bigint;
BEGIN
    IF p_result->>'status' <> 'completed' OR p_result->'plan' IS NULL THEN
        RETURN orch_ask(p_task, format('coordinator: %s — %s%s', p_result->>'status', p_result->>'summary',
            coalesce(E'\n' || (p_result->>'error'), '') ||
            coalesce(E'\n' || (SELECT string_agg('• ' || q, E'\n') FROM jsonb_array_elements_text(p_result->'questions') q), '')));
    END IF;
    v_errors := orch_validate_plan(p_result->'plan');
    IF cardinality(v_errors) > 0 THEN
        RETURN orch_ask(p_task, E'план не прошёл проверку:\n• ' || array_to_string(v_errors, E'\n• '));
    END IF;

    SELECT coalesce(max(version), 0) + 1 INTO v_version FROM plans WHERE task_id = p_task;
    UPDATE plans SET status = 'superseded', decided_at = now() WHERE task_id = p_task AND status = 'proposed';
    UPDATE approvals SET status = 'rejected', decided_at = now(), comment = 'superseded'
     WHERE task_id = p_task AND status = 'pending' AND level = 'plan';
    INSERT INTO plans (task_id, version, basis, reason, body, trigger)
    VALUES (p_task, v_version, p_result->'plan'->>'basis', p_result->'plan'->>'reason',
            p_result->'plan' || jsonb_build_object('task_id', p_task, 'version', v_version), p_trigger)
    RETURNING * INTO v_plan;
    PERFORM orch_event('plan.proposed', p_task,
        jsonb_build_object('basis', v_plan.basis, 'steps', jsonb_array_length(v_plan.body->'steps')),
        p_plan_version => v_version);
    IF v_version > 1 THEN
        PERFORM orch_event('plan.revised', p_task,
            jsonb_build_object('from_version', v_version - 1, 'trigger', p_trigger), p_plan_version => v_version);
    END IF;
    INSERT INTO approvals (task_id, plan_id, level, action, description)
    VALUES (p_task, v_plan.id, 'plan', 'plan.approve', format('План v%s', v_version)) RETURNING id INTO v_approval;
    PERFORM orch_event('approval.requested', p_task, jsonb_build_object('level', 'plan', 'action', 'plan.approve'),
                       p_plan_version => v_version);
    PERFORM orch_task_status(p_task, 'awaiting_approval');
    RETURN jsonb_build_array(orch_tg(orch_plan_text(p_task, v_plan), v_approval, true));
END;
$$;

CREATE OR REPLACE FUNCTION orch_final_report(p_task bigint) RETURNS jsonb
LANGUAGE sql STABLE AS $$
    SELECT orch_tg(format(E'🏁 Задача #%s выполнена: %s\n\nВремя: %s мин · запусков ролей: %s · версий плана: %s · ожидание одобрений: %s мин\n\n%s',
        t.id, t.title,
        round(extract(epoch FROM now() - t.created_at) / 60, 1),
        (SELECT count(*) FROM runs WHERE task_id = t.id),
        (SELECT count(*) FROM plans WHERE task_id = t.id),
        (SELECT round(coalesce(sum(wait_ms), 0) / 60000.0, 1) FROM approvals WHERE task_id = t.id AND status <> 'pending'),
        (SELECT string_agg(format('• %s (%s): %s%s', s.step_key, coalesce(s.role, 'человек'), coalesce(s.summary, s.status),
                    coalesce(E'\n  ' || (SELECT string_agg(r, E'\n  ') FROM jsonb_array_elements_text(s.result_refs) r), '')),
                E'\n' ORDER BY s.finished_at, s.id)
           FROM steps s WHERE s.plan_id = (orch_current_plan(t.id)).id)))
      FROM tasks t WHERE t.id = p_task;
$$;

CREATE OR REPLACE FUNCTION orch_advance(p_task bigint) RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
    v_plan plans;
    v_step steps;
    v_actions jsonb := '[]';
    v_approval bigint;
BEGIN
    IF (SELECT status FROM tasks WHERE id = p_task) <> 'running' THEN
        RETURN v_actions;
    END IF;
    v_plan := orch_current_plan(p_task);
    IF v_plan.id IS NULL OR EXISTS (SELECT 1 FROM steps WHERE plan_id = v_plan.id AND status IN ('blocked', 'failed')) THEN
        RETURN v_actions;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM steps WHERE plan_id = v_plan.id AND status NOT IN ('completed', 'skipped')) THEN
        PERFORM orch_task_status(p_task, 'done');
        RETURN jsonb_build_array(orch_final_report(p_task));
    END IF;

    FOR v_step IN
        UPDATE steps s SET status = CASE WHEN s.type = 'role' THEN 'running' ELSE 'needs_approval' END,
                           ready_at = now(),
                           started_at = CASE WHEN s.type = 'role' THEN now() END
         WHERE s.plan_id = v_plan.id AND s.status = 'pending'
           AND NOT EXISTS (SELECT 1 FROM steps d
                            WHERE d.plan_id = s.plan_id AND d.step_key = ANY (s.after)
                              AND d.status NOT IN ('completed', 'skipped'))
        RETURNING s.*
    LOOP
        PERFORM orch_event('step.ready', p_task, '{}', v_step.step_key, NULL, v_step.role, v_plan.version);
        IF v_step.type = 'role' THEN
            PERFORM orch_event('step.started', p_task, jsonb_build_object('queue_ms', 0),
                               v_step.step_key, NULL, v_step.role, v_plan.version);
            v_actions := v_actions || orch_run_action('step', p_task, v_step.step_key, v_step.role, 'coordinator',
                jsonb_build_object(
                    'step_id', v_step.step_key,
                    'command', v_step.command,
                    'text', v_step.text,
                    'refs', orch_refs(v_step.refs, (SELECT refs FROM tasks WHERE id = p_task)),
                    'context', jsonb_build_object('task', orch_task_json(p_task), 'plan', v_plan.body,
                                                  'previous', orch_previous(p_task))));
        ELSE
            INSERT INTO approvals (task_id, plan_id, step_id, level, action, description)
            VALUES (p_task, v_plan.id, v_step.id, 'step', 'human_approval', v_step.text) RETURNING id INTO v_approval;
            PERFORM orch_event('approval.requested', p_task, jsonb_build_object('level', 'step', 'action', 'human_approval'),
                               v_step.step_key, NULL, NULL, v_plan.version);
            v_actions := v_actions || orch_tg(format(E'🙋 Задача #%s, шаг %s:\n%s\n\nОтвет на сообщение = отклонить с комментарием.',
                                                     p_task, v_step.step_key, v_step.text), v_approval, true);
        END IF;
    END LOOP;
    RETURN v_actions;
END;
$$;

CREATE OR REPLACE FUNCTION orch_on_step_result(p_task bigint, p_step_key text, p_result jsonb) RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
    v_plan plans := orch_current_plan(p_task);
    v_step steps;
    v_status text := p_result->>'status';
    v_approval bigint;
    v_questions text;
BEGIN
    UPDATE steps SET status = v_status,
                     summary = p_result->>'summary',
                     result_refs = orch_refs(result_refs, p_result->'refs'),
                     finished_at = CASE WHEN v_status IN ('completed', 'blocked', 'failed') THEN now() END
     WHERE plan_id = v_plan.id AND step_key = p_step_key AND status = 'running'
    RETURNING * INTO v_step;
    IF v_step.id IS NULL THEN
        RETURN '[]';
    END IF;

    IF v_status = 'completed' THEN
        PERFORM orch_event('step.completed', p_task,
            jsonb_build_object('duration_ms', (extract(epoch FROM v_step.finished_at - v_step.started_at) * 1000)::bigint,
                               'runs', (SELECT count(*) FROM runs WHERE task_id = p_task AND step_id = v_step.id)),
            p_step_key, p_result->>'run_id', v_step.role, v_plan.version);
        RETURN jsonb_build_array(orch_tg(format('✅ #%s %s (%s): %s', p_task, p_step_key, v_step.role, p_result->>'summary')))
               || orch_advance(p_task);
    END IF;

    IF v_status = 'needs_approval' THEN
        INSERT INTO approvals (task_id, plan_id, step_id, run_id, level, action, description)
        VALUES (p_task, v_plan.id, v_step.id, (SELECT id FROM runs WHERE id = p_result->>'run_id'), 'role',
                p_result->'pending_approval'->>'action', p_result->'pending_approval'->>'description')
        RETURNING id INTO v_approval;
        PERFORM orch_event('approval.requested', p_task,
            jsonb_build_object('level', 'role', 'action', p_result->'pending_approval'->>'action'),
            p_step_key, p_result->>'run_id', v_step.role, v_plan.version);
        RETURN jsonb_build_array(orch_tg(format(E'🔐 Задача #%s, шаг %s: %s просит одобрить %s\n%s%s',
            p_task, p_step_key, v_step.role, p_result->'pending_approval'->>'action',
            p_result->'pending_approval'->>'description',
            coalesce(E'\n\n' || (p_result->'pending_approval'->>'details'), '')), v_approval, true));
    END IF;

    v_questions := (SELECT string_agg('• ' || q, E'\n') FROM jsonb_array_elements_text(p_result->'questions') q);
    PERFORM orch_event('step.' || v_status, p_task,
        CASE WHEN v_status = 'blocked'
             THEN jsonb_build_object('questions', jsonb_array_length(p_result->'questions'))
             ELSE jsonb_build_object('error', p_result->>'error') END,
        p_step_key, p_result->>'run_id', v_step.role, v_plan.version);
    RETURN jsonb_build_array(orch_tg(format(E'%s #%s %s (%s): %s%s', CASE WHEN v_status = 'blocked' THEN '⛔' ELSE '💥' END,
                                            p_task, p_step_key, v_step.role, p_result->>'summary',
                                            coalesce(E'\n' || v_questions, coalesce(E'\n' || (p_result->>'error'), '')))
                                     || E'\nCoordinator перепланирует задачу.'))
           || orch_coordinator(p_task,
                format(E'Шаг %s (%s) завершился со статусом %s: %s%s', p_step_key, v_step.role, v_status,
                       p_result->>'summary', coalesce(E'\n' || v_questions, coalesce(E'\n' || (p_result->>'error'), ''))),
                v_status);
END;
$$;

CREATE OR REPLACE FUNCTION orch_on_result(p_result jsonb) RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
    v_sent events;
BEGIN
    SELECT * INTO v_sent FROM events
     WHERE type = 'command.sent' AND run_id = p_result->>'run_id' ORDER BY id DESC LIMIT 1;
    IF v_sent.id IS NULL OR (SELECT status FROM tasks WHERE id = v_sent.task_id) IN ('done', 'failed', 'cancelled') THEN
        RETURN '[]';
    END IF;
    IF v_sent.payload->>'kind' = 'plan' THEN
        RETURN orch_on_plan_result(v_sent.task_id, p_result, v_sent.payload->>'trigger');
    END IF;
    RETURN orch_on_step_result(v_sent.task_id, v_sent.step_key, p_result);
END;
$$;

CREATE OR REPLACE FUNCTION orch_on_decision(p_approval bigint, p_decision text, p_comment text) RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
    v_a approvals;
    v_plan plans;
    v_prev plans;
    v_step steps;
    v_granted boolean := p_decision = 'approved';
    v_note text := coalesce(E'\nКомментарий: ' || nullif(p_comment, ''), '');
BEGIN
    UPDATE approvals SET status = p_decision, comment = nullif(p_comment, ''), decided_at = now()
     WHERE id = p_approval AND status = 'pending'
    RETURNING * INTO v_a;
    IF v_a.id IS NULL THEN
        RETURN '[]';
    END IF;
    SELECT * INTO v_plan FROM plans WHERE id = v_a.plan_id;
    SELECT * INTO v_step FROM steps WHERE id = v_a.step_id;
    PERFORM orch_event(CASE WHEN v_granted THEN 'approval.granted' ELSE 'approval.rejected' END, v_a.task_id,
        jsonb_strip_nulls(jsonb_build_object('level', v_a.level, 'action', v_a.action, 'wait_ms', v_a.wait_ms,
                                             'comment', v_a.comment)),
        v_step.step_key, v_a.run_id, v_step.role, v_plan.version);

    IF v_a.action = 'coordinator.question' THEN
        RETURN jsonb_build_array(orch_tg(format('📝 Задача #%s: ответ передан coordinator.', v_a.task_id)))
               || orch_coordinator(v_a.task_id, format(E'Ответ человека на вопрос:\n%s\n\n%s',
                                                       v_a.description, coalesce(p_comment, '')), 'new_info');
    END IF;

    IF v_a.level = 'plan' THEN
        IF NOT v_granted THEN
            UPDATE plans SET status = 'rejected', decided_at = now() WHERE id = v_plan.id;
            PERFORM orch_event('plan.rejected', v_a.task_id, jsonb_build_object('comment', v_a.comment),
                               p_plan_version => v_plan.version);
            RETURN jsonb_build_array(orch_tg(format('❌ Задача #%s: план v%s отклонён.%s', v_a.task_id, v_plan.version, v_note)))
                   || orch_coordinator(v_a.task_id, format('План v%s отклонён человеком.%s', v_plan.version, v_note), 'rejected');
        END IF;
        v_prev := orch_current_plan(v_a.task_id);
        UPDATE plans SET status = 'superseded' WHERE task_id = v_a.task_id AND status = 'approved';
        UPDATE plans SET status = 'approved', decided_at = now() WHERE id = v_plan.id;
        PERFORM orch_event('plan.approved', v_a.task_id, jsonb_build_object('wait_ms', v_a.wait_ms),
                           p_plan_version => v_plan.version);
        INSERT INTO steps (plan_id, task_id, step_key, type, role, command, text, refs, after,
                           status, summary, result_refs, started_at, finished_at)
        SELECT v_plan.id, v_a.task_id, s->>'id', s->>'type', s->>'role', s->>'command', s->>'text',
               coalesce(s->'refs', '[]'),
               ARRAY(SELECT jsonb_array_elements_text(coalesce(s->'after', '[]'))),
               coalesce(p.status, 'pending'), p.summary, coalesce(p.result_refs, '[]'), p.started_at, p.finished_at
          FROM jsonb_array_elements(v_plan.body->'steps') s
          LEFT JOIN steps p ON p.plan_id = v_prev.id AND p.step_key = s->>'id' AND p.status = 'completed'
                           AND p.type = s->>'type' AND p.role IS NOT DISTINCT FROM s->>'role';
        PERFORM orch_task_status(v_a.task_id, 'running');
        RETURN jsonb_build_array(orch_tg(format('▶️ Задача #%s: план v%s одобрен, выполняю.%s', v_a.task_id, v_plan.version, v_note)))
               || orch_advance(v_a.task_id);
    END IF;

    IF v_a.level = 'step' THEN
        UPDATE steps SET status = CASE WHEN v_granted THEN 'completed' ELSE 'failed' END,
                         summary = CASE WHEN v_granted THEN 'Одобрено человеком' ELSE 'Отклонено человеком' END
                                   || coalesce(': ' || v_a.comment, ''),
                         started_at = coalesce(started_at, ready_at), finished_at = now()
         WHERE id = v_step.id;
        IF v_granted THEN
            PERFORM orch_event('step.completed', v_a.task_id, jsonb_build_object('duration_ms', v_a.wait_ms, 'runs', 0),
                               v_step.step_key, NULL, NULL, v_plan.version);
            RETURN orch_advance(v_a.task_id);
        END IF;
        PERFORM orch_event('step.failed', v_a.task_id, jsonb_build_object('error', 'rejected by human'),
                           v_step.step_key, NULL, NULL, v_plan.version);
        RETURN orch_coordinator(v_a.task_id, format('Человек отклонил шаг %s: %s.%s', v_step.step_key, v_step.text, v_note),
                                'rejected');
    END IF;

    -- role approval: resume the role run
    UPDATE steps SET status = 'running' WHERE id = v_step.id;
    RETURN jsonb_build_array(orch_tg(format('%s Задача #%s, шаг %s: %s %s.%s', CASE WHEN v_granted THEN '👍' ELSE '👎' END,
                                            v_a.task_id, v_step.step_key, v_a.action,
                                            CASE WHEN v_granted THEN 'одобрено' ELSE 'отклонено' END, v_note)))
           || orch_run_action('step', v_a.task_id, v_step.step_key, v_step.role, 'human',
                jsonb_build_object(
                    'step_id', v_step.step_key,
                    'command', 'continue',
                    'text', v_step.text,
                    'refs', orch_refs(v_step.refs, (SELECT refs FROM tasks WHERE id = v_a.task_id)),
                    'context', jsonb_build_object('task', orch_task_json(v_a.task_id), 'plan', v_plan.body,
                                                  'previous', orch_previous(v_a.task_id)),
                    'approval', jsonb_strip_nulls(jsonb_build_object('decision', p_decision, 'comment', v_a.comment))));
END;
$$;

CREATE OR REPLACE FUNCTION orch(p_event jsonb) RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
    v_task bigint;
    v_refs jsonb;
    v_bad text;
    v_approval bigint;
BEGIN
    CASE p_event->>'type'
    WHEN 'roles' THEN
        DELETE FROM roles WHERE NOT id IN (SELECT c->>'id' FROM jsonb_array_elements(p_event->'cards') c);
        INSERT INTO roles (id, card)
        SELECT c->>'id', c FROM jsonb_array_elements(p_event->'cards') c
        ON CONFLICT (id) DO UPDATE SET card = excluded.card, updated_at = now();
        RETURN '[]';

    WHEN 'task.create' THEN
        SELECT coalesce(jsonb_agg(DISTINCT r) FILTER (WHERE r ~ '^(gitlab|jira|confluence|url):.+$'), '[]'),
               string_agg(r, ', ') FILTER (WHERE r !~ '^(gitlab|jira|confluence|url):.+$')
          INTO v_refs, v_bad
          FROM (SELECT CASE WHEN x ~ '^https?://' THEN 'url:' || x ELSE x END AS r
                  FROM jsonb_array_elements_text(coalesce(p_event->'refs', '[]')) e(y), btrim(y) x
                 WHERE x <> '') s;
        INSERT INTO tasks (title, text, refs, status)
        VALUES (left(btrim(p_event->>'title'), 200), p_event->>'text', coalesce(v_refs, '[]'), 'planning')
        RETURNING id INTO v_task;
        PERFORM orch_event('task.created', v_task, jsonb_build_object('title', p_event->>'title'));
        RETURN jsonb_build_array(orch_tg(format('📥 Задача #%s принята: %s%s', v_task, p_event->>'title',
                                                coalesce(E'\nПропущены ссылки без префикса gitlab:/jira:/confluence:/url: ' || v_bad, ''))))
               || orch_coordinator(v_task, 'Построить план выполнения задачи.');

    WHEN 'result' THEN
        RETURN orch_on_result(p_event->'result');

    WHEN 'dispatch_failed' THEN
        RETURN orch_on_result(jsonb_build_object('run_id', p_event->>'run_id', 'role', p_event->>'role',
            'status', 'failed', 'summary', 'Команда не доставлена роли', 'error', p_event->>'error'));

    WHEN 'decision' THEN
        RETURN orch_on_decision((p_event->>'approval_id')::bigint, p_event->>'decision', p_event->>'comment');

    WHEN 'reply' THEN
        SELECT id INTO v_approval FROM approvals
         WHERE tg_message_id = (p_event->>'message_id')::bigint AND status = 'pending';
        IF v_approval IS NULL THEN
            RETURN jsonb_build_array(orch_tg('Это сообщение не ждёт ответа.'));
        END IF;
        RETURN orch_on_decision(v_approval,
            CASE WHEN (SELECT action FROM approvals WHERE id = v_approval) = 'coordinator.question'
                 THEN 'approved' ELSE 'rejected' END,
            p_event->>'text');

    WHEN 'message' THEN
        UPDATE approvals SET tg_message_id = (p_event->>'message_id')::bigint WHERE id = (p_event->>'approval_id')::bigint;
        RETURN '[]';

    ELSE
        RAISE EXCEPTION 'unknown event type: %', p_event->>'type';
    END CASE;
END;
$$;
