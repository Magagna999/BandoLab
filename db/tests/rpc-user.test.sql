-- BandoLab — test delle funzioni RPC dell'area utente (patch-10)
-- Stesse regole di rpc-sessions.test.sql: crea dati finti, simula i ruoli, termina SEMPRE con l'errore
-- voluto "RISULTATI: ..." che annulla tutto. "Uxx ok" = controllo superato, "Uxx KO[...]" = fallito.

do $$
declare
  c_a constant text := '{"sub":"aaaaaaaa-0000-0000-0000-00000000000a","role":"authenticated"}';
  c_b constant text := '{"sub":"bbbbbbbb-0000-0000-0000-00000000000b","role":"authenticated"}';
  c_c constant text := '{"sub":"cccccccc-0000-0000-0000-00000000000c","role":"authenticated"}';
  c_d constant text := '{"sub":"dddddddd-0000-0000-0000-00000000000d","role":"authenticated"}';
  v_r text := '';
  v_j jsonb; v_n int; v_state text; v_aid uuid; v_aid2 uuid; v_aid3 uuid;
  v_i int;
begin
  begin
    insert into auth.users (id, email, raw_user_meta_data) values
      ('aaaaaaaa-0000-0000-0000-00000000000a', 'a@test.local', '{"full_name":"Utente A"}'),
      ('bbbbbbbb-0000-0000-0000-00000000000b', 'b@test.local', '{"full_name":"Utente B"}'),
      ('cccccccc-0000-0000-0000-00000000000c', 'c@test.local', '{"full_name":"Editor C"}'),
      ('dddddddd-0000-0000-0000-00000000000d', 'd@test.local', '{"full_name":"Utente D"}');
    update public.profiles_user set role = 'editor' where id = 'cccccccc-0000-0000-0000-00000000000c';

    insert into public.subjects (id, env, name) values ('s1', 'demo', 'Materia 1');
    insert into public.topics (id, env, name, subject_id) values ('t1', 'demo', 'Argomento 1', 's1');
    insert into public.materials (id, env, title, subject_id, topic_id, format, status, minutes, source, author_id)
    values ('m-pub', 'demo', 'Materiale pubblicato', 's1', 't1', 'scheda', 'published', 5, 'Fonte', 'cccccccc-0000-0000-0000-00000000000c'),
           ('m-bozza', 'demo', 'Materiale in bozza', 's1', 't1', 'scheda', 'draft', 5, 'Fonte', 'cccccccc-0000-0000-0000-00000000000c');
    insert into public.study_paths (id, env, title, status) values ('p1', 'demo', 'Percorso', 'published');
    insert into public.study_path_steps (env, path_id, id, position, type, title, material_id)
    values ('demo', 'p1', 'st1', 1, 'material', 'Leggi', 'm-pub');
    insert into public.questions (id, env, current_version) values ('tq1', 'demo', 1), ('tq2', 'demo', null);
    insert into public.question_versions (env, question_id, v, status, text, options, correct, explanation, subject_id, topic_id,
       difficulty, source, last_verified, next_review, author_id, reviewer_id, approved_at, published_at)
    values ('demo', 'tq1', 1, 'published', 'Testo domanda di prova uno', array['A','B','C','D'], 0, 'Spiegazione', 's1', 't1', 1,
            'Fonte', current_date - 10, current_date + 300, 'cccccccc-0000-0000-0000-00000000000c', 'bbbbbbbb-0000-0000-0000-00000000000b', now(), now());
    insert into public.question_versions (env, question_id, v, status, author_id)
    values ('demo', 'tq2', 1, 'draft', 'cccccccc-0000-0000-0000-00000000000c');
    -- tentativi: A completato, A abbandonato, B completato
    v_aid := gen_random_uuid(); v_aid2 := gen_random_uuid(); v_aid3 := gen_random_uuid();
    insert into public.attempts (id, user_id, env, mode, title, quiz_key, status, reason, started_at, finished_at, duration_sec, c, e, o, n, raw_score, score, passed)
    values (v_aid, 'aaaaaaaa-0000-0000-0000-00000000000a', 'demo', 'training', 'T', 'k', 'completed', 'submitted', now() - interval '1 hour', now(), 60, 1, 0, 0, 1, 1, 30, true),
           (v_aid3, 'bbbbbbbb-0000-0000-0000-00000000000b', 'demo', 'training', 'T', 'k', 'completed', 'submitted', now() - interval '1 hour', now(), 60, 1, 0, 0, 1, 1, 30, true);
    insert into public.attempts (id, user_id, env, mode, title, quiz_key, status, reason, started_at, finished_at, duration_sec)
    values (v_aid2, 'aaaaaaaa-0000-0000-0000-00000000000a', 'demo', 'training', 'T', 'k', 'abandoned', 'abandoned', now() - interval '1 hour', now(), 10);

    -- ===== complete_material =====
    perform set_config('request.jwt.claims', c_a, true);
    set local role authenticated;
    v_j := public.complete_material('demo', 'm-bozza');
    v_r := v_r || case when v_j ->> 'error' = 'not_found' then 'U01 materiale non pubblicato rifiutato ok | ' else 'U01 KO[' || v_j::text || '] | ' end;
    v_j := public.complete_material('demo', 'm-pub');
    select coalesce(sum(amount), 0) into v_n from public.xp_events where user_id = 'aaaaaaaa-0000-0000-0000-00000000000a';
    v_r := v_r || case when v_j ->> 'ok' = 'true' and v_j ->> 'already' = 'false' and v_n = 8 then 'U02 completamento +8 XP ok | ' else 'U02 KO[' || v_j::text || ' xp=' || v_n || '] | ' end;
    select count(*) into v_n from public.user_path_progress where user_id = 'aaaaaaaa-0000-0000-0000-00000000000a' and path_id = 'p1' and step_status ->> 'st1' = 'done';
    v_r := v_r || case when v_n = 1 then 'U03 avanzamento del percorso ok | ' else 'U03 KO[' || v_n || '] | ' end;
    v_j := public.complete_material('demo', 'm-pub');
    select coalesce(sum(amount), 0) into v_n from public.xp_events where user_id = 'aaaaaaaa-0000-0000-0000-00000000000a';
    v_r := v_r || case when v_j ->> 'already' = 'true' and v_n = 8 then 'U04 ripetizione senza nuovo XP ok | ' else 'U04 KO[' || v_j::text || ' xp=' || v_n || '] | ' end;

    -- ===== mark_reviewed =====
    v_j := public.mark_reviewed(v_aid);
    select coalesce(sum(amount), 0) into v_n from public.xp_events where user_id = 'aaaaaaaa-0000-0000-0000-00000000000a';
    v_r := v_r || case when v_j ->> 'ok' = 'true' and v_j ->> 'already' = 'false' and v_n = 13 then 'U05 revisione errori +5 XP ok | ' else 'U05 KO[' || v_j::text || ' xp=' || v_n || '] | ' end;
    v_j := public.mark_reviewed(v_aid);
    select coalesce(sum(amount), 0) into v_n from public.xp_events where user_id = 'aaaaaaaa-0000-0000-0000-00000000000a';
    v_r := v_r || case when v_j ->> 'already' = 'true' and v_n = 13 then 'U06 revisione ripetuta senza XP ok | ' else 'U06 KO[' || v_j::text || '] | ' end;
    v_r := v_r || case when public.mark_reviewed(v_aid3) ->> 'error' = 'attempt_not_found' and public.mark_reviewed(v_aid2) ->> 'error' = 'attempt_not_found'
      then 'U07 tentativo altrui o abbandonato rifiutato ok | ' else 'U07 KO | ' end;

    -- ===== create_report =====
    v_j := public.create_report('demo', 'tq1', 1, 'errore', 'La risposta indicata non è corretta secondo la norma.');
    select count(*) into v_n from public.notifications where user_id = 'aaaaaaaa-0000-0000-0000-00000000000a' and title = 'Segnalazione inviata';
    v_r := v_r || case when v_j ->> 'ok' = 'true' and v_n = 1 then 'U08 segnalazione e notifica ok | ' else 'U08 KO[' || v_j::text || ' n=' || v_n || '] | ' end;
    begin
      perform public.create_report('demo', 'tq1', 1, 'errore', 'corto');
      v_r := v_r || 'U09 KO[testo breve accettato] | ';
    exception when sqlstate '22023' then v_r := v_r || 'U09 testo troppo breve rifiutato ok | '; end;
    v_r := v_r || case when public.create_report('demo', 'tq2', 1, 'errore', 'La domanda è ancora una bozza non pubblica.') ->> 'error' = 'not_found'
      then 'U10 versione non pubblicata rifiutata ok | ' else 'U10 KO | ' end;
    for v_i in 1..4 loop perform public.create_report('demo', 'tq1', 1, 'errore', 'Segnalazione numero ' || v_i || ' di prova.'); end loop;
    v_j := public.create_report('demo', 'tq1', 1, 'errore', 'Questa è la sesta segnalazione del giorno.');
    v_r := v_r || case when v_j ->> 'error' = 'too_many' then 'U11 limite di 5 segnalazioni al giorno ok | ' else 'U11 KO[' || v_j::text || '] | ' end;
    -- preferenza notifiche disattivata (utente B)
    perform set_config('request.jwt.claims', c_b, true);
    insert into public.user_prefs (user_id, env, notif_content) values ('bbbbbbbb-0000-0000-0000-00000000000b', 'demo', false);
    perform public.create_report('demo', 'tq1', 1, 'errore', 'Segnalazione di B senza notifica.');
    select count(*) into v_n from public.notifications where user_id = 'bbbbbbbb-0000-0000-0000-00000000000b';
    v_r := v_r || case when v_n = 0 then 'U12 preferenza notifiche rispettata ok | ' else 'U12 KO[' || v_n || '] | ' end;

    -- ===== notifiche: solo read_at =====
    perform set_config('request.jwt.claims', c_a, true);
    begin
      update public.notifications set title = 'Modificato' where user_id = 'aaaaaaaa-0000-0000-0000-00000000000a';
      v_r := v_r || 'U13 KO[titolo modificabile] | ';
    exception when insufficient_privilege then v_r := v_r || 'U13 titolo non modificabile ok | '; end;
    update public.notifications set read_at = now() where user_id = 'aaaaaaaa-0000-0000-0000-00000000000a';
    get diagnostics v_n = row_count;
    v_r := v_r || case when v_n >= 1 then 'U14 lettura notifiche (read_at) ok | ' else 'U14 KO | ' end;

    -- ===== anonimo =====
    reset role; set local role anon;
    begin
      perform public.complete_material('demo', 'm-pub');
      v_r := v_r || 'U15 KO[anon ammesso] | ';
    exception when insufficient_privilege then v_r := v_r || 'U15 anonimo escluso ok | '; end;
    reset role;

    -- ===== export_my_data =====
    perform set_config('request.jwt.claims', c_a, true);
    set local role authenticated;
    v_j := public.export_my_data();
    v_r := v_r || case when jsonb_array_length(v_j -> 'attempts') = 2 and jsonb_array_length(v_j -> 'xp_events') = 2
        and (v_j -> 'profile' ->> 'email') = 'a@test.local' and v_j::text not like '%b@test.local%'
      then 'U16 esportazione dei soli dati propri ok | ' else 'U16 KO[att=' || jsonb_array_length(v_j -> 'attempts') || '] | ' end;

    -- ===== delete_my_account =====
    perform set_config('request.jwt.claims', c_d, true);
    begin
      perform public.delete_my_account('no');
      v_r := v_r || 'U17 KO[senza conferma] | ';
    exception when sqlstate '22023' then v_r := v_r || 'U17 conferma obbligatoria ok | '; end;
    perform set_config('request.jwt.claims', c_c, true);
    v_r := v_r || case when public.delete_my_account('ELIMINA') ->> 'error' = 'staff_account' then 'U18 account di redazione protetto ok | ' else 'U18 KO | ' end;
    perform set_config('request.jwt.claims', c_b, true);
    v_r := v_r || case when public.delete_my_account('ELIMINA') ->> 'error' = 'staff_account'
      then 'U18b ex revisore con contenuti protetto ok | ' else 'U18b KO | ' end;
    reset role;
    update public.question_versions set reviewer_id = null where reviewer_id = 'bbbbbbbb-0000-0000-0000-00000000000b';
    set local role authenticated;
    v_j := public.delete_my_account('ELIMINA');
    reset role;
    select count(*) into v_n from public.profiles_user where id = 'bbbbbbbb-0000-0000-0000-00000000000b';
    v_r := v_r || case when v_j ->> 'ok' = 'true' and v_n = 0 then 'U19 cancellazione account ok | ' else 'U19 KO[' || v_j::text || '] | ' end;
    select count(*) into v_n from public.attempts where user_id = 'bbbbbbbb-0000-0000-0000-00000000000b';
    v_r := v_r || case when v_n = 0 then 'U20 dati personali eliminati ok | ' else 'U20 KO | ' end;
    select count(*) into v_n from public.reports where reporter_id is null and env = 'demo';
    v_r := v_r || case when v_n = 1 then 'U21 segnalazioni rese anonime ok | ' else 'U21 KO[' || v_n || '] | ' end;

    raise exception 'RISULTATI: %', v_r;
  exception
    when others then
      get stacked diagnostics v_state = returned_sqlstate;
      if v_state = 'P0001' and sqlerrm like 'RISULTATI:%' then raise; end if;
      raise exception 'RISULTATI: % !!ERRORE [%] %', v_r, v_state, sqlerrm;
  end;
end $$;
