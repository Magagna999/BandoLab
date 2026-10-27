-- BandoLab — patch 12: funzioni RPC editoriali per materiali, quiz, catalogo e ruoli
-- Da eseguire dopo patch-11 (usa private.req_role e private.write_audit).
--
-- Sostituiscono nel core: BL.createMaterial, BL.updateMaterial, BL.materialTransition, il salvataggio e la
-- pubblicazione dei quiz (BL.quizChecks), BL.taxEdit, BL.setRole.
-- Convenzioni come patch-11: ruolo non ammesso -> 42501; dati non validi -> 22023;
-- condizioni previste -> {"ok": false, "error": "...", "why": "..."}. Ogni modifica scrive in audit_log.
-- Nota: il registro di audit richiede un ambiente; le operazioni globali (ruoli) sono registrate in 'real'.
-- STATO: APPLICATA al database il 27/10/2026 (migrazione patch_12_rpc_content), verificata con rpc-content.test.sql.

-- =========================================================
-- Controlli di completezza di un materiale (come BL.validateMaterial)
-- =========================================================
create or replace function private.validate_material(p_env public.env_t, p_mid text)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  m public.materials%rowtype;
  e jsonb := '{}';
begin
  select * into m from public.materials where env = p_env and id = p_mid;
  if not found then return jsonb_build_object('material', 'Materiale non trovato.'); end if;
  if m.title is null or char_length(btrim(m.title)) < 4 then e := e || jsonb_build_object('title', 'Inserisci un titolo (almeno 4 caratteri).'); end if;
  if btrim(coalesce(m.source, '')) = '' then e := e || jsonb_build_object('source', 'Indica la fonte.'); end if;
  if m.last_verified is null then e := e || jsonb_build_object('lastVerified', 'Indica la data dell''ultima verifica.'); end if;
  if m.next_review is null then
    e := e || jsonb_build_object('nextReview', 'Indica la data della prossima revisione.');
  elsif m.last_verified is not null and m.next_review <= m.last_verified then
    e := e || jsonb_build_object('nextReview', 'Deve essere successiva all''ultima verifica.');
  end if;
  if m.format = 'scheda' then
    if not exists (select 1 from public.material_sections s
                   where s.env = p_env and s.material_id = p_mid and btrim(s.title) <> '' and char_length(btrim(s.body)) >= 20) then
      e := e || jsonb_build_object('sections', 'Aggiungi almeno una sezione con titolo e testo (20 caratteri).');
    end if;
  elsif m.file_path is null then
    e := e || jsonb_build_object('file', 'Carica il file PDF.');
  end if;
  return e;
end;
$$;

-- =========================================================
-- create_material(p_env, p_title, p_subject_id, p_topic_id, p_format) — nuova bozza
-- (materia e argomento servono subito: il database li richiede per ogni materiale)
-- =========================================================
create or replace function public.create_material(
  p_env public.env_t, p_title text, p_subject_id text, p_topic_id text, p_format public.material_fmt_t default 'scheda')
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id text := 'm' || substr(md5(random()::text || clock_timestamp()::text), 1, 8);
begin
  perform private.req_role(array['editor', 'admin']::public.role_t[]);
  if p_title is null or char_length(btrim(p_title)) < 4 or char_length(p_title) > 200 then
    raise exception 'Il titolo deve avere almeno 4 caratteri' using errcode = '22023';
  end if;
  if not exists (select 1 from public.topics t where t.env = p_env and t.id = p_topic_id and t.subject_id = p_subject_id) then
    raise exception 'Materia o argomento non validi' using errcode = '22023';
  end if;
  insert into public.materials (id, env, title, subject_id, topic_id, format, status, minutes, source, last_verified, next_review, author_id)
  values (v_id, p_env, btrim(p_title), p_subject_id, p_topic_id, p_format, 'draft', 5, '', current_date, current_date + 365, auth.uid());
  perform private.write_audit(p_env, v_id, 1, 'Materiale: creazione bozza');
  return jsonb_build_object('ok', true, 'id', v_id);
end;
$$;

-- =========================================================
-- update_material(p_env, p_mid, p_fields) — modifica di una bozza
-- Campi: title, subject_id, topic_id, format, minutes, source, key_concepts[], last_verified, next_review,
--        sections [{title, body}] (sostituisce tutte le sezioni), related [id] (sostituisce i collegamenti).
-- Un editor modifica solo le proprie bozze.
-- =========================================================
create or replace function public.update_material(p_env public.env_t, p_mid text, p_fields jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_role public.role_t;
  m public.materials%rowtype;
  v_subject text; v_topic text; v_format public.material_fmt_t; v_minutes smallint;
  v_keys text[]; v_lv date; v_nr date;
  v_sec jsonb; v_i int := 0;
begin
  v_role := private.req_role(array['editor', 'admin']::public.role_t[]);
  if p_fields is null or jsonb_typeof(p_fields) <> 'object' then raise exception 'Campi non validi' using errcode = '22023'; end if;
  if exists (select 1 from jsonb_object_keys(p_fields) k
             where k not in ('title', 'subject_id', 'topic_id', 'format', 'minutes', 'source', 'key_concepts',
                             'last_verified', 'next_review', 'sections', 'related')) then
    raise exception 'Campo non modificabile' using errcode = '22023';
  end if;
  select * into m from public.materials where env = p_env and id = p_mid for update;
  if not found then return jsonb_build_object('ok', false, 'error', 'not_found', 'why', 'Materiale non trovato.'); end if;
  if m.status <> 'draft' then
    return jsonb_build_object('ok', false, 'error', 'not_editable', 'why', 'Solo i materiali in bozza sono modificabili. Ritira il materiale per modificarlo.');
  end if;
  if v_role = 'editor' and m.author_id <> v_uid then
    return jsonb_build_object('ok', false, 'error', 'not_author', 'why', 'Puoi modificare solo le tue bozze.');
  end if;

  v_subject := coalesce(nullif(p_fields ->> 'subject_id', ''), m.subject_id);
  v_topic := coalesce(nullif(p_fields ->> 'topic_id', ''), m.topic_id);
  if p_fields ? 'subject_id' and not (p_fields ? 'topic_id')
     and not exists (select 1 from public.topics t where t.env = p_env and t.id = v_topic and t.subject_id = v_subject) then
    raise exception 'Cambiando materia indica anche l''argomento' using errcode = '22023';
  end if;
  if not exists (select 1 from public.topics t where t.env = p_env and t.id = v_topic and t.subject_id = v_subject) then
    raise exception 'Materia o argomento non validi' using errcode = '22023';
  end if;
  v_format := coalesce((p_fields ->> 'format')::public.material_fmt_t, m.format);
  v_minutes := coalesce(nullif(p_fields ->> 'minutes', '')::smallint, m.minutes);
  if v_minutes is not null and (v_minutes < 1 or v_minutes > 600) then raise exception 'Durata non valida' using errcode = '22023'; end if;
  v_keys := m.key_concepts;
  if p_fields ? 'key_concepts' then
    if jsonb_typeof(p_fields -> 'key_concepts') <> 'array' then raise exception 'Concetti chiave non validi' using errcode = '22023'; end if;
    v_keys := array(select btrim(k) from jsonb_array_elements_text(p_fields -> 'key_concepts') k where btrim(k) <> '');
  end if;
  v_lv := m.last_verified; v_nr := m.next_review;
  if p_fields ? 'last_verified' then v_lv := nullif(p_fields ->> 'last_verified', '')::date; end if;
  if p_fields ? 'next_review' then v_nr := nullif(p_fields ->> 'next_review', '')::date; end if;

  update public.materials set
    title = case when p_fields ? 'title' then btrim(coalesce(p_fields ->> 'title', '')) else title end,
    subject_id = v_subject, topic_id = v_topic, format = v_format, minutes = v_minutes,
    source = case when p_fields ? 'source' then btrim(coalesce(p_fields ->> 'source', '')) else source end,
    key_concepts = v_keys, last_verified = v_lv, next_review = v_nr
  where env = p_env and id = p_mid;

  if p_fields ? 'sections' then
    if jsonb_typeof(p_fields -> 'sections') <> 'array' then raise exception 'Sezioni non valide' using errcode = '22023'; end if;
    delete from public.material_sections where env = p_env and material_id = p_mid;
    for v_sec in select * from jsonb_array_elements(p_fields -> 'sections') loop
      v_i := v_i + 1;
      insert into public.material_sections (env, material_id, id, position, title, body)
      values (p_env, p_mid, p_mid || '-s' || v_i, v_i, btrim(coalesce(v_sec ->> 'title', '')), btrim(coalesce(v_sec ->> 'body', '')));
    end loop;
  end if;
  if p_fields ? 'related' then
    if jsonb_typeof(p_fields -> 'related') <> 'array' then raise exception 'Collegamenti non validi' using errcode = '22023'; end if;
    delete from public.material_related where env = p_env and material_id = p_mid;
    insert into public.material_related (env, material_id, related_id)
    select p_env, p_mid, r.id from (select distinct jsonb_array_elements_text(p_fields -> 'related') as id) r
    where r.id <> p_mid and exists (select 1 from public.materials x where x.env = p_env and x.id = r.id);
  end if;
  return jsonb_build_object('ok', true);
end;
$$;

-- =========================================================
-- set_material_file(p_env, p_mid, p_path) — collega il PDF già caricato nello storage a una bozza
-- =========================================================
create or replace function public.set_material_file(p_env public.env_t, p_mid text, p_path text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_role public.role_t;
  m public.materials%rowtype;
begin
  v_role := private.req_role(array['editor', 'admin']::public.role_t[]);
  if p_path is null or p_path !~ '^[A-Za-z0-9_./-]{1,200}$' or p_path like '%..%' or p_path like '/%' then
    raise exception 'Percorso del file non valido' using errcode = '22023';
  end if;
  select * into m from public.materials where env = p_env and id = p_mid for update;
  if not found then return jsonb_build_object('ok', false, 'error', 'not_found', 'why', 'Materiale non trovato.'); end if;
  if m.status <> 'draft' then return jsonb_build_object('ok', false, 'error', 'not_editable', 'why', 'Solo i materiali in bozza sono modificabili.'); end if;
  if v_role = 'editor' and m.author_id <> auth.uid() then
    return jsonb_build_object('ok', false, 'error', 'not_author', 'why', 'Puoi modificare solo le tue bozze.');
  end if;
  update public.materials set file_path = p_path where env = p_env and id = p_mid;
  perform private.write_audit(p_env, p_mid, 1, 'Materiale: file collegato');
  return jsonb_build_object('ok', true);
end;
$$;

-- =========================================================
-- material_transition(p_env, p_mid, p_action)
--   submit (editor/admin): bozza -> revisione, con controllo dei campi
--   approve (revisore/admin): revisione -> approvato (non sul proprio contenuto, salvo admin)
--   publish (revisore/admin): approvato -> pubblicato (ricontrolla i campi; i PDF richiedono il file)
--   unpublish (revisore/admin): pubblicato -> bozza
-- =========================================================
create or replace function public.material_transition(p_env public.env_t, p_mid text, p_action text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_role public.role_t;
  m public.materials%rowtype;
  v_errors jsonb;
  v_label text;
begin
  if p_action is null or p_action not in ('submit', 'approve', 'publish', 'unpublish') then
    raise exception 'Azione non valida' using errcode = '22023';
  end if;
  v_role := private.req_role(case when p_action = 'submit' then array['editor', 'admin'] else array['reviewer', 'admin'] end::public.role_t[]);
  select * into m from public.materials where env = p_env and id = p_mid for update;
  if not found then return jsonb_build_object('ok', false, 'error', 'not_found', 'why', 'Materiale non trovato.'); end if;

  if p_action = 'submit' and v_role = 'editor' and m.author_id <> v_uid then
    return jsonb_build_object('ok', false, 'error', 'not_author', 'why', 'Puoi inviare solo i tuoi materiali.');
  end if;
  if p_action = 'approve' and m.author_id = v_uid and v_role <> 'admin' then
    return jsonb_build_object('ok', false, 'error', 'self_review',
      'why', 'Non puoi revisionare o approvare un contenuto di cui sei autore. Solo un amministratore può farlo.');
  end if;
  if (p_action = 'submit' and m.status <> 'draft') or (p_action = 'approve' and m.status <> 'review')
     or (p_action = 'publish' and m.status <> 'approved') or (p_action = 'unpublish' and m.status <> 'published') then
    return jsonb_build_object('ok', false, 'error', 'invalid_state', 'why', 'Transizione non consentita dallo stato attuale.');
  end if;
  if p_action in ('submit', 'publish') then
    v_errors := private.validate_material(p_env, p_mid);
    if v_errors <> '{}'::jsonb then
      return jsonb_build_object('ok', false, 'error', 'validation', 'why', 'Completa i campi obbligatori del materiale.', 'errors', v_errors);
    end if;
  end if;

  if p_action = 'submit' then
    update public.materials set status = 'review' where env = p_env and id = p_mid; v_label := 'invio in revisione';
  elsif p_action = 'approve' then
    update public.materials set status = 'approved', reviewer_id = v_uid where env = p_env and id = p_mid; v_label := 'approvazione';
  elsif p_action = 'publish' then
    update public.materials set status = 'published' where env = p_env and id = p_mid; v_label := 'pubblicazione';
  else
    update public.materials set status = 'draft' where env = p_env and id = p_mid; v_label := 'ritiro dalla pubblicazione';
  end if;
  perform private.write_audit(p_env, p_mid, 1, 'Materiale: ' || v_label);
  return jsonb_build_object('ok', true, 'action', p_action);
end;
$$;

-- =========================================================
-- save_quiz(p_env, p_quiz) — crea o modifica un quiz in bozza (editor e amministratori)
-- p_quiz: {id?, title, mode, subject_ids?, topic_ids?, question_count, duration_min?}
-- =========================================================
create or replace function public.save_quiz(p_env public.env_t, p_quiz jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  z public.quizzes%rowtype;
  v_id text;
  v_title text; v_mode public.quiz_mode_t; v_count int; v_dur int;
  v_subjects text[]; v_topics text[];
  v_new boolean;
begin
  perform private.req_role(array['editor', 'admin']::public.role_t[]);
  if p_quiz is null or jsonb_typeof(p_quiz) <> 'object' then raise exception 'Dati non validi' using errcode = '22023'; end if;
  v_id := nullif(btrim(coalesce(p_quiz ->> 'id', '')), '');
  v_new := v_id is null;
  if not v_new then
    select * into z from public.quizzes where env = p_env and id = v_id for update;
    if not found then return jsonb_build_object('ok', false, 'error', 'not_found', 'why', 'Quiz non trovato.'); end if;
    if z.status = 'published' then
      return jsonb_build_object('ok', false, 'error', 'not_editable', 'why', 'Ritira il quiz dalla pubblicazione per modificarlo.');
    end if;
  end if;

  v_title := btrim(coalesce(p_quiz ->> 'title', z.title, ''));
  v_mode := coalesce(nullif(p_quiz ->> 'mode', '')::public.quiz_mode_t, z.mode);
  v_count := coalesce(nullif(p_quiz ->> 'question_count', '')::int, z.question_count);
  v_dur := case when p_quiz ? 'duration_min' then nullif(p_quiz ->> 'duration_min', '')::int else z.duration_min end;
  v_subjects := case when p_quiz ? 'subject_ids' and jsonb_typeof(p_quiz -> 'subject_ids') = 'array'
                     then array(select jsonb_array_elements_text(p_quiz -> 'subject_ids')) when p_quiz ? 'subject_ids' then null else z.subject_ids end;
  v_topics := case when p_quiz ? 'topic_ids' and jsonb_typeof(p_quiz -> 'topic_ids') = 'array'
                   then array(select jsonb_array_elements_text(p_quiz -> 'topic_ids')) when p_quiz ? 'topic_ids' then null else z.topic_ids end;

  if char_length(v_title) < 3 or char_length(v_title) > 120 then raise exception 'Titolo non valido (3-120 caratteri)' using errcode = '22023'; end if;
  if v_mode is null then raise exception 'Modalità mancante' using errcode = '22023'; end if;
  if v_count is null or v_count < 1 or v_count > 200 then raise exception 'Numero di domande non valido (1-200)' using errcode = '22023'; end if;
  if v_mode = 'exam' and (v_dur is null or v_dur < 1 or v_dur > 360) then raise exception 'Le simulazioni richiedono una durata (1-360 minuti)' using errcode = '22023'; end if;
  if v_mode = 'training' then v_dur := null; end if;
  if exists (select 1 from unnest(coalesce(v_subjects, array[]::text[])) s where not exists (select 1 from public.subjects x where x.env = p_env and x.id = s)) then
    raise exception 'Materia inesistente' using errcode = '22023';
  end if;
  if exists (select 1 from unnest(coalesce(v_topics, array[]::text[])) t where not exists (select 1 from public.topics x where x.env = p_env and x.id = t)) then
    raise exception 'Argomento inesistente' using errcode = '22023';
  end if;

  if v_new then
    v_id := 'z' || substr(md5(random()::text || clock_timestamp()::text), 1, 8);
    insert into public.quizzes (id, env, title, mode, subject_ids, topic_ids, question_count, duration_min, status)
    values (v_id, p_env, v_title, v_mode, v_subjects, v_topics, v_count, v_dur, 'draft');
  else
    update public.quizzes set title = v_title, mode = v_mode, subject_ids = v_subjects, topic_ids = v_topics,
      question_count = v_count, duration_min = v_dur, status = 'draft'
    where env = p_env and id = v_id;
  end if;
  perform private.write_audit(p_env, v_id, null, case when v_new then 'Quiz: creazione' else 'Quiz: modifica' end);
  return jsonb_build_object('ok', true, 'id', v_id);
end;
$$;

-- =========================================================
-- set_quiz_status(p_env, p_zid, p_status) — pubblica o ritira un quiz (revisori e amministratori)
-- La pubblicazione richiede gli stessi controlli di BL.quizChecks; se uno fallisce si riceve l'elenco in "failed".
-- =========================================================
create or replace function public.set_quiz_status(p_env public.env_t, p_zid text, p_status text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  z public.quizzes%rowtype;
  s public.editorial_settings%rowtype;
  v_live int; v_noexpl int; v_nosrc int;
  v_failed jsonb := '[]';
begin
  perform private.req_role(array['reviewer', 'admin']::public.role_t[]);
  if p_status not in ('published', 'draft') then raise exception 'Stato non valido' using errcode = '22023'; end if;
  select * into z from public.quizzes where env = p_env and id = p_zid for update;
  if not found then return jsonb_build_object('ok', false, 'error', 'not_found', 'why', 'Quiz non trovato.'); end if;

  if p_status = 'published' then
    select * into s from public.editorial_settings where env = p_env;
    if not found then s.require_url := true; s.require_explanation := true; end if;
    select count(*),
           count(*) filter (where btrim(qv.explanation) = ''),
           count(*) filter (where btrim(qv.source) = '' or (s.require_url and coalesce(qv.source_url, '') = ''))
      into v_live, v_noexpl, v_nosrc
    from public.questions q
    join public.question_versions qv on qv.env = q.env and qv.question_id = q.id and qv.v = q.current_version
    where q.env = p_env and qv.status = 'published' and not q.suspended and q.merged_into is null
      and (z.subject_ids is null or qv.subject_id = any (z.subject_ids))
      and (z.topic_ids is null or qv.topic_id = any (z.topic_ids));
    if v_live = 0 then v_failed := v_failed || to_jsonb('Domande approvate e pubblicate'::text); end if;
    if v_live < z.question_count then
      v_failed := v_failed || to_jsonb(('Numero di domande sufficiente: ' || v_live || ' disponibili su ' || z.question_count || ' richieste')::text);
    end if;
    if s.require_explanation and v_noexpl > 0 then v_failed := v_failed || to_jsonb('Spiegazioni disponibili'::text); end if;
    if v_nosrc > 0 then v_failed := v_failed || to_jsonb('Fonti compilate secondo la policy'::text); end if;
    if jsonb_array_length(v_failed) > 0 then
      return jsonb_build_object('ok', false, 'error', 'checks_failed', 'why', 'Il quiz non supera i controlli di pubblicazione.', 'failed', v_failed);
    end if;
  end if;

  update public.quizzes set status = p_status::public.content_status_t where env = p_env and id = p_zid;
  perform private.write_audit(p_env, p_zid, null, case when p_status = 'published' then 'Quiz: pubblicazione' else 'Quiz: ritiro dalla pubblicazione' end);
  return jsonb_build_object('ok', true);
end;
$$;

-- =========================================================
-- tax_edit(p_env, p_kind, p_id, p_patch) — catalogo (solo amministratori)
-- p_kind: areas | subjects | topics | professional_profiles | entities
-- p_id null = creazione. p_patch: name (obbligatorio alla creazione); topics: subject_id; entities: area_id;
-- professional_profiles: subject_ids[] e entity_ids[] (sostituiscono i collegamenti).
-- =========================================================
create or replace function public.tax_edit(p_env public.env_t, p_kind text, p_id text, p_patch jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id text := nullif(btrim(coalesce(p_id, '')), '');
  v_new boolean;
  v_name text;
  v_ref text;
  v_prefix text;
  v_exists boolean;
begin
  perform private.req_role(array['admin']::public.role_t[]);
  if p_kind not in ('areas', 'subjects', 'topics', 'professional_profiles', 'entities') then
    raise exception 'Tipo di voce non valido' using errcode = '22023';
  end if;
  if p_patch is null or jsonb_typeof(p_patch) <> 'object' then raise exception 'Dati non validi' using errcode = '22023'; end if;
  if exists (select 1 from jsonb_object_keys(p_patch) k where k not in ('name', 'subject_id', 'area_id', 'subject_ids', 'entity_ids')) then
    raise exception 'Campo non modificabile' using errcode = '22023';
  end if;
  v_new := v_id is null;
  v_name := nullif(btrim(coalesce(p_patch ->> 'name', '')), '');
  if v_name is not null and (char_length(v_name) < 2 or char_length(v_name) > 120) then
    raise exception 'Il nome deve avere da 2 a 120 caratteri' using errcode = '22023';
  end if;
  if v_new and v_name is null then raise exception 'Il nome è obbligatorio' using errcode = '22023'; end if;
  v_prefix := case p_kind when 'areas' then 'a-' when 'subjects' then 's-' when 'topics' then 't-' when 'professional_profiles' then 'p-' else 'e-' end;
  if v_new then
    v_id := v_prefix || substr(md5(random()::text || clock_timestamp()::text), 1, 6);
  else
    execute format('select exists (select 1 from public.%I where env = $1 and id = $2)', p_kind) into v_exists using p_env, v_id;
    if not v_exists then return jsonb_build_object('ok', false, 'error', 'not_found', 'why', 'Voce non trovata.'); end if;
  end if;

  if p_kind = 'areas' then
    if v_new then insert into public.areas (id, env, name) values (v_id, p_env, v_name);
    else update public.areas set name = coalesce(v_name, name) where env = p_env and id = v_id; end if;

  elsif p_kind = 'subjects' then
    if v_new then insert into public.subjects (id, env, name) values (v_id, p_env, v_name);
    else update public.subjects set name = coalesce(v_name, name) where env = p_env and id = v_id; end if;

  elsif p_kind = 'topics' then
    v_ref := nullif(p_patch ->> 'subject_id', '');
    if v_ref is not null and not exists (select 1 from public.subjects s where s.env = p_env and s.id = v_ref) then
      raise exception 'Materia inesistente' using errcode = '22023';
    end if;
    if v_new then
      if v_ref is null then raise exception 'La materia è obbligatoria' using errcode = '22023'; end if;
      insert into public.topics (id, env, name, subject_id) values (v_id, p_env, v_name, v_ref);
    else
      update public.topics set name = coalesce(v_name, name), subject_id = coalesce(v_ref, subject_id) where env = p_env and id = v_id;
    end if;

  elsif p_kind = 'entities' then
    v_ref := nullif(p_patch ->> 'area_id', '');
    if v_ref is not null and not exists (select 1 from public.areas a where a.env = p_env and a.id = v_ref) then
      raise exception 'Area inesistente' using errcode = '22023';
    end if;
    if v_new then
      if v_ref is null then raise exception 'L''area è obbligatoria' using errcode = '22023'; end if;
      insert into public.entities (id, env, name, area_id) values (v_id, p_env, v_name, v_ref);
    else
      update public.entities set name = coalesce(v_name, name), area_id = coalesce(v_ref, area_id) where env = p_env and id = v_id;
    end if;

  else
    if v_new then insert into public.professional_profiles (id, env, name) values (v_id, p_env, v_name);
    else update public.professional_profiles set name = coalesce(v_name, name) where env = p_env and id = v_id; end if;
    if p_patch ? 'subject_ids' then
      delete from public.profile_subjects where env = p_env and profile_id = v_id;
      insert into public.profile_subjects (env, profile_id, subject_id)
      select p_env, v_id, s.id from (select distinct jsonb_array_elements_text(p_patch -> 'subject_ids') as id) s
      where exists (select 1 from public.subjects x where x.env = p_env and x.id = s.id);
    end if;
    if p_patch ? 'entity_ids' then
      delete from public.profile_entities where env = p_env and profile_id = v_id;
      insert into public.profile_entities (env, profile_id, entity_id)
      select p_env, v_id, s.id from (select distinct jsonb_array_elements_text(p_patch -> 'entity_ids') as id) s
      where exists (select 1 from public.entities x where x.env = p_env and x.id = s.id);
    end if;
  end if;

  perform private.write_audit(p_env, v_id, null, 'Catalogo: ' || coalesce('«' || v_name || '»', 'modifica'), p_kind);
  return jsonb_build_object('ok', true, 'id', v_id);
end;
$$;

-- =========================================================
-- set_role(p_uid, p_role) — assegna il ruolo (solo amministratori)
-- Non si può togliere il ruolo all'ultimo amministratore.
-- =========================================================
create or replace function public.set_role(p_uid uuid, p_role public.role_t)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_old public.role_t;
begin
  perform private.req_role(array['admin']::public.role_t[]);
  select role into v_old from public.profiles_user where id = p_uid for update;
  if not found then return jsonb_build_object('ok', false, 'error', 'not_found', 'why', 'Utente non trovato.'); end if;
  if v_old = 'admin' and p_role <> 'admin' and (select count(*) from public.profiles_user where role = 'admin') <= 1 then
    return jsonb_build_object('ok', false, 'error', 'last_admin', 'why', 'Non puoi rimuovere il ruolo dall''unico amministratore.');
  end if;
  update public.profiles_user set role = p_role where id = p_uid;
  perform private.write_audit('real', p_uid::text, null, 'Ruolo modificato: ' || v_old || ' → ' || p_role);
  return jsonb_build_object('ok', true);
end;
$$;

-- =========================================================
-- PERMESSI
-- =========================================================
revoke all on function private.validate_material(public.env_t, text)                          from public, anon, authenticated;

revoke all on function public.create_material(public.env_t, text, text, text, public.material_fmt_t) from public, anon;
revoke all on function public.update_material(public.env_t, text, jsonb)                      from public, anon;
revoke all on function public.set_material_file(public.env_t, text, text)                     from public, anon;
revoke all on function public.material_transition(public.env_t, text, text)                   from public, anon;
revoke all on function public.save_quiz(public.env_t, jsonb)                                  from public, anon;
revoke all on function public.set_quiz_status(public.env_t, text, text)                       from public, anon;
revoke all on function public.tax_edit(public.env_t, text, text, jsonb)                       from public, anon;
revoke all on function public.set_role(uuid, public.role_t)                                   from public, anon;

grant execute on function public.create_material(public.env_t, text, text, text, public.material_fmt_t) to authenticated;
grant execute on function public.update_material(public.env_t, text, jsonb)                   to authenticated;
grant execute on function public.set_material_file(public.env_t, text, text)                  to authenticated;
grant execute on function public.material_transition(public.env_t, text, text)                to authenticated;
grant execute on function public.save_quiz(public.env_t, jsonb)                               to authenticated;
grant execute on function public.set_quiz_status(public.env_t, text, text)                    to authenticated;
grant execute on function public.tax_edit(public.env_t, text, text, jsonb)                    to authenticated;
grant execute on function public.set_role(uuid, public.role_t)                                to authenticated;
