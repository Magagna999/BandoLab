-- BandoLab — test delle funzioni RPC editoriali (patch-11)
-- Stesse regole degli altri test: dati finti, ruoli simulati, termina SEMPRE con l'errore voluto "RISULTATI: ..."
-- che annulla tutto. "Exx ok" = superato, "Exx KO[...]" = fallito, "!!ERRORE" = eccezione inattesa.

do $$
declare
  c_u constant text := '{"sub":"aaaaaaaa-0000-0000-0000-00000000000a","role":"authenticated"}'; -- utente
  c_e2 constant text := '{"sub":"bbbbbbbb-0000-0000-0000-00000000000b","role":"authenticated"}'; -- editor 2
  c_e constant text := '{"sub":"cccccccc-0000-0000-0000-00000000000c","role":"authenticated"}'; -- editor
  c_r constant text := '{"sub":"dddddddd-0000-0000-0000-00000000000d","role":"authenticated"}'; -- revisore
  c_a constant text := '{"sub":"eeeeeeee-0000-0000-0000-00000000000e","role":"authenticated"}'; -- admin
  v_r text := '';
  v_j jsonb; v_n int; v_s text; v_state text; v_id text; v_id2 text; v_rid uuid;
  v_ok boolean;
  v_good jsonb := '{"text":"Quale organo approva il bilancio dello Stato?","options":["Il Parlamento","Il Governo","La Corte dei conti","Il CNEL"],"correct":0,"explanation":"Il bilancio è approvato con legge.","subject_id":"s1","topic_id":"t1","difficulty":2,"source":"Cost. art. 81","source_url":"https://www.normattiva.it","last_verified":"2026-10-01","next_review":"2027-10-01"}';
begin
  begin
    insert into auth.users (id, email, raw_user_meta_data) values
      ('aaaaaaaa-0000-0000-0000-00000000000a', 'u@test.local', '{"full_name":"Utente"}'),
      ('bbbbbbbb-0000-0000-0000-00000000000b', 'e2@test.local', '{"full_name":"Editor Due"}'),
      ('cccccccc-0000-0000-0000-00000000000c', 'e@test.local', '{"full_name":"Editor Uno"}'),
      ('dddddddd-0000-0000-0000-00000000000d', 'r@test.local', '{"full_name":"Revisore"}'),
      ('eeeeeeee-0000-0000-0000-00000000000e', 'a@test.local', '{"full_name":"Amministratore"}');
    update public.profiles_user set role = 'editor' where id in ('bbbbbbbb-0000-0000-0000-00000000000b', 'cccccccc-0000-0000-0000-00000000000c');
    update public.profiles_user set role = 'reviewer' where id = 'dddddddd-0000-0000-0000-00000000000d';
    update public.profiles_user set role = 'admin' where id = 'eeeeeeee-0000-0000-0000-00000000000e';
    insert into public.subjects (id, env, name) values ('s1', 'demo', 'Materia 1'), ('s2', 'demo', 'Materia 2');
    insert into public.topics (id, env, name, subject_id) values ('t1', 'demo', 'Argomento 1', 's1'), ('t2', 'demo', 'Argomento 2', 's2');

    -- ===== permessi di base =====
    perform set_config('request.jwt.claims', c_u, true);
    set local role authenticated;
    begin perform public.create_question('demo'); v_r := v_r || 'E01 KO[utente ha creato] | ';
    exception when sqlstate '42501' then v_r := v_r || 'E01 utente semplice escluso ok | '; end;
    reset role; set local role anon;
    begin perform public.create_question('demo'); v_r := v_r || 'E02 KO[anon ammesso] | ';
    exception when insufficient_privilege then v_r := v_r || 'E02 anonimo escluso ok | '; end;
    reset role;

    -- ===== creazione e modifica =====
    perform set_config('request.jwt.claims', c_e, true);
    set local role authenticated;
    v_j := public.create_question('demo');
    v_id := v_j ->> 'id';
    select count(*) into v_n from public.audit_log where target = v_id and action = 'Creazione bozza';
    v_r := v_r || case when v_j ->> 'ok' = 'true' and v_n = 1 then 'E03 creazione bozza e audit ok | ' else 'E03 KO[' || v_j::text || '] | ' end;
    v_j := public.update_draft('demo', v_id, '{"text":"Testo provvisorio della domanda","subject_id":"s1","topic_id":"t1"}');
    v_r := v_r || case when v_j ->> 'ok' = 'true' then 'E04 modifica bozza ok | ' else 'E04 KO[' || v_j::text || '] | ' end;
    perform set_config('request.jwt.claims', c_e2, true);
    v_r := v_r || case when public.update_draft('demo', v_id, '{"source":"x"}') ->> 'error' = 'not_author' then 'E05 editor non autore escluso ok | ' else 'E05 KO | ' end;
    perform set_config('request.jwt.claims', c_e, true);
    begin perform public.update_draft('demo', v_id, '{"stato":"published"}'); v_r := v_r || 'E06 KO[campo estraneo] | ';
    exception when sqlstate '22023' then v_r := v_r || 'E06 campo non ammesso rifiutato ok | '; end;
    begin perform public.update_draft('demo', v_id, '{"options":["a","b"]}'); v_r := v_r || 'E07 KO[2 opzioni] | ';
    exception when sqlstate '22023' then v_r := v_r || 'E07 opzioni non valide rifiutate ok | '; end;
    begin perform public.update_draft('demo', v_id, '{"subject_id":"s1","topic_id":"t2"}'); v_r := v_r || 'E08 KO[argomento estraneo] | ';
    exception when sqlstate '22023' then v_r := v_r || 'E08 argomento fuori materia rifiutato ok | '; end;
    perform public.update_draft('demo', v_id, '{"subject_id":"s2"}');
    select topic_id into v_s from public.question_versions where env = 'demo' and question_id = v_id;
    v_r := v_r || case when v_s is null then 'E09 cambio materia azzera l''argomento ok | ' else 'E09 KO[' || v_s || '] | ' end;
    v_r := v_r || case when public.update_draft('demo', 'nonesiste', '{"source":"x"}') ->> 'error' = 'not_found' then 'E10 id inesistente gestito ok | ' else 'E10 KO | ' end;

    -- ===== invio =====
    v_j := public.transition('demo', v_id, 'submit');
    v_r := v_r || case when v_j ->> 'error' = 'validation' and v_j -> 'errors' ? 'options' and v_j -> 'errors' ? 'topic' and v_j -> 'errors' ? 'sourceUrl'
      then 'E11 invio incompleto con elenco errori ok | ' else 'E11 KO[' || v_j::text || '] | ' end;
    perform public.update_draft('demo', v_id, v_good);
    v_j := public.transition('demo', v_id, 'submit');
    select status::text into v_s from public.question_versions where env = 'demo' and question_id = v_id and v = 1;
    v_r := v_r || case when v_j ->> 'ok' = 'true' and v_s = 'review' then 'E12 invio in revisione ok | ' else 'E12 KO[' || v_j::text || ' ' || coalesce(v_s, '-') || '] | ' end;
    v_r := v_r || case when public.update_draft('demo', v_id, '{"source":"x"}') ->> 'error' = 'not_editable' then 'E13 contenuto in revisione non modificabile ok | ' else 'E13 KO | ' end;
    begin perform public.transition('demo', v_id, 'approve'); v_r := v_r || 'E14 KO[editor approva] | ';
    exception when sqlstate '42501' then v_r := v_r || 'E14 editor non può approvare ok | '; end;
    begin perform public.transition('demo', v_id, 'boh'); v_r := v_r || 'E15 KO[azione sconosciuta] | ';
    exception when sqlstate '22023' then v_r := v_r || 'E15 azione sconosciuta rifiutata ok | '; end;

    -- ===== revisione: modifiche richieste, nuovo invio, approvazione, pubblicazione =====
    perform set_config('request.jwt.claims', c_r, true);
    v_r := v_r || case when public.transition('demo', v_id, 'changes') ->> 'error' = 'note_required' then 'E16 modifiche senza nota rifiutate ok | ' else 'E16 KO | ' end;
    v_j := public.transition('demo', v_id, 'changes', 'Citare meglio la fonte');
    select review_note into v_s from public.question_versions where env = 'demo' and question_id = v_id and v = 1;
    v_r := v_r || case when v_j ->> 'ok' = 'true' and v_s = 'Citare meglio la fonte' then 'E17 modifiche richieste con nota ok | ' else 'E17 KO[' || v_j::text || '] | ' end;
    perform set_config('request.jwt.claims', c_e, true);
    v_j := public.update_draft('demo', v_id, '{"source":"Cost. art. 81 e L. 196/2009"}');
    v_r := v_r || case when v_j ->> 'ok' = 'true' then 'E18 modifica dopo richiesta ok | ' else 'E18 KO[' || v_j::text || '] | ' end;
    perform public.transition('demo', v_id, 'submit');
    perform set_config('request.jwt.claims', c_r, true);
    v_r := v_r || case when public.transition('demo', v_id, 'publish') ->> 'error' = 'invalid_state' then 'E19 pubblicazione senza approvazione rifiutata ok | ' else 'E19 KO | ' end;
    perform public.transition('demo', v_id, 'approve');
    v_j := public.transition('demo', v_id, 'publish');
    select q.current_version into v_n from public.questions q where q.env = 'demo' and q.id = v_id;
    select count(*) into v_n from (select 1 from public.live_questions where env = 'demo' and question_id = v_id) x;
    v_r := v_r || case when v_j ->> 'ok' = 'true' and v_n = 1 then 'E20 approvazione, pubblicazione e vista live ok | ' else 'E20 KO[' || v_j::text || ' n=' || v_n || '] | ' end;

    -- ===== nuova versione =====
    perform set_config('request.jwt.claims', c_e, true);
    v_j := public.transition('demo', v_id, 'newVersion', 'Aggiornamento normativo');
    select count(*) into v_n from public.question_versions where env = 'demo' and question_id = v_id and v = 2 and status = 'draft' and author_id = 'cccccccc-0000-0000-0000-00000000000c' and change_note = 'Aggiornamento normativo';
    v_r := v_r || case when v_j ->> 'v' = '2' and v_n = 1 then 'E21 nuova versione in bozza ok | ' else 'E21 KO[' || v_j::text || '] | ' end;
    v_r := v_r || case when public.transition('demo', v_id, 'newVersion') ->> 'error' = 'invalid_state' then 'E22 seconda nuova versione rifiutata ok | ' else 'E22 KO | ' end;
    perform public.update_draft('demo', v_id, '{"explanation":"Il bilancio è approvato con legge annuale."}');
    perform public.transition('demo', v_id, 'submit');
    perform set_config('request.jwt.claims', c_r, true);
    perform public.transition('demo', v_id, 'approve');
    perform public.transition('demo', v_id, 'publish');
    select count(*) = 2 into v_ok from public.question_versions where env = 'demo' and question_id = v_id and ((v = 1 and status = 'superseded') or (v = 2 and status = 'published'));
    select q.current_version into v_n from public.questions q where q.env = 'demo' and q.id = v_id;
    v_r := v_r || case when v_n = 2 and v_ok then 'E23 v1 sostituita, v2 corrente ok | ' else 'E23 KO[' || v_n || '] | ' end;

    -- ===== sospensione e verifica =====
    v_r := v_r || case when public.transition('demo', v_id, 'suspend') ->> 'error' = 'note_required' then 'E24 sospensione senza motivo rifiutata ok | ' else 'E24 KO | ' end;
    perform public.transition('demo', v_id, 'suspend', 'Norma in revisione');
    select count(*) into v_n from public.live_questions where env = 'demo' and question_id = v_id;
    v_r := v_r || case when v_n = 0 then 'E25 sospesa: esclusa dalle domande attive ok | ' else 'E25 KO[' || v_n || '] | ' end;
    perform public.transition('demo', v_id, 'unsuspend');
    select count(*) into v_n from public.live_questions where env = 'demo' and question_id = v_id;
    v_r := v_r || case when v_n = 1 then 'E26 sospensione revocata ok | ' else 'E26 KO | ' end;
    perform public.transition('demo', v_id, 'verify');
    select count(*) into v_n from public.question_versions where env = 'demo' and question_id = v_id and v = 2 and last_verified = current_date and next_review = current_date + 365;
    v_r := v_r || case when v_n = 1 then 'E27 verifica normativa aggiorna le date ok | ' else 'E27 KO | ' end;

    -- ===== autore = revisore =====
    reset role;
    insert into public.questions (id, env) values ('qself', 'demo'), ('qadm', 'demo');
    insert into public.question_versions (env, question_id, v, status, text, options, correct, explanation, subject_id, topic_id, difficulty, source, source_url, last_verified, next_review, author_id)
    values ('demo', 'qself', 1, 'review', 'Domanda scritta dal revisore stesso', array['a','b','c','d'], 0, 'Spiegazione valida', 's1', 't1', 1, 'Fonte', 'https://x.it', current_date - 1, current_date + 100, 'dddddddd-0000-0000-0000-00000000000d'),
           ('demo', 'qadm', 1, 'review', 'Domanda scritta dall''amministratore', array['a','b','c','d'], 0, 'Spiegazione valida', 's1', 't1', 1, 'Fonte', 'https://x.it', current_date - 1, current_date + 100, 'eeeeeeee-0000-0000-0000-00000000000e');
    perform set_config('request.jwt.claims', c_r, true);
    set local role authenticated;
    v_r := v_r || case when public.transition('demo', 'qself', 'approve') ->> 'error' = 'self_review' then 'E28 revisore non approva il proprio contenuto ok | ' else 'E28 KO | ' end;
    perform set_config('request.jwt.claims', c_a, true);
    perform public.transition('demo', 'qadm', 'approve');
    v_j := public.transition('demo', 'qadm', 'publish');
    v_r := v_r || case when v_j ->> 'ok' = 'true' then 'E29 amministratore approva e pubblica il proprio contenuto ok | ' else 'E29 KO[' || v_j::text || '] | ' end;

    -- ===== segnalazioni =====
    perform set_config('request.jwt.claims', c_u, true);
    v_j := public.create_report('demo', 'qadm', 1, 'errore', 'La risposta non mi sembra corretta, ricontrollare.');
    v_rid := (v_j ->> 'id')::uuid;
    perform set_config('request.jwt.claims', c_e, true);
    begin perform public.update_report(v_rid, '{"status":"resolved"}'); v_r := v_r || 'E30 KO[editor gestisce] | ';
    exception when sqlstate '42501' then v_r := v_r || 'E30 editor non gestisce segnalazioni ok | '; end;
    perform set_config('request.jwt.claims', c_r, true);
    begin perform public.update_report(v_rid, '{"assignee_id":"cccccccc-0000-0000-0000-00000000000c"}'); v_r := v_r || 'E31 KO[assegnata a editor] | ';
    exception when sqlstate '22023' then v_r := v_r || 'E31 assegnazione solo a revisori/admin ok | '; end;
    perform public.update_report(v_rid, '{"assignee_id":"dddddddd-0000-0000-0000-00000000000d","priority":"alta"}');
    v_j := public.update_report(v_rid, '{"status":"resolved"}');
    reset role;   -- la lettura delle notifiche altrui avviene come proprietario: il revisore non le vedrebbe (RLS)
    select count(*) into v_n from public.notifications where user_id = 'aaaaaaaa-0000-0000-0000-00000000000a' and title = 'Segnalazione gestita';
    v_r := v_r || case when v_j ->> 'ok' = 'true' and v_n = 1 then 'E32 segnalazione gestita e segnalante avvisato ok | ' else 'E32 KO[' || v_j::text || ' n=' || v_n || '] | ' end;
    set local role authenticated;

    -- ===== duplicati =====
    reset role;
    insert into public.professional_profiles (id, env, name) values ('pp1', 'demo', 'Profilo');
    insert into public.question_profiles (env, question_id, profile_id) values ('demo', 'qself', 'pp1');
    perform set_config('request.jwt.claims', c_r, true);
    set local role authenticated;
    v_j := public.decide_duplicate('demo', 'qadm', 'qself', 'merge', 'identiche');
    select merged_into into v_s from public.questions where env = 'demo' and id = 'qself';
    select count(*) into v_n from public.question_profiles where env = 'demo' and question_id = 'qadm' and profile_id = 'pp1';
    v_r := v_r || case when v_j ->> 'ok' = 'true' and v_s = 'qadm' and v_n = 1 then 'E33 consolidamento e profili uniti ok | ' else 'E33 KO[' || v_j::text || ']| ' end;
    v_r := v_r || case when public.decide_duplicate('demo', 'qadm', 'qself', 'merge') ->> 'error' = 'already_merged' then 'E34 doppio consolidamento rifiutato ok | ' else 'E34 KO | ' end;
    perform set_config('request.jwt.claims', c_e, true);
    begin perform public.decide_duplicate('demo', 'qadm', v_id, 'keep'); v_r := v_r || 'E35 KO[editor decide] | ';
    exception when sqlstate '42501' then v_r := v_r || 'E35 editor non decide sui duplicati ok | '; end;

    -- ===== importazione =====
    begin perform public.import_questions('demo', '[]'); v_r := v_r || 'E36 KO[] | ';
    exception when sqlstate '42501' then v_r := v_r || 'E36 importazione solo admin ok | '; end;
    perform set_config('request.jwt.claims', c_a, true);
    v_j := public.import_questions('demo', jsonb_build_array(v_good || '{"id":"imp1"}', (v_good - 'options') || '{"id":"imp2"}', v_good || '{"id":"imp1"}'));
    select count(*) into v_n from public.questions where env = 'demo' and id in ('imp1', 'imp2');
    v_r := v_r || case when v_j ->> 'error' = 'validation' and v_n = 0 and (v_j -> 'rows' -> 0 ->> 'row') = '2' and v_j ->> 'bad_rows' = '2'
      then 'E37 righe errate: nulla importato, errori per riga ok | ' else 'E37 KO[' || v_j::text || ' n=' || v_n || '] | ' end;
    v_j := public.import_questions('demo', jsonb_build_array(v_good || '{"id":"imp1"}', v_good || '{"id":"imp2"}', v_good));
    v_r := v_r || case when v_j ->> 'inserted' = '3' then 'E38 importazione valida (3 domande) ok | ' else 'E38 KO[' || v_j::text || '] | ' end;
    v_j := public.import_questions('demo', jsonb_build_array(v_good || '{"id":"imp1"}'));
    v_r := v_r || case when v_j ->> 'skipped' = '1' and v_j ->> 'inserted' = '0' then 'E39 importazione ripetibile (id già presenti saltati) ok | ' else 'E39 KO[' || v_j::text || '] | ' end;
    v_j := public.import_questions('demo', jsonb_build_array(v_good || '{"id":"imp3"}'), 'published');
    select count(*) into v_n from public.live_questions where env = 'demo' and question_id = 'imp3';
    v_r := v_r || case when v_j ->> 'inserted' = '1' and v_n = 1 then 'E40 importazione come pubblicate (admin autore e revisore) ok | ' else 'E40 KO[' || v_j::text || '] | ' end;
    select count(*) into v_n from public.audit_log where actor_id = 'eeeeeeee-0000-0000-0000-00000000000e' and target = 'import';
    v_r := v_r || case when v_n >= 3 then 'E41 audit delle importazioni ok | ' else 'E41 KO[' || v_n || '] | ' end;

    raise exception 'RISULTATI: %', v_r;
  exception
    when others then
      get stacked diagnostics v_state = returned_sqlstate;
      if v_state = 'P0001' and sqlerrm like 'RISULTATI:%' then raise; end if;
      raise exception 'RISULTATI: % !!ERRORE [%] %', v_r, v_state, sqlerrm;
  end;
end $$;
