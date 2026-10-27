-- BandoLab — patch 07: funzioni RPC per sessioni, punteggio e tentativi
-- Da eseguire dopo patch-06.
--
-- Sostituiscono nel core: BL.startSession, BL.saveSession, BL.finishSession,
-- BL.logInterruption, BL.abandonSession (stesse regole di punteggio e XP).
--
-- Convenzioni
--  * Funzioni public.*: security definer, search_path fisso, richiamabili solo da utenti autenticati.
--  * Funzioni private.*: di supporto, non richiamabili dall'API.
--  * Input o permessi non validi: eccezione. Condizioni previste (domande insufficienti,
--    sessione già attiva, tempo scaduto): risposta jsonb {"ok": false, "error": "<codice>"}.
--  * Le risposte corrette non vengono mai restituite al client (vedi patch-08).
--  * L'id del tentativo coincide con l'id della sessione: questo rende la consegna idempotente.
--
-- Formato di cfg per start_session:
--   { "env": "demo" | "real", "mode": "training" | "exam", "title": "...", "key": "...",
--     "count": 10, "duration_min": 30 (solo exam),
--     "filter": { "subjects": [...], "topics": [...], "difficulty": "mix"|"1"|"2"|"3", "profile": "..." },
--     "path_ref": { "pid": "...", "sid": "..." } }

-- =========================================================
-- FUNZIONI DI SUPPORTO (schema private)
-- =========================================================

create or replace function private.session_json(p_row public.quiz_sessions)
returns jsonb
language sql
stable
set search_path = public
as $$
  select jsonb_build_object(
    'id', p_row.id, 'env', p_row.env, 'mode', p_row.mode, 'title', p_row.title,
    'key', p_row.quiz_key, 'items', p_row.items, 'answers', p_row.answers,
    'revealed', p_row.revealed, 'current_idx', p_row.current_idx,
    'started_at', p_row.started_at, 'deadline', p_row.deadline,
    'path_ref', p_row.path_ref, 'server_now', now());
$$;

-- Risultato di un tentativo già registrato (punteggio, esito, XP assegnati).
create or replace function private.attempt_result(p_id uuid, p_uid uuid)
returns jsonb
language sql
stable
set search_path = public
as $$
  select jsonb_build_object(
    'ok', true,
    'attempt', jsonb_build_object(
      'id', a.id, 'mode', a.mode, 'title', a.title, 'status', a.status, 'reason', a.reason,
      'started_at', a.started_at, 'finished_at', a.finished_at, 'duration_sec', a.duration_sec,
      'c', a.c, 'e', a.e, 'o', a.o, 'n', a.n, 'raw', a.raw_score, 'score', a.score,
      'display', replace(to_char(round(a.score, 1), 'FM990.0'), '.', ','),
      'passed', a.passed),
    'xp', coalesce((
      select jsonb_agg(jsonb_build_object('amount', x.amount, 'reason', x.reason) order by x.id)
      from public.xp_events x
      where x.user_id = a.user_id and x.ref = a.id::text), '[]'::jsonb))
  from public.attempts a
  where a.id = p_id and a.user_id = p_uid;
$$;

-- Consegna di una sessione: punteggio, tentativo, XP, avanzamento del percorso, notifica.
create or replace function private.finish_session_core(p_id uuid, p_uid uuid, p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_sess   public.quiz_sessions%rowtype;
  v_res    jsonb;
  v_reason public.attempt_reason_t;
  v_end    timestamptz;
  v_items  jsonb;
  v_n int; v_c int; v_o int; v_e int;
  v_raw numeric; v_score numeric; v_passed boolean;
  v_recent int;
  v_xp_main int;
  v_prev numeric;
  v_interruptions jsonb;
  v_notify boolean;
  v_display text;
  v_xp_total int;
begin
  select * into v_sess from public.quiz_sessions where id = p_id and user_id = p_uid for update;
  if not found then
    -- già consegnata (anche da una chiamata concorrente): restituisce il risultato esistente
    v_res := private.attempt_result(p_id, p_uid);
    if v_res is null then
      return jsonb_build_object('ok', false, 'error', 'session_not_found');
    end if;
    return v_res || jsonb_build_object('already', true);
  end if;

  -- esito temporale deciso dal server
  if v_sess.deadline is not null and now() >= v_sess.deadline then
    v_reason := 'timeout'; v_end := v_sess.deadline;
  elsif p_reason = 'timeout' then
    -- tolleranza di 5 secondi per piccoli scarti di orologio tra client e server
    if v_sess.deadline is not null and now() >= v_sess.deadline - interval '5 seconds' then
      v_reason := 'timeout'; v_end := now();
    else
      return jsonb_build_object('ok', false, 'error', 'not_expired');
    end if;
  else
    v_reason := 'submitted'; v_end := now();
  end if;

  -- correzione sulle versioni fissate all'avvio
  v_n := jsonb_array_length(v_sess.items);
  select jsonb_agg(jsonb_build_object('pos', t.pos, 'qid', t.qid, 'v', t.ver, 'answer', t.answer,
                                      'ok', (t.answer is not null and t.answer = t.correct)) order by t.pos)
    into v_items
  from (
    select i.ord::int as pos, i.qid, i.ver, qv.correct,
           case when jsonb_typeof(v_sess.answers -> i.qid) = 'number'
                then (v_sess.answers ->> i.qid)::smallint end as answer
    from (
      select e.ord, e.val ->> 'qid' as qid, (e.val ->> 'v')::int as ver
      from jsonb_array_elements(v_sess.items) with ordinality as e(val, ord)
    ) i
    join public.question_versions qv
      on qv.env = v_sess.env and qv.question_id = i.qid and qv.v = i.ver
  ) t;
  if v_items is null or jsonb_array_length(v_items) <> v_n then
    raise exception 'Versione di una domanda non trovata' using errcode = 'P0002';
  end if;

  select count(*) filter (where (x ->> 'ok')::boolean),
         count(*) filter (where x ->> 'answer' is null)
    into v_c, v_o
  from jsonb_array_elements(v_items) x;
  v_e := v_n - v_c - v_o;

  select r.raw, r.score, r.passed into v_raw, v_score, v_passed
  from public.compute_score(v_c, v_e, v_o, v_n) r;

  select coalesce(jsonb_agg(jsonb_build_object('at', i.at, 'type', i.type) order by i.at), '[]'::jsonb)
    into v_interruptions
  from public.session_interruptions i where i.session_id = v_sess.id;

  insert into public.attempts (id, user_id, env, mode, title, quiz_key, status, reason, started_at, finished_at,
                               duration_sec, c, e, o, n, raw_score, score, passed, interruptions, path_ref)
  values (v_sess.id, p_uid, v_sess.env, v_sess.mode, v_sess.title, v_sess.quiz_key, 'completed', v_reason,
          v_sess.started_at, v_end, greatest(0, round(extract(epoch from v_end - v_sess.started_at))::int),
          v_c, v_e, v_o, v_n, v_raw, round(v_score, 4), v_passed, v_interruptions, v_sess.path_ref);

  insert into public.attempt_items (attempt_id, position, env, question_id, version, answer, is_correct)
  select v_sess.id, (x ->> 'pos')::smallint, v_sess.env, x ->> 'qid', (x ->> 'v')::int,
         (x ->> 'answer')::smallint, (x ->> 'ok')::boolean
  from jsonb_array_elements(v_items) x;

  -- XP: stesse regole di BL.finishSession
  select count(*) into v_recent
  from public.attempts a
  where a.user_id = p_uid and a.env = v_sess.env and a.quiz_key = v_sess.quiz_key
    and a.status = 'completed' and a.id <> v_sess.id and a.finished_at > v_end - interval '1 day';

  if v_recent >= 2 then
    v_xp_main := 0;
    insert into public.xp_events (user_id, env, amount, reason, ref, at)
    values (p_uid, v_sess.env, 0, 'Ripetizione dello stesso quiz nelle 24 ore: nessun XP aggiuntivo', v_sess.id::text, v_end);
  else
    v_xp_main := 10 + v_c;
    insert into public.xp_events (user_id, env, amount, reason, ref, at)
    values (p_uid, v_sess.env, v_xp_main, 'Quiz completato', v_sess.id::text, v_end);
  end if;
  v_xp_total := v_xp_main;

  if v_sess.mode = 'exam' then
    select a.score into v_prev
    from public.attempts a
    where a.user_id = p_uid and a.env = v_sess.env and a.mode = 'exam' and a.status = 'completed'
      and a.n = v_n and a.id <> v_sess.id
    order by a.finished_at desc limit 1;
    if v_prev is not null and round(v_score, 4) > v_prev then
      insert into public.xp_events (user_id, env, amount, reason, ref, at)
      values (p_uid, v_sess.env, 15, 'Miglioramento in simulazione comparabile', v_sess.id::text, v_end);
      v_xp_total := v_xp_total + 15;
    end if;
  end if;

  -- avanzamento del percorso
  if v_sess.path_ref ->> 'pid' is not null and v_sess.path_ref ->> 'sid' is not null then
    insert into public.user_path_progress (user_id, env, path_id, step_status, updated_at)
    values (p_uid, v_sess.env, v_sess.path_ref ->> 'pid',
            jsonb_build_object(v_sess.path_ref ->> 'sid', 'done'), now())
    on conflict (user_id, env, path_id) do update
      set step_status = public.user_path_progress.step_status || jsonb_build_object(v_sess.path_ref ->> 'sid', 'done'),
          updated_at = now();
  end if;

  -- notifica in-app (rispetta la preferenza dell'utente)
  select coalesce((select up.notif_progress from public.user_prefs up
                   where up.user_id = p_uid and up.env = v_sess.env), true) into v_notify;
  if v_notify then
    v_display := replace(to_char(round(v_score, 1), 'FM990.0'), '.', ',');
    insert into public.notifications (user_id, env, type, title, body)
    values (p_uid, v_sess.env, 'progress',
            case when v_sess.mode = 'exam' then 'Simulazione consegnata' else 'Quiz completato' end,
            v_sess.title || ': ' || v_display || '/30'
              || case when v_xp_total > 0 then ' · +' || v_xp_total || ' XP' else '' end);
  end if;

  delete from public.quiz_sessions where id = v_sess.id;  -- le interruzioni seguono in cascata
  return private.attempt_result(v_sess.id, p_uid);
end;
$$;

-- =========================================================
-- FUNZIONI PUBBLICHE (richiamabili con supabase.rpc)
-- =========================================================

-- Avvia una sessione. Distribuzione bilanciata tra materie come BL.plan; in allenamento,
-- dopo almeno 30 risposte, le domande sbagliate in passato hanno la precedenza.
create or replace function public.start_session(cfg jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid        uuid := auth.uid();
  v_env        public.env_t;
  v_mode       public.quiz_mode_t;
  v_title      text;
  v_key        text;
  v_count      int;
  v_dur        int;
  v_subjects   text[];
  v_topics     text[];
  v_diff       text;
  v_profile    text;
  v_path       jsonb;
  v_old        public.quiz_sessions%rowtype;
  v_new        public.quiz_sessions%rowtype;
  v_wrong_pref boolean := false;
  v_available  int;
  v_items      jsonb;
  v_prior      boolean;
begin
  if v_uid is null then
    raise exception 'Accesso richiesto' using errcode = '28000';
  end if;
  if cfg is null or jsonb_typeof(cfg) <> 'object' then
    raise exception 'Configurazione non valida' using errcode = '22023';
  end if;

  v_env   := coalesce(nullif(cfg ->> 'env', ''), 'demo')::public.env_t;
  v_mode  := (cfg ->> 'mode')::public.quiz_mode_t;
  v_title := nullif(btrim(cfg ->> 'title'), '');
  v_key   := nullif(btrim(cfg ->> 'key'), '');
  v_count := (cfg ->> 'count')::int;
  if v_mode is null or v_title is null or v_key is null or v_count is null
     or v_count not between 1 and 200 or char_length(v_title) > 200 or char_length(v_key) > 100 then
    raise exception 'Configurazione non valida' using errcode = '22023';
  end if;
  if v_mode = 'exam' then
    v_dur := (cfg ->> 'duration_min')::int;
    if v_dur is null or v_dur not between 1 and 360 then
      raise exception 'Durata non valida' using errcode = '22023';
    end if;
  end if;

  v_diff := coalesce(nullif(cfg #>> '{filter,difficulty}', ''), 'mix');
  if v_diff not in ('mix', '1', '2', '3') then
    raise exception 'Difficoltà non valida' using errcode = '22023';
  end if;
  v_subjects := array(select jsonb_array_elements_text(
                  coalesce(nullif(cfg #> '{filter,subjects}', 'null'::jsonb), '[]'::jsonb)));
  v_topics   := array(select jsonb_array_elements_text(
                  coalesce(nullif(cfg #> '{filter,topics}', 'null'::jsonb), '[]'::jsonb)));
  v_profile  := nullif(cfg #>> '{filter,profile}', '');
  v_path     := nullif(cfg -> 'path_ref', 'null'::jsonb);
  if v_path is not null and (jsonb_typeof(v_path) <> 'object'
     or v_path ->> 'pid' is null or v_path ->> 'sid' is null) then
    raise exception 'Riferimento al percorso non valido' using errcode = '22023';
  end if;

  -- una sola sessione attiva per utente e ambiente; una simulazione scaduta viene consegnata
  select * into v_old from public.quiz_sessions where user_id = v_uid and env = v_env for update;
  if found then
    if v_old.deadline is not null and now() >= v_old.deadline then
      perform private.finish_session_core(v_old.id, v_uid, 'timeout');
    else
      return jsonb_build_object('ok', false, 'error', 'session_exists', 'session_id', v_old.id);
    end if;
  end if;

  if v_mode = 'training' then
    select count(*) >= 30 into v_wrong_pref
    from public.attempt_items ai
    join public.attempts a on a.id = ai.attempt_id
    where a.user_id = v_uid and a.env = v_env;
  end if;

  with pool as materialized (
    select lq.question_id as qid, lq.v as ver, lq.subject_id,
           (v_wrong_pref and exists (
              select 1 from public.attempt_items ai
              join public.attempts a on a.id = ai.attempt_id
              where a.user_id = v_uid and a.env = v_env
                and ai.question_id = lq.question_id and ai.env = v_env
                and ai.answer is not null and not ai.is_correct)) as was_wrong
    from public.live_questions lq
    where lq.env = v_env
      and (cardinality(v_subjects) = 0 or lq.subject_id = any (v_subjects))
      and (cardinality(v_topics) = 0 or lq.topic_id = any (v_topics))
      and (v_diff = 'mix' or lq.difficulty = v_diff::int)
      and (v_profile is null or exists (
             select 1 from public.question_profiles qp
             where qp.env = lq.env and qp.question_id = lq.question_id and qp.profile_id = v_profile))
  ), ranked as materialized (
    select p.*, row_number() over (partition by p.subject_id order by p.was_wrong desc, random()) as rn
    from pool p
  ), pick as materialized (
    select r.qid, r.ver, r.was_wrong from ranked r order by r.rn, r.subject_id limit v_count
  )
  select (select count(*) from pool),
         (select jsonb_agg(jsonb_build_object('qid', k.qid, 'v', k.ver) order by random()) from pick k),
         (select coalesce(bool_or(k.was_wrong), false) from pick k)
    into v_available, v_items, v_prior;

  if v_items is null or v_available < v_count then
    return jsonb_build_object('ok', false, 'error', 'insufficient', 'available', coalesce(v_available, 0));
  end if;

  begin
    insert into public.quiz_sessions (user_id, env, mode, title, quiz_key, items, deadline, path_ref)
    values (v_uid, v_env, v_mode, v_title, v_key, v_items,
            case when v_mode = 'exam' then now() + make_interval(mins => v_dur) end, v_path)
    returning * into v_new;
  exception when unique_violation then
    return jsonb_build_object('ok', false, 'error', 'session_exists');
  end;

  return jsonb_build_object('ok', true, 'prioritized', v_prior, 'session', private.session_json(v_new));
end;
$$;

-- Salva risposte e posizione. Dopo la scadenza il salvataggio viene rifiutato.
create or replace function public.save_session(
  p_id uuid, p_answers jsonb, p_revealed jsonb default null, p_current int default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid  uuid := auth.uid();
  v_sess public.quiz_sessions%rowtype;
begin
  if v_uid is null then
    raise exception 'Accesso richiesto' using errcode = '28000';
  end if;

  select * into v_sess from public.quiz_sessions where id = p_id and user_id = v_uid for update;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'session_not_found');
  end if;
  if v_sess.deadline is not null and now() >= v_sess.deadline then
    return jsonb_build_object('ok', false, 'error', 'expired', 'deadline', v_sess.deadline);
  end if;

  if p_answers is not null then
    if jsonb_typeof(p_answers) <> 'object' then
      raise exception 'Risposte non valide' using errcode = '22023';
    end if;
    if exists (
      select 1 from jsonb_each(p_answers) a
      where not exists (select 1 from jsonb_array_elements(v_sess.items) i where i.value ->> 'qid' = a.key)
         or (jsonb_typeof(a.value) <> 'null'
             and (jsonb_typeof(a.value) <> 'number' or a.value::text !~ '^[0-3]$'))
    ) then
      raise exception 'Risposte non valide' using errcode = '22023';
    end if;
  end if;

  if p_revealed is not null then
    if jsonb_typeof(p_revealed) <> 'object' then
      raise exception 'Dati non validi' using errcode = '22023';
    end if;
    if exists (
      select 1 from jsonb_each(p_revealed) a
      where not exists (select 1 from jsonb_array_elements(v_sess.items) i where i.value ->> 'qid' = a.key)
         or jsonb_typeof(a.value) <> 'boolean'
    ) then
      raise exception 'Dati non validi' using errcode = '22023';
    end if;
  end if;

  update public.quiz_sessions
     set answers     = coalesce(p_answers, answers),
         revealed    = case when mode = 'training' then coalesce(p_revealed, revealed) else revealed end,
         current_idx = case when p_current is null then current_idx
                            else least(greatest(p_current, 0), jsonb_array_length(items) - 1)::smallint end,
         last_seen   = now()
   where id = v_sess.id;

  return jsonb_build_object('ok', true, 'server_now', now(), 'deadline', v_sess.deadline);
end;
$$;

-- Consegna la sessione. Il server decide se è stata consegnata in tempo.
create or replace function public.finish_session(p_id uuid, p_reason text default 'submitted')
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then
    raise exception 'Accesso richiesto' using errcode = '28000';
  end if;
  if p_reason is null or p_reason not in ('submitted', 'timeout') then
    raise exception 'Motivo non valido' using errcode = '22023';
  end if;
  return private.finish_session_core(p_id, v_uid, p_reason);
end;
$$;

-- Registra un'interruzione (es. perdita di focus). Massimo 200 per sessione.
create or replace function public.log_interruption(p_id uuid, p_type text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then
    raise exception 'Accesso richiesto' using errcode = '28000';
  end if;
  if p_type is null or char_length(p_type) not between 1 and 40 then
    raise exception 'Tipo non valido' using errcode = '22023';
  end if;
  if not exists (select 1 from public.quiz_sessions where id = p_id and user_id = v_uid) then
    return jsonb_build_object('ok', false, 'error', 'session_not_found');
  end if;
  if (select count(*) from public.session_interruptions where session_id = p_id) < 200 then
    insert into public.session_interruptions (session_id, type) values (p_id, p_type);
  end if;
  return jsonb_build_object('ok', true);
end;
$$;

-- Abbandona la sessione: registra un tentativo "abandoned" (non conta nelle statistiche).
-- Rispetto al core, la durata è quella effettivamente trascorsa invece di 0.
create or replace function public.abandon_session(p_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid  uuid := auth.uid();
  v_sess public.quiz_sessions%rowtype;
  v_interruptions jsonb;
begin
  if v_uid is null then
    raise exception 'Accesso richiesto' using errcode = '28000';
  end if;

  select * into v_sess from public.quiz_sessions where id = p_id and user_id = v_uid for update;
  if not found then
    if exists (select 1 from public.attempts where id = p_id and user_id = v_uid) then
      return jsonb_build_object('ok', true, 'already', true);
    end if;
    return jsonb_build_object('ok', false, 'error', 'session_not_found');
  end if;

  select coalesce(jsonb_agg(jsonb_build_object('at', i.at, 'type', i.type) order by i.at), '[]'::jsonb)
    into v_interruptions
  from public.session_interruptions i where i.session_id = v_sess.id;

  insert into public.attempts (id, user_id, env, mode, title, quiz_key, status, reason, started_at, finished_at,
                               duration_sec, interruptions, path_ref)
  values (v_sess.id, v_uid, v_sess.env, v_sess.mode, v_sess.title, v_sess.quiz_key, 'abandoned', 'abandoned',
          v_sess.started_at, now(), greatest(0, round(extract(epoch from now() - v_sess.started_at))::int),
          v_interruptions, v_sess.path_ref);

  delete from public.quiz_sessions where id = v_sess.id;
  return jsonb_build_object('ok', true);
end;
$$;

-- =========================================================
-- PERMESSI
-- =========================================================
revoke all on function private.session_json(public.quiz_sessions)        from public, anon, authenticated;
revoke all on function private.attempt_result(uuid, uuid)                from public, anon, authenticated;
revoke all on function private.finish_session_core(uuid, uuid, text)     from public, anon, authenticated;

revoke all on function public.start_session(jsonb)                       from public, anon;
revoke all on function public.save_session(uuid, jsonb, jsonb, int)      from public, anon;
revoke all on function public.finish_session(uuid, text)                 from public, anon;
revoke all on function public.log_interruption(uuid, text)               from public, anon;
revoke all on function public.abandon_session(uuid)                      from public, anon;

grant execute on function public.start_session(jsonb)                    to authenticated;
grant execute on function public.save_session(uuid, jsonb, jsonb, int)   to authenticated;
grant execute on function public.finish_session(uuid, text)              to authenticated;
grant execute on function public.log_interruption(uuid, text)            to authenticated;
grant execute on function public.abandon_session(uuid)                   to authenticated;
