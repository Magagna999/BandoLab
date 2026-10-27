-- BandoLab — test delle funzioni RPC per materiali, quiz, catalogo e ruoli (patch-12)
-- Stesse regole degli altri test: dati finti, ruoli simulati, termina SEMPRE con l'errore voluto "RISULTATI: ...".

do $$
declare
  c_u constant text := '{"sub":"aaaaaaaa-0000-0000-0000-00000000000a","role":"authenticated"}'; -- utente
  c_e2 constant text := '{"sub":"bbbbbbbb-0000-0000-0000-00000000000b","role":"authenticated"}'; -- editor 2
  c_e constant text := '{"sub":"cccccccc-0000-0000-0000-00000000000c","role":"authenticated"}'; -- editor
  c_r constant text := '{"sub":"dddddddd-0000-0000-0000-00000000000d","role":"authenticated"}'; -- revisore
  c_a constant text := '{"sub":"eeeeeeee-0000-0000-0000-00000000000e","role":"authenticated"}'; -- admin
  v_r text := '';
  v_j jsonb; v_n int; v_s text; v_state text; v_m text; v_m2 text; v_m3 text; v_z text; v_z2 text; v_x text;
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
    -- isola il test: l'unico amministratore è quello di prova
    update public.profiles_user set role = 'user' where role = 'admin' and id <> 'eeeeeeee-0000-0000-0000-00000000000e';
    insert into public.subjects (id, env, name) values ('s1', 'demo', 'Materia 1'), ('s2', 'demo', 'Materia 2');
    insert into public.topics (id, env, name, subject_id) values ('t1', 'demo', 'Argomento 1', 's1'), ('t2', 'demo', 'Argomento 2', 's2');
    insert into public.areas (id, env, name) values ('a1', 'demo', 'Area 1');
    insert into public.questions (id, env, current_version) values ('p1', 'demo', 1), ('p2', 'demo', 1), ('p3', 'demo', 1);
    insert into public.question_versions (env, question_id, v, status, text, options, correct, explanation, subject_id, topic_id, difficulty, source, source_url, last_verified, next_review, author_id, reviewer_id, approved_at, published_at)
    select 'demo', 'p' || i, 1, 'published', 'Testo della domanda pubblicata ' || i, array['a','b','c','d'], 0, 'Spiegazione valida ' || i, 's1', 't1', 1, 'Fonte', 'https://x.it',
           current_date - 1, current_date + 100, 'cccccccc-0000-0000-0000-00000000000c', 'dddddddd-0000-0000-0000-00000000000d', now(), now()
    from generate_series(1, 3) i;

    -- ===== materiali: creazione e modifica =====
    perform set_config('request.jwt.claims', c_u, true);
    set local role authenticated;
    begin perform public.create_material('demo', 'Titolo valido', 's1', 't1'); v_r := v_r || 'M01 KO[utente crea] | ';
    exception when sqlstate '42501' then v_r := v_r || 'M01 utente semplice escluso ok | '; end;
    perform set_config('request.jwt.claims', c_e, true);
    begin perform public.create_material('demo', 'Titolo valido', 's1', 't2'); v_r := v_r || 'M02 KO[argomento estraneo] | ';
    exception when sqlstate '22023' then v_r := v_r || 'M02 materia/argomento incoerenti rifiutati ok | '; end;
    v_j := public.create_material('demo', 'Scheda di prova', 's1', 't1');
    v_m := v_j ->> 'id';
    select count(*) into v_n from public.audit_log where target = v_m and action = 'Materiale: creazione bozza';
    v_r := v_r || case when v_j ->> 'ok' = 'true' and v_n = 1 then 'M03 creazione bozza e audit ok | ' else 'M03 KO[' || v_j::text || '] | ' end;
    perform set_config('request.jwt.claims', c_e2, true);
    v_r := v_r || case when public.update_material('demo', v_m, '{"source":"x"}') ->> 'error' = 'not_author' then 'M04 editor non autore escluso ok | ' else 'M04 KO | ' end;
    perform set_config('request.jwt.claims', c_e, true);
    begin perform public.update_material('demo', v_m, '{"status":"published"}'); v_r := v_r || 'M05 KO[campo estraneo] | ';
    exception when sqlstate '22023' then v_r := v_r || 'M05 campo non ammesso rifiutato ok | '; end;

    -- ===== materiali: invio, revisione, pubblicazione =====
    v_j := public.material_transition('demo', v_m, 'submit');
    v_r := v_r || case when v_j ->> 'error' = 'validation' and v_j -> 'errors' ? 'source' and v_j -> 'errors' ? 'sections'
      then 'M06 invio incompleto con elenco errori ok | ' else 'M06 KO[' || v_j::text || '] | ' end;
    v_j := public.update_material('demo', v_m, '{"source":"Fonte ufficiale","key_concepts":["uno"," due ",""],"sections":[{"title":"Introduzione","body":"Testo della prima sezione, abbastanza lungo."},{"title":"Seconda","body":"Altro testo della seconda sezione del materiale."}]}');
    select count(*) into v_n from public.material_sections where env = 'demo' and material_id = v_m;
    select array_length(key_concepts, 1)::text into v_s from public.materials where env = 'demo' and id = v_m;
    v_r := v_r || case when v_j ->> 'ok' = 'true' and v_n = 2 and v_s = '2' then 'M07 sezioni e concetti chiave salvati ok | ' else 'M07 KO[' || v_j::text || ' n=' || v_n || ' k=' || coalesce(v_s, '-') || '] | ' end;
    v_j := public.update_material('demo', v_m, '{"sections":[{"title":"Unica","body":"Una sola sezione, sostituisce le precedenti."}]}');
    select count(*) into v_n from public.material_sections where env = 'demo' and material_id = v_m;
    v_r := v_r || case when v_n = 1 then 'M08 le sezioni vengono sostituite ok | ' else 'M08 KO[' || v_n || '] | ' end;
    v_j := public.material_transition('demo', v_m, 'submit');
    v_r := v_r || case when v_j ->> 'ok' = 'true' then 'M09 invio in revisione ok | ' else 'M09 KO[' || v_j::text || '] | ' end;
    v_r := v_r || case when public.update_material('demo', v_m, '{"source":"y"}') ->> 'error' = 'not_editable' then 'M10 materiale in revisione non modificabile ok | ' else 'M10 KO | ' end;
    begin perform public.material_transition('demo', v_m, 'approve'); v_r := v_r || 'M11 KO[editor approva] | ';
    exception when sqlstate '42501' then v_r := v_r || 'M11 editor non approva ok | '; end;
    perform set_config('request.jwt.claims', c_r, true);
    v_r := v_r || case when public.material_transition('demo', v_m, 'publish') ->> 'error' = 'invalid_state' then 'M12 pubblicazione senza approvazione rifiutata ok | ' else 'M12 KO | ' end;
    perform public.material_transition('demo', v_m, 'approve');
    v_j := public.material_transition('demo', v_m, 'publish');
    select status::text into v_s from public.materials where env = 'demo' and id = v_m;
    v_r := v_r || case when v_j ->> 'ok' = 'true' and v_s = 'published' then 'M13 approvazione e pubblicazione ok | ' else 'M13 KO[' || v_j::text || '] | ' end;
    v_j := public.material_transition('demo', v_m, 'unpublish');
    select status::text into v_s from public.materials where env = 'demo' and id = v_m;
    v_r := v_r || case when v_j ->> 'ok' = 'true' and v_s = 'draft' then 'M14 ritiro dalla pubblicazione ok | ' else 'M14 KO[' || v_j::text || '] | ' end;

    -- ===== materiali: PDF e file =====
    perform set_config('request.jwt.claims', c_e, true);
    v_m2 := public.create_material('demo', 'Documento PDF di prova', 's1', 't1', 'pdf-view') ->> 'id';
    perform public.update_material('demo', v_m2, '{"source":"Fonte PDF"}');
    v_j := public.material_transition('demo', v_m2, 'submit');
    v_r := v_r || case when v_j ->> 'error' = 'validation' and v_j -> 'errors' ? 'file' then 'M15 PDF senza file rifiutato ok | ' else 'M15 KO[' || v_j::text || '] | ' end;
    begin perform public.set_material_file('demo', v_m2, '../segreto.pdf'); v_r := v_r || 'M16 KO[percorso con ..] | ';
    exception when sqlstate '22023' then v_r := v_r || 'M16 percorso non valido rifiutato ok | '; end;
    perform public.set_material_file('demo', v_m2, 'materiali/documento.pdf');
    v_j := public.material_transition('demo', v_m2, 'submit');
    v_r := v_r || case when v_j ->> 'ok' = 'true' then 'M17 PDF con file inviato ok | ' else 'M17 KO[' || v_j::text || '] | ' end;

    -- ===== autore = revisore (materiali) =====
    reset role;
    insert into public.materials (id, env, title, subject_id, topic_id, format, status, source, last_verified, next_review, author_id)
    values ('mrev', 'demo', 'Materiale del revisore', 's1', 't1', 'scheda', 'review', 'F', current_date - 1, current_date + 10, 'dddddddd-0000-0000-0000-00000000000d'),
           ('madm', 'demo', 'Materiale dell''amministratore', 's1', 't1', 'scheda', 'review', 'F', current_date - 1, current_date + 10, 'eeeeeeee-0000-0000-0000-00000000000e');
    insert into public.material_sections (env, material_id, id, position, title, body)
    values ('demo', 'mrev', 'x1', 1, 'T', 'Testo abbastanza lungo per superare il controllo'), ('demo', 'madm', 'x2', 1, 'T', 'Testo abbastanza lungo per superare il controllo');
    perform set_config('request.jwt.claims', c_r, true);
    set local role authenticated;
    v_r := v_r || case when public.material_transition('demo', 'mrev', 'approve') ->> 'error' = 'self_review' then 'M18 revisore non approva il proprio materiale ok | ' else 'M18 KO | ' end;
    perform set_config('request.jwt.claims', c_a, true);
    perform public.material_transition('demo', 'madm', 'approve');
    v_j := public.material_transition('demo', 'madm', 'publish');
    v_r := v_r || case when v_j ->> 'ok' = 'true' then 'M19 amministratore approva e pubblica il proprio materiale ok | ' else 'M19 KO[' || v_j::text || '] | ' end;

    -- ===== quiz =====
    perform set_config('request.jwt.claims', c_e, true);
    v_j := public.save_quiz('demo', '{"title":"Allenamento di prova","mode":"training","subject_ids":["s1"],"question_count":3}');
    v_z := v_j ->> 'id';
    v_r := v_r || case when v_j ->> 'ok' = 'true' and v_z is not null then 'Q01 creazione quiz in bozza ok | ' else 'Q01 KO[' || v_j::text || '] | ' end;
    begin perform public.save_quiz('demo', '{"title":"Simulazione senza durata","mode":"exam","question_count":3}'); v_r := v_r || 'Q02 KO[exam senza durata] | ';
    exception when sqlstate '22023' then v_r := v_r || 'Q02 simulazione senza durata rifiutata ok | '; end;
    begin perform public.save_quiz('demo', '{"title":"Quiz materia inesistente","mode":"training","subject_ids":["zzz"],"question_count":3}'); v_r := v_r || 'Q03 KO[materia inesistente] | ';
    exception when sqlstate '22023' then v_r := v_r || 'Q03 materia inesistente rifiutata ok | '; end;
    v_j := public.save_quiz('demo', jsonb_build_object('id', v_z, 'title', 'Allenamento rinominato', 'question_count', 5));
    select title || '/' || question_count into v_s from public.quizzes where env = 'demo' and id = v_z;
    v_r := v_r || case when v_j ->> 'ok' = 'true' and v_s = 'Allenamento rinominato/5' then 'Q04 modifica quiz ok | ' else 'Q04 KO[' || coalesce(v_s, '-') || '] | ' end;
    begin perform public.set_quiz_status('demo', v_z, 'published'); v_r := v_r || 'Q05 KO[editor pubblica quiz] | ';
    exception when sqlstate '42501' then v_r := v_r || 'Q05 editor non pubblica quiz ok | '; end;
    perform set_config('request.jwt.claims', c_r, true);
    v_j := public.set_quiz_status('demo', v_z, 'published');
    v_r := v_r || case when v_j ->> 'error' = 'checks_failed' and v_j::text like '%3 disponibili su 5%' then 'Q06 pubblicazione bloccata: domande insufficienti ok | ' else 'Q06 KO[' || v_j::text || '] | ' end;
    perform set_config('request.jwt.claims', c_e, true);
    perform public.save_quiz('demo', jsonb_build_object('id', v_z, 'question_count', 3));
    perform set_config('request.jwt.claims', c_r, true);
    v_j := public.set_quiz_status('demo', v_z, 'published');
    v_r := v_r || case when v_j ->> 'ok' = 'true' then 'Q07 quiz pubblicato ok | ' else 'Q07 KO[' || v_j::text || '] | ' end;
    perform set_config('request.jwt.claims', c_e, true);
    v_r := v_r || case when public.save_quiz('demo', jsonb_build_object('id', v_z, 'title', 'Altro titolo')) ->> 'error' = 'not_editable' then 'Q08 quiz pubblicato non modificabile ok | ' else 'Q08 KO | ' end;
    perform set_config('request.jwt.claims', c_r, true);
    v_j := public.set_quiz_status('demo', v_z, 'draft');
    select status::text into v_s from public.quizzes where env = 'demo' and id = v_z;
    v_r := v_r || case when v_j ->> 'ok' = 'true' and v_s = 'draft' then 'Q09 ritiro del quiz ok | ' else 'Q09 KO | ' end;

    -- ===== catalogo =====
    perform set_config('request.jwt.claims', c_r, true);
    begin perform public.tax_edit('demo', 'subjects', null, '{"name":"Nuova"}'); v_r := v_r || 'C01 KO[revisore edita catalogo] | ';
    exception when sqlstate '42501' then v_r := v_r || 'C01 solo l''amministratore modifica il catalogo ok | '; end;
    perform set_config('request.jwt.claims', c_a, true);
    v_j := public.tax_edit('demo', 'subjects', null, '{"name":"Materia nuova"}');
    v_x := v_j ->> 'id';
    v_r := v_r || case when v_j ->> 'ok' = 'true' and v_x like 's-%' then 'C02 nuova materia ok | ' else 'C02 KO[' || v_j::text || '] | ' end;
    begin perform public.tax_edit('demo', 'topics', null, '{"name":"Argomento senza materia"}'); v_r := v_r || 'C03 KO[argomento senza materia] | ';
    exception when sqlstate '22023' then v_r := v_r || 'C03 argomento senza materia rifiutato ok | '; end;
    v_j := public.tax_edit('demo', 'topics', null, jsonb_build_object('name', 'Argomento nuovo', 'subject_id', v_x));
    v_r := v_r || case when v_j ->> 'ok' = 'true' then 'C04 nuovo argomento ok | ' else 'C04 KO[' || v_j::text || '] | ' end;
    perform public.tax_edit('demo', 'subjects', v_x, '{"name":"Materia rinominata"}');
    select name into v_s from public.subjects where env = 'demo' and id = v_x;
    v_r := v_r || case when v_s = 'Materia rinominata' then 'C05 rinomina ok | ' else 'C05 KO | ' end;
    v_r := v_r || case when public.tax_edit('demo', 'subjects', 'inesistente', '{"name":"X1"}') ->> 'error' = 'not_found' then 'C06 voce inesistente gestita ok | ' else 'C06 KO | ' end;
    begin perform public.tax_edit('demo', 'subjects', v_x, '{"id":"altro"}'); v_r := v_r || 'C07 KO[campo estraneo] | ';
    exception when sqlstate '22023' then v_r := v_r || 'C07 campo non ammesso rifiutato ok | '; end;
    perform public.tax_edit('demo', 'entities', null, '{"name":"Ente nuovo","area_id":"a1"}');
    v_j := public.tax_edit('demo', 'professional_profiles', null, jsonb_build_object('name', 'Profilo nuovo', 'subject_ids', jsonb_build_array('s1', 's2', 'nonesiste')));
    select count(*) into v_n from public.profile_subjects where env = 'demo' and profile_id = v_j ->> 'id';
    v_r := v_r || case when v_j ->> 'ok' = 'true' and v_n = 2 then 'C08 profilo con materie collegate (inesistenti ignorate) ok | ' else 'C08 KO[' || v_n || '] | ' end;

    -- ===== ruoli =====
    perform set_config('request.jwt.claims', c_r, true);
    begin perform public.set_role('aaaaaaaa-0000-0000-0000-00000000000a', 'editor'); v_r := v_r || 'R01 KO[revisore cambia ruoli] | ';
    exception when sqlstate '42501' then v_r := v_r || 'R01 solo l''amministratore cambia i ruoli ok | '; end;
    perform set_config('request.jwt.claims', c_a, true);
    v_j := public.set_role('aaaaaaaa-0000-0000-0000-00000000000a', 'editor');
    select role::text into v_s from public.profiles_user where id = 'aaaaaaaa-0000-0000-0000-00000000000a';
    v_r := v_r || case when v_j ->> 'ok' = 'true' and v_s = 'editor' then 'R02 assegnazione ruolo ok | ' else 'R02 KO[' || v_j::text || '] | ' end;
    v_j := public.set_role('eeeeeeee-0000-0000-0000-00000000000e', 'user');
    v_r := v_r || case when v_j ->> 'error' = 'last_admin' then 'R03 ultimo amministratore protetto ok | ' else 'R03 KO[' || v_j::text || '] | ' end;
    perform public.set_role('dddddddd-0000-0000-0000-00000000000d', 'admin');
    v_j := public.set_role('eeeeeeee-0000-0000-0000-00000000000e', 'reviewer');
    v_r := v_r || case when v_j ->> 'ok' = 'true' then 'R04 con un secondo admin si può declassare ok | ' else 'R04 KO[' || v_j::text || '] | ' end;
    v_r := v_r || case when public.set_role('00000000-0000-0000-0000-0000000000ff', 'user') ->> 'error' = 'not_found' then 'R05 utente inesistente gestito ok | ' else 'R05 KO | ' end;

    raise exception 'RISULTATI: %', v_r;
  exception
    when others then
      get stacked diagnostics v_state = returned_sqlstate;
      if v_state = 'P0001' and sqlerrm like 'RISULTATI:%' then raise; end if;
      raise exception 'RISULTATI: % !!ERRORE [%] %', v_r, v_state, sqlerrm;
  end;
end $$;
