-- BandoLab — test di esecuzione delle funzioni RPC (patch-07 e patch-08)
--
-- Come si usa: incolla tutto nel SQL Editor di Supabase e premi Run.
-- Non lascia NULLA nel database: crea utenti e domande finti e termina SEMPRE con un errore voluto
-- ("RISULTATI: ...") che annulla l'intera transazione. L'errore finale è il modo in cui lo script
-- restituisce l'esito: ogni controllo compare come "Txx ok" oppure "Txx KO[dettaglio]".
-- Se compare "!!ERRORE", un test ha sollevato un'eccezione inattesa: l'esito dei controlli successivi
-- non è disponibile.
--
-- Nota: dentro una transazione now() è costante, quindi le scadenze vengono simulate modificando
-- started_at e deadline della sessione.

do $$
declare
  c_a constant text := '{"sub":"aaaaaaaa-0000-0000-0000-00000000000a","role":"authenticated"}';
  c_b constant text := '{"sub":"bbbbbbbb-0000-0000-0000-00000000000b","role":"authenticated"}';
  c_c constant text := '{"sub":"cccccccc-0000-0000-0000-00000000000c","role":"authenticated"}';
  c_d constant text := '{"sub":"dddddddd-0000-0000-0000-00000000000d","role":"authenticated"}';
  v_r text := '';
  v_j jsonb;
  v_js jsonb;
  v_n int;
  v_before int;
  v_i int;
  v_t text;
  v_s numeric;
  v_p boolean;
  v_sid uuid; v_sid2 uuid; v_sid3 uuid; v_sid4 uuid; v_sid5 uuid;
  v_items jsonb;
  v_q0 text; v_q1 text; v_q2 text; v_q3 text;
begin
  begin
    -- =====================================================
    -- PREPARAZIONE (come proprietario): utenti, tassonomia, 12 domande pubblicate
    -- =====================================================
    insert into auth.users (id, email, raw_user_meta_data) values
      ('aaaaaaaa-0000-0000-0000-00000000000a', 'a@test.local', '{"full_name":"Utente A"}'),
      ('bbbbbbbb-0000-0000-0000-00000000000b', 'b@test.local', '{"full_name":"Utente B"}'),
      ('cccccccc-0000-0000-0000-00000000000c', 'c@test.local', '{"full_name":"Editor C"}'),
      ('dddddddd-0000-0000-0000-00000000000d', 'd@test.local', '{"full_name":"Utente D"}');
    update public.profiles_user set role = 'editor' where id = 'cccccccc-0000-0000-0000-00000000000c';

    insert into public.subjects (id, env, name) values ('s1', 'demo', 'Materia 1'), ('s2', 'demo', 'Materia 2');
    insert into public.topics (id, env, name, subject_id) values
      ('t1', 'demo', 'Argomento 1', 's1'), ('t2', 'demo', 'Argomento 2', 's2');

    for v_i in 1..12 loop
      insert into public.questions (id, env, current_version) values ('tq' || v_i, 'demo', 1);
      insert into public.question_versions
        (env, question_id, v, status, text, options, correct, explanation, subject_id, topic_id, difficulty,
         source, last_verified, next_review, author_id, reviewer_id, approved_at, published_at)
      values ('demo', 'tq' || v_i, 1, 'published', 'Testo domanda di prova numero ' || v_i,
              array['A', 'B', 'C', 'D'], 0, 'Spiegazione ' || v_i,
              case when v_i <= 6 then 's1' else 's2' end, case when v_i <= 6 then 't1' else 't2' end,
              (v_i % 3) + 1, 'Fonte di prova', current_date - 10, current_date + 300,
              'cccccccc-0000-0000-0000-00000000000c', 'bbbbbbbb-0000-0000-0000-00000000000b', now(), now());
    end loop;

    -- =====================================================
    -- UTENTE A — allenamento
    -- =====================================================
    perform set_config('request.jwt.claims', c_a, true);
    set local role authenticated;

    v_j := public.start_session('{"env":"demo","mode":"training","title":"Allenamento prova","key":"k-train","count":4}'::jsonb);
    v_sid := (v_j -> 'session' ->> 'id')::uuid;
    v_items := v_j -> 'session' -> 'items';
    v_q0 := v_items -> 0 ->> 'qid'; v_q1 := v_items -> 1 ->> 'qid';
    v_q2 := v_items -> 2 ->> 'qid'; v_q3 := v_items -> 3 ->> 'qid';
    v_r := v_r || case when v_j ->> 'ok' = 'true' and jsonb_array_length(v_items) = 4 and v_j::text not like '%correct%'
      then 'T01 avvio allenamento, nessuna soluzione nella risposta ok | ' else 'T01 KO[' || v_j::text || '] | ' end;

    select count(*) filter (where lq.subject_id = 's1') into v_n
    from public.live_questions lq
    where lq.env = 'demo' and lq.question_id in (select e.value ->> 'qid' from jsonb_array_elements(v_items) e);
    v_r := v_r || case when v_n = 2 then 'T02 distribuzione bilanciata 2+2 ok | ' else 'T02 KO[s1=' || v_n || '] | ' end;

    v_j := public.start_session('{"env":"demo","mode":"training","title":"Allenamento prova","key":"k-train","count":4}'::jsonb);
    v_r := v_r || case when v_j ->> 'error' = 'session_exists' then 'T03 seconda sessione rifiutata ok | ' else 'T03 KO[' || v_j::text || '] | ' end;

    v_j := public.start_session('{"env":"real","mode":"training","title":"x","key":"k","count":3}'::jsonb);
    v_r := v_r || case when v_j ->> 'error' = 'insufficient' and (v_j ->> 'available')::int = 0
      then 'T04 domande insufficienti ok | ' else 'T04 KO[' || v_j::text || '] | ' end;

    begin
      perform public.start_session('{"mode":"training","title":"x","key":"k","count":0}'::jsonb);
      v_r := v_r || 'T05 KO[configurazione non valida accettata] | ';
    exception when sqlstate '22023' then v_r := v_r || 'T05 configurazione non valida rifiutata ok | ';
    end;

    begin
      perform public.save_session(v_sid, jsonb_build_object(v_q0, 7));
      v_r := v_r || 'T06 KO[risposta 7 accettata] | ';
    exception when sqlstate '22023' then v_r := v_r || 'T06 risposta fuori scala rifiutata ok | ';
    end;
    begin
      perform public.save_session(v_sid, jsonb_build_object('zzz', 0));
      v_r := v_r || 'T06b KO[domanda estranea accettata] | ';
    exception when sqlstate '22023' then v_r := v_r || 'T06b domanda estranea rifiutata ok | ';
    end;

    v_j := public.save_session(v_sid, jsonb_build_object(v_q0, 0, v_q1, 0, v_q2, 1), jsonb_build_object(v_q0, true), 2);
    v_r := v_r || case when v_j ->> 'ok' = 'true' then 'T07 salvataggio ok | ' else 'T07 KO[' || v_j::text || '] | ' end;

    v_j := public.save_session(v_sid, jsonb_build_object(v_q0, 0, v_q1, 0, v_q2, 1));
    select qs.current_idx into v_n from public.quiz_sessions qs where qs.id = v_sid;
    v_r := v_r || case when v_n = 2 then 'T08 posizione non azzerata se omessa ok | ' else 'T08 KO[idx=' || v_n || '] | ' end;

    v_j := public.get_question_feedback(v_sid, v_q1);
    v_r := v_r || case when v_j ->> 'error' = 'not_revealed' then 'T09 feedback negato se non rivelata ok | ' else 'T09 KO[' || v_j::text || '] | ' end;

    v_j := public.get_question_feedback(v_sid, v_q0);
    v_r := v_r || case when v_j ->> 'ok' = 'true' and (v_j ->> 'correct')::int = 0 and v_j ->> 'explanation' like 'Spiegazione%'
      then 'T10 feedback dopo rivelazione ok | ' else 'T10 KO[' || v_j::text || '] | ' end;

    v_j := public.get_question_feedback(v_sid, 'zzz');
    v_r := v_r || case when v_j ->> 'error' = 'question_not_in_session' then 'T11 feedback domanda estranea negato ok | ' else 'T11 KO[' || v_j::text || '] | ' end;

    -- consegna: 2 corrette, 1 errata, 1 omessa su 4 -> grezzo 1,25 -> 9,375/30 -> "9,4", non superato, +12 XP
    v_j := public.finish_session(v_sid, 'submitted');
    v_r := v_r || case when v_j ->> 'ok' = 'true'
        and (v_j -> 'attempt' ->> 'c')::int = 2 and (v_j -> 'attempt' ->> 'e')::int = 1
        and (v_j -> 'attempt' ->> 'o')::int = 1 and (v_j -> 'attempt' ->> 'n')::int = 4
        and (v_j -> 'attempt' ->> 'score')::numeric = 9.375 and v_j -> 'attempt' ->> 'display' = '9,4'
        and v_j -> 'attempt' ->> 'passed' = 'false' and v_j -> 'attempt' ->> 'reason' = 'submitted'
        and (v_j -> 'xp' -> 0 ->> 'amount')::int = 12
      then 'T12 consegna: punteggio, esito e XP ok | ' else 'T12 KO[' || v_j::text || '] | ' end;

    select count(*) into v_n from public.quiz_sessions qs where qs.id = v_sid;
    v_r := v_r || case when v_n = 0 then 'T13 sessione chiusa ok | ' else 'T13 KO | ' end;

    select count(*), max(nt.body) into v_n, v_t from public.notifications nt;
    v_r := v_r || case when v_n = 1 and v_t like 'Allenamento prova: 9,4/30%12 XP'
      then 'T14 notifica creata ok | ' else 'T14 KO[' || v_n || ',' || coalesce(v_t, 'null') || '] | ' end;

    v_j := public.finish_session(v_sid, 'submitted');
    v_r := v_r || case when v_j ->> 'ok' = 'true' and v_j ->> 'already' = 'true' and jsonb_array_length(v_j -> 'xp') = 1
      then 'T15 doppia consegna idempotente ok | ' else 'T15 KO[' || v_j::text || '] | ' end;

    v_j := public.get_attempt_review(v_sid);
    v_r := v_r || case when v_j ->> 'ok' = 'true' and jsonb_array_length(v_j -> 'items') = 4
        and v_j -> 'items' -> 0 ->> 'pos' = '1' and v_j -> 'items' -> 0 ->> 'text' like 'Testo domanda%'
        and v_j -> 'items' -> 0 ->> 'correct' is not null and v_j -> 'items' -> 3 ->> 'pos' = '4'
      then 'T16 revisione con soluzioni ok | ' else 'T16 KO[' || left(v_j::text, 200) || '] | ' end;

    perform set_config('request.jwt.claims', c_b, true);
    v_j := public.get_attempt_review(v_sid);
    v_r := v_r || case when v_j ->> 'error' = 'attempt_not_found' then 'T17 revisione di altri negata ok | ' else 'T17 KO[' || left(v_j::text, 200) || '] | ' end;
    perform set_config('request.jwt.claims', c_a, true);

    -- =====================================================
    -- UTENTE A — simulazioni d'esame e scadenza
    -- =====================================================
    v_j := public.start_session('{"env":"demo","mode":"exam","title":"Simulazione prova","key":"k-exam","count":4,"duration_min":30}'::jsonb);
    v_sid2 := (v_j -> 'session' ->> 'id')::uuid;
    v_r := v_r || case when v_j ->> 'ok' = 'true' and v_j -> 'session' ->> 'deadline' is not null
      then 'T18 avvio simulazione con scadenza ok | ' else 'T18 KO[' || left(v_j::text, 200) || '] | ' end;

    v_q0 := v_j -> 'session' -> 'items' -> 0 ->> 'qid';
    v_j := public.get_question_feedback(v_sid2, v_q0);
    v_r := v_r || case when v_j ->> 'error' = 'not_available' then 'T19 feedback negato in simulazione ok | ' else 'T19 KO[' || v_j::text || '] | ' end;

    v_j := public.finish_session(v_sid2, 'timeout');
    v_r := v_r || case when v_j ->> 'error' = 'not_expired' then 'T20 timeout anticipato rifiutato ok | ' else 'T20 KO[' || left(v_j::text, 200) || '] | ' end;

    reset role;
    update public.quiz_sessions set started_at = now() - interval '31 minutes', deadline = now() - interval '1 minute' where id = v_sid2;
    set local role authenticated;

    v_j := public.save_session(v_sid2, jsonb_build_object(v_q0, 0));
    v_r := v_r || case when v_j ->> 'error' = 'expired' then 'T21 salvataggio dopo scadenza rifiutato ok | ' else 'T21 KO[' || v_j::text || '] | ' end;

    v_j := public.finish_session(v_sid2, 'submitted');
    v_r := v_r || case when v_j ->> 'ok' = 'true' and v_j -> 'attempt' ->> 'reason' = 'timeout'
        and (v_j -> 'attempt' ->> 'duration_sec')::int = 1800
      then 'T22 consegna tardiva registrata come timeout, durata 1800 s ok | ' else 'T22 KO[' || left(v_j::text, 250) || '] | ' end;

    v_j := public.start_session('{"env":"demo","mode":"exam","title":"Simulazione 2","key":"k-exam2","count":4,"duration_min":30}'::jsonb);
    v_sid3 := (v_j -> 'session' ->> 'id')::uuid;
    reset role;
    update public.quiz_sessions set deadline = now() + interval '3 seconds' where id = v_sid3;
    set local role authenticated;
    v_j := public.finish_session(v_sid3, 'timeout');
    v_r := v_r || case when v_j ->> 'ok' = 'true' and v_j -> 'attempt' ->> 'reason' = 'timeout'
      then 'T23 tolleranza di 5 secondi sul timeout ok | ' else 'T23 KO[' || left(v_j::text, 250) || '] | ' end;

    -- miglioramento: stessa dimensione (4), punteggio 30 contro 0 -> +15 XP
    v_j := public.start_session('{"env":"demo","mode":"exam","title":"Simulazione 3","key":"k-exam3","count":4,"duration_min":30}'::jsonb);
    v_sid4 := (v_j -> 'session' ->> 'id')::uuid;
    v_items := v_j -> 'session' -> 'items';
    perform public.save_session(v_sid4, jsonb_build_object(
      v_items -> 0 ->> 'qid', 0, v_items -> 1 ->> 'qid', 0, v_items -> 2 ->> 'qid', 0, v_items -> 3 ->> 'qid', 0));
    v_j := public.finish_session(v_sid4, 'submitted');
    select count(*) into v_n from jsonb_array_elements(v_j -> 'xp') x
      where (x.value ->> 'amount')::int = 15 and x.value ->> 'reason' like 'Miglioramento%';
    v_r := v_r || case when v_j ->> 'ok' = 'true' and (v_j -> 'attempt' ->> 'score')::numeric = 30
        and v_j -> 'attempt' ->> 'passed' = 'true' and v_n = 1
      then 'T24 punteggio 30, superato, bonus miglioramento +15 ok | ' else 'T24 KO[' || left(v_j::text, 250) || '] | ' end;

    -- simulazione scaduta e mai consegnata: viene consegnata da start_session
    v_j := public.start_session('{"env":"demo","mode":"exam","title":"Simulazione 4","key":"k-exam4","count":4,"duration_min":30}'::jsonb);
    v_sid4 := (v_j -> 'session' ->> 'id')::uuid;
    reset role;
    update public.quiz_sessions set started_at = now() - interval '40 minutes', deadline = now() - interval '10 minutes' where id = v_sid4;
    set local role authenticated;
    v_j := public.start_session('{"env":"demo","mode":"training","title":"Dopo scadenza","key":"k-after","count":2}'::jsonb);
    v_sid5 := (v_j -> 'session' ->> 'id')::uuid;
    select count(*) into v_n from public.attempts a where a.id = v_sid4 and a.reason = 'timeout';
    v_r := v_r || case when v_j ->> 'ok' = 'true' and v_n = 1
      then 'T25 simulazione scaduta consegnata all''avvio successivo ok | ' else 'T25 KO[' || left(v_j::text, 200) || ',' || v_n || '] | ' end;

    -- interruzioni e abbandono
    perform public.log_interruption(v_sid5, 'blur');
    perform public.log_interruption(v_sid5, 'blur');
    begin
      perform public.log_interruption(v_sid5, '');
      v_r := v_r || 'T26a KO[tipo vuoto accettato] | ';
    exception when sqlstate '22023' then v_r := v_r || 'T26a tipo vuoto rifiutato ok | ';
    end;
    v_j := public.log_interruption('99999999-0000-0000-0000-000000000099'::uuid, 'blur');
    v_r := v_r || case when v_j ->> 'error' = 'session_not_found' then 'T26b sessione inesistente ok | ' else 'T26b KO | ' end;
    v_j := public.abandon_session(v_sid5);
    select count(*) into v_n from public.attempts a
      where a.id = v_sid5 and a.status = 'abandoned' and jsonb_array_length(a.interruptions) = 2;
    v_r := v_r || case when v_j ->> 'ok' = 'true' and v_n = 1 then 'T26c abbandono con 2 interruzioni ok | ' else 'T26c KO[' || v_j::text || ',' || v_n || '] | ' end;
    v_j := public.abandon_session(v_sid5);
    v_r := v_r || case when v_j ->> 'already' = 'true' then 'T26d doppio abbandono idempotente ok | ' else 'T26d KO | ' end;

    -- XP: dalla terza ripetizione dello stesso quiz in 24 ore nessun XP
    v_t := '';
    for v_i in 1..3 loop
      v_j := public.start_session('{"env":"demo","mode":"training","title":"Ripetizione","key":"k-rep","count":2}'::jsonb);
      v_j := public.finish_session((v_j -> 'session' ->> 'id')::uuid, 'submitted');
      v_t := v_t || (v_j -> 'xp' -> 0 ->> 'amount') || ',';
    end loop;
    v_r := v_r || case when v_t = '10,10,0,' then 'T27 XP: 10,10,0 alla terza ripetizione ok | ' else 'T27 KO[' || v_t || '] | ' end;

    -- avanzamento del percorso
    v_j := public.start_session('{"env":"demo","mode":"training","title":"Percorso","key":"k-path","count":2,"path_ref":{"pid":"p1","sid":"st1"}}'::jsonb);
    perform public.finish_session((v_j -> 'session' ->> 'id')::uuid, 'submitted');
    select upp.step_status into v_js from public.user_path_progress upp where upp.path_id = 'p1';
    v_r := v_r || case when v_js ->> 'st1' = 'done' then 'T28 percorso aggiornato ok | ' else 'T28 KO[' || coalesce(v_js::text, 'null') || '] | ' end;

    -- preferenza notifiche disattivata
    reset role;
    insert into public.user_prefs (user_id, env, notif_progress) values ('aaaaaaaa-0000-0000-0000-00000000000a', 'demo', false);
    set local role authenticated;
    select count(*) into v_before from public.notifications;
    v_j := public.start_session('{"env":"demo","mode":"training","title":"Senza notifica","key":"k-nonotif","count":2}'::jsonb);
    perform public.finish_session((v_j -> 'session' ->> 'id')::uuid, 'submitted');
    select count(*) into v_n from public.notifications;
    v_r := v_r || case when v_n = v_before then 'T29 preferenza notifiche rispettata ok | ' else 'T29 KO[' || v_before || '->' || v_n || '] | ' end;

    -- =====================================================
    -- PERMESSI
    -- =====================================================
    reset role;
    set local role anon;
    begin
      perform public.start_session('{}'::jsonb);
      v_r := v_r || 'T30 KO[anonimo può chiamare start_session] | ';
    exception when insufficient_privilege then v_r := v_r || 'T30 anonimo bloccato ok | ';
    end;
    reset role;

    perform set_config('request.jwt.claims', c_c, true);
    set local role authenticated;
    v_j := public.get_question_version_staff('demo'::public.env_t, 'tq1', 1);
    v_r := v_r || case when v_j ->> 'ok' = 'true' and (v_j -> 'version' ->> 'correct')::int = 0
        and v_j -> 'version' ->> 'explanation' = 'Spiegazione 1'
      then 'T31 editor vede la versione completa ok | ' else 'T31 KO[' || left(v_j::text, 200) || '] | ' end;
    v_j := public.get_question_version_staff('demo'::public.env_t, 'zz', 9);
    v_r := v_r || case when v_j ->> 'error' = 'not_found' then 'T31b versione inesistente ok | ' else 'T31b KO | ' end;
    reset role;

    -- punteggio: soglia sul valore non arrotondato
    select r.score, r.passed into v_s, v_p from public.compute_score(130, 5, 35, 170) r;
    v_r := v_r || case when round(v_s, 1) = 21.0 and v_p = false then 'T32a 21,0 mostrato ma non superato ok | ' else 'T32a KO[' || v_s || ',' || v_p || '] | ' end;
    select r.score, r.passed into v_s, v_p from public.compute_score(16, 4, 0, 20) r;
    v_r := v_r || case when v_s = 21 and v_p = true then 'T32b soglia esatta 21 superata ok | ' else 'T32b KO[' || v_s || ',' || v_p || '] | ' end;

    -- =====================================================
    -- UTENTE D — precedenza agli errori passati (dopo 30 risposte in allenamento)
    -- =====================================================
    insert into public.attempts (id, user_id, env, mode, title, quiz_key, status, reason, started_at, finished_at,
                                 duration_sec, c, e, o, n, raw_score, score, passed)
    values ('dddddddd-0000-0000-0000-0000000000a1', 'dddddddd-0000-0000-0000-00000000000d', 'demo', 'training',
            'Storico', 'k-old', 'completed', 'submitted', now() - interval '1 day', now() - interval '1 day',
            60, 30, 6, 0, 36, 27.00, 22.5, true);
    insert into public.attempt_items (attempt_id, position, env, question_id, version, answer, is_correct)
    select 'dddddddd-0000-0000-0000-0000000000a1', p, 'demo', 'tq' || (((p - 1) % 12) + 1), 1,
           case when ((p - 1) % 12) + 1 in (3, 9) then 1 else 0 end,
           not (((p - 1) % 12) + 1 in (3, 9))
    from generate_series(1, 36) p;

    perform set_config('request.jwt.claims', c_d, true);
    set local role authenticated;
    v_j := public.start_session('{"env":"demo","mode":"training","title":"Con errori","key":"k-prio","count":2}'::jsonb);
    select string_agg(e.value ->> 'qid', ',' order by e.value ->> 'qid') into v_t from jsonb_array_elements(v_j -> 'session' -> 'items') e;
    v_r := v_r || case when v_j ->> 'prioritized' = 'true' and v_t = 'tq3,tq9'
      then 'T33 precedenza agli errori passati ok | ' else 'T33 KO[' || coalesce(v_t, 'null') || ',' || coalesce(v_j ->> 'prioritized', 'null') || '] | ' end;
    reset role;
  exception when others then
    v_r := v_r || ' !!ERRORE[' || sqlstate || ']: ' || sqlerrm;
  end;

  raise exception 'RISULTATI: %', v_r;
end $$;
