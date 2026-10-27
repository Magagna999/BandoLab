-- BandoLab — patch 11: funzioni RPC editoriali per domande, segnalazioni, duplicati e importazione
-- Da eseguire dopo patch-10.
--
-- Sostituiscono nel core: BL.createQuestion, BL.updateDraft, BL.transition, BL.updateReport,
-- BL.decideDuplicate e aggiungono import_questions (caricamento in blocco, solo amministratori).
-- I permessi replicano BL.PERMS: editor = scrive e invia; revisore = approva, pubblica, sospende, verifica;
-- amministratore = tutto. Le regole sono applicate dal server, non dal client.
--
-- Convenzioni come patch-07: security definer, search_path fisso, solo utenti autenticati.
--   * ruolo non ammesso -> eccezione 42501; utente non autenticato -> 28000; dati non validi -> 22023;
--   * condizioni previste -> {"ok": false, "error": "<codice>", "why": "<messaggio>"}.
-- Ogni operazione che modifica contenuti scrive una riga in audit_log.
-- Differenza rispetto al core: un editor può modificare solo le proprie bozze (il core permetteva a qualsiasi editor).
-- STATO: APPLICATA al database il 27/10/2026 (migrazione patch_11_rpc_questions), verificata con rpc-editorial.test.sql.

-- =========================================================
-- FUNZIONI DI SUPPORTO (schema private, non chiamabili dall'API)
-- =========================================================

-- Verifica accesso e ruolo; ritorna il ruolo dell'utente.
create or replace function private.req_role(p_roles public.role_t[])
returns public.role_t
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_role public.role_t;
begin
  if auth.uid() is null then
    raise exception 'Accesso richiesto' using errcode = '28000';
  end if;
  select role into v_role from public.profiles_user where id = auth.uid();
  if v_role is null or not (v_role = any (p_roles)) then
    raise exception 'Operazione non autorizzata per il ruolo' using errcode = '42501';
  end if;
  return v_role;
end;
$$;

create or replace function private.write_audit(
  p_env public.env_t, p_target text, p_version int, p_action text, p_note text default null)
returns void
language sql
security definer
set search_path = public
as $$
  insert into public.audit_log (env, actor_id, target, version, action, note)
  values (p_env, auth.uid(), p_target, p_version, p_action, nullif(btrim(coalesce(p_note, '')), ''));
$$;

-- Controlli di completezza di una domanda (stessi di BL.validate); ritorna {campo: messaggio}.
create or replace function private.validate_question_fields(
  p_env public.env_t, p_subject text, p_topic text, p_text text, p_options text[], p_correct int,
  p_explanation text, p_difficulty int, p_source text, p_source_url text, p_last_verified date, p_next_review date)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  e jsonb := '{}';
  s public.editorial_settings%rowtype;
  v_filled int;
begin
  select * into s from public.editorial_settings where env = p_env;
  if not found then s.require_url := true; s.require_explanation := true; end if;

  if p_text is null or char_length(btrim(p_text)) < 10 then
    e := e || jsonb_build_object('text', 'Inserisci il testo della domanda (almeno 10 caratteri).');
  end if;
  select count(*) into v_filled from unnest(coalesce(p_options, array[]::text[])) o where btrim(coalesce(o, '')) <> '';
  if coalesce(array_length(p_options, 1), 0) <> 4 or v_filled < 4 then
    e := e || jsonb_build_object('options', 'Compila tutte e quattro le opzioni di risposta.');
  end if;
  if p_correct is null or p_correct not between 0 and 3
     or btrim(coalesce(p_options[p_correct + 1], '')) = '' then
    e := e || jsonb_build_object('correct', 'Indica la risposta corretta tra le opzioni compilate.');
  end if;
  if s.require_explanation and (p_explanation is null or char_length(btrim(p_explanation)) < 10) then
    e := e || jsonb_build_object('explanation', 'La spiegazione è obbligatoria secondo la policy editoriale.');
  end if;
  if p_subject is null then e := e || jsonb_build_object('subject', 'Seleziona la materia.'); end if;
  if p_topic is null then
    e := e || jsonb_build_object('topic', 'Seleziona l''argomento.');
  elsif p_subject is not null and not exists (
      select 1 from public.topics t where t.env = p_env and t.id = p_topic and t.subject_id = p_subject) then
    e := e || jsonb_build_object('topic', 'L''argomento non appartiene alla materia.');
  end if;
  if p_difficulty is null then e := e || jsonb_build_object('difficulty', 'Assegna manualmente la difficoltà.'); end if;
  if p_source is null or btrim(p_source) = '' then e := e || jsonb_build_object('source', 'Indica la fonte ufficiale o documentale.'); end if;
  if s.require_url and coalesce(p_source_url, '') !~ '^https?://' then
    e := e || jsonb_build_object('sourceUrl', 'Inserisci l''URL della fonte (http/https).');
  end if;
  if p_last_verified is null then e := e || jsonb_build_object('lastVerified', 'Indica la data dell''ultima verifica.'); end if;
  if p_next_review is null then
    e := e || jsonb_build_object('nextReview', 'Indica la data della prossima revisione.');
  elsif p_last_verified is not null and p_next_review <= p_last_verified then
    e := e || jsonb_build_object('nextReview', 'La prossima revisione deve essere successiva all''ultima verifica.');
  end if;
  return e;
end;
$$;

-- =========================================================
-- create_question(p_env) — nuova bozza vuota
-- =========================================================
create or replace function public.create_question(p_env public.env_t)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id text := 'q' || substr(md5(random()::text || clock_timestamp()::text), 1, 8);
begin
  perform private.req_role(array['editor', 'admin']::public.role_t[]);
  insert into public.questions (id, env) values (v_id, p_env);
  insert into public.question_versions (env, question_id, v, status, author_id)
  values (p_env, v_id, 1, 'draft', auth.uid());
  perform private.write_audit(p_env, v_id, 1, 'Creazione bozza');
  return jsonb_build_object('ok', true, 'id', v_id);
end;
$$;

-- =========================================================
-- update_draft(p_env, p_qid, p_fields) — modifica di una bozza o di un contenuto con modifiche richieste
-- Campi ammessi: text, options[4], correct, explanation, subject_id, topic_id, difficulty, source,
-- source_url, last_verified, next_review. Gli altri sono rifiutati.
-- =========================================================
create or replace function public.update_draft(p_env public.env_t, p_qid text, p_fields jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_role public.role_t;
  w public.question_versions%rowtype;
  v_opts text[]; v_subject text; v_topic text; v_corr smallint; v_diff smallint;
  v_lv date; v_nr date;
begin
  v_role := private.req_role(array['editor', 'admin']::public.role_t[]);
  if p_fields is null or jsonb_typeof(p_fields) <> 'object' then
    raise exception 'Campi non validi' using errcode = '22023';
  end if;
  if exists (select 1 from jsonb_object_keys(p_fields) k
             where k not in ('text', 'options', 'correct', 'explanation', 'subject_id', 'topic_id', 'difficulty',
                             'source', 'source_url', 'last_verified', 'next_review')) then
    raise exception 'Campo non modificabile' using errcode = '22023';
  end if;

  select * into w from public.question_versions
  where env = p_env and question_id = p_qid order by v desc limit 1 for update;
  if not found then return jsonb_build_object('ok', false, 'error', 'not_found', 'why', 'Domanda non trovata.'); end if;
  if w.status not in ('draft', 'changes') then
    return jsonb_build_object('ok', false, 'error', 'not_editable',
      'why', 'Solo le bozze o i contenuti con modifiche richieste sono modificabili.');
  end if;
  if v_role = 'editor' and w.author_id <> v_uid then
    return jsonb_build_object('ok', false, 'error', 'not_author', 'why', 'Puoi modificare solo le tue bozze.');
  end if;

  v_opts := w.options;
  if p_fields ? 'options' then
    if jsonb_typeof(p_fields -> 'options') <> 'array' or jsonb_array_length(p_fields -> 'options') <> 4 then
      raise exception 'Servono esattamente quattro opzioni' using errcode = '22023';
    end if;
    v_opts := array(select btrim(o) from jsonb_array_elements_text(p_fields -> 'options') o);
  end if;
  v_corr := w.correct;
  if p_fields ? 'correct' then
    v_corr := nullif(p_fields ->> 'correct', '')::smallint;
    if v_corr is not null and v_corr not between 0 and 3 then raise exception 'Risposta corretta non valida' using errcode = '22023'; end if;
  end if;
  v_diff := w.difficulty;
  if p_fields ? 'difficulty' then
    v_diff := nullif(p_fields ->> 'difficulty', '')::smallint;
    if v_diff is not null and v_diff not between 1 and 3 then raise exception 'Difficoltà non valida' using errcode = '22023'; end if;
  end if;
  v_lv := w.last_verified; v_nr := w.next_review;
  if p_fields ? 'last_verified' then v_lv := nullif(p_fields ->> 'last_verified', '')::date; end if;
  if p_fields ? 'next_review' then v_nr := nullif(p_fields ->> 'next_review', '')::date; end if;

  v_subject := case when p_fields ? 'subject_id' then nullif(p_fields ->> 'subject_id', '') else w.subject_id end;
  v_topic   := case when p_fields ? 'topic_id'   then nullif(p_fields ->> 'topic_id', '')   else w.topic_id end;
  if v_subject is not null and not exists (select 1 from public.subjects s where s.env = p_env and s.id = v_subject) then
    raise exception 'Materia inesistente' using errcode = '22023';
  end if;
  if v_topic is not null and not exists (select 1 from public.topics t where t.env = p_env and t.id = v_topic) then
    raise exception 'Argomento inesistente' using errcode = '22023';
  end if;
  -- cambiando materia senza indicare l'argomento, quello vecchio non è più valido
  if p_fields ? 'subject_id' and not (p_fields ? 'topic_id') and v_topic is not null
     and not exists (select 1 from public.topics t where t.env = p_env and t.id = v_topic and t.subject_id = v_subject) then
    v_topic := null;
  end if;
  if v_subject is not null and v_topic is not null
     and not exists (select 1 from public.topics t where t.env = p_env and t.id = v_topic and t.subject_id = v_subject) then
    raise exception 'L''argomento non appartiene alla materia' using errcode = '22023';
  end if;

  update public.question_versions set
    text = case when p_fields ? 'text' then coalesce(p_fields ->> 'text', '') else text end,
    options = v_opts, correct = v_corr, difficulty = v_diff,
    explanation = case when p_fields ? 'explanation' then coalesce(p_fields ->> 'explanation', '') else explanation end,
    subject_id = v_subject, topic_id = v_topic,
    source = case when p_fields ? 'source' then coalesce(p_fields ->> 'source', '') else source end,
    source_url = case when p_fields ? 'source_url' then nullif(btrim(coalesce(p_fields ->> 'source_url', '')), '') else source_url end,
    last_verified = v_lv, next_review = v_nr
  where env = p_env and question_id = p_qid and v = w.v;
  return jsonb_build_object('ok', true, 'v', w.v);
end;
$$;

-- =========================================================
-- transition(p_env, p_qid, p_action, p_note) — flusso editoriale
--   submit      editor/admin  bozza o modifiche richieste -> revisione (controlla i campi obbligatori)
--   approve     revisore/admin  revisione -> approvata (non sul proprio contenuto, salvo admin)
--   changes     revisore/admin  revisione -> modifiche richieste (nota obbligatoria)
--   reject      revisore/admin  revisione -> rifiutata
--   publish     revisore/admin  approvata -> pubblicata; la versione precedente diventa "superseded"
--   newVersion  editor/admin  da una versione pubblicata crea la bozza della successiva
--   suspend / unsuspend  revisore/admin  esclude dai nuovi quiz (motivo obbligatorio)
--   verify      revisore/admin  aggiorna ultima verifica e prossima revisione
--   reopen      editor/admin  rifiutata -> bozza
-- =========================================================
create or replace function public.transition(p_env public.env_t, p_qid text, p_action text, p_note text default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_role public.role_t;
  w public.question_versions%rowtype;
  q public.questions%rowtype;
  v_errors jsonb;
  v_note text := nullif(btrim(coalesce(p_note, '')), '');
  v_label text;
  v_audit_v int;
  v_months int;
  v_new int;
begin
  if p_action is null or p_action not in ('submit', 'approve', 'changes', 'reject', 'publish', 'newVersion',
                                          'suspend', 'unsuspend', 'verify', 'reopen') then
    raise exception 'Azione non valida' using errcode = '22023';
  end if;
  v_role := private.req_role(
    case when p_action in ('submit', 'newVersion', 'reopen') then array['editor', 'admin']
         when p_action in ('approve', 'changes', 'reject', 'publish', 'suspend', 'unsuspend', 'verify') then array['reviewer', 'admin']
         else array[]::text[] end::public.role_t[]);

  select * into q from public.questions where env = p_env and id = p_qid for update;
  if not found then return jsonb_build_object('ok', false, 'error', 'not_found', 'why', 'Domanda non trovata.'); end if;
  select * into w from public.question_versions
  where env = p_env and question_id = p_qid order by v desc limit 1 for update;
  v_audit_v := w.v;

  if p_action in ('submit', 'reopen') and v_role = 'editor' and w.author_id <> v_uid then
    return jsonb_build_object('ok', false, 'error', 'not_author', 'why', 'Puoi gestire solo i tuoi contenuti.');
  end if;
  if p_action in ('approve', 'changes', 'reject') and w.author_id = v_uid and v_role <> 'admin' then
    return jsonb_build_object('ok', false, 'error', 'self_review',
      'why', 'Non puoi revisionare o approvare un contenuto di cui sei autore. Solo un amministratore può farlo.');
  end if;

  if p_action = 'submit' then
    v_label := 'Invio in revisione';
    if w.status not in ('draft', 'changes') then
      return jsonb_build_object('ok', false, 'error', 'invalid_state', 'why', 'Solo una bozza può essere inviata in revisione.');
    end if;
    v_errors := private.validate_question_fields(p_env, w.subject_id, w.topic_id, w.text, w.options, w.correct,
      w.explanation, w.difficulty, w.source, w.source_url, w.last_verified, w.next_review);
    if v_errors <> '{}'::jsonb then
      return jsonb_build_object('ok', false, 'error', 'validation', 'why', 'Completa i campi obbligatori.', 'errors', v_errors);
    end if;
    update public.question_versions set status = 'review', review_note = null
    where env = p_env and question_id = p_qid and v = w.v;

  elsif p_action = 'approve' then
    v_label := 'Approvazione';
    if w.status <> 'review' then return jsonb_build_object('ok', false, 'error', 'invalid_state', 'why', 'Il contenuto non è in revisione.'); end if;
    update public.question_versions set status = 'approved', reviewer_id = v_uid, approved_at = now()
    where env = p_env and question_id = p_qid and v = w.v;

  elsif p_action = 'changes' then
    v_label := 'Modifiche richieste';
    if w.status <> 'review' then return jsonb_build_object('ok', false, 'error', 'invalid_state', 'why', 'Il contenuto non è in revisione.'); end if;
    if v_note is null then return jsonb_build_object('ok', false, 'error', 'note_required', 'why', 'Specifica le modifiche richieste.'); end if;
    update public.question_versions set status = 'changes', reviewer_id = v_uid, review_note = v_note
    where env = p_env and question_id = p_qid and v = w.v;

  elsif p_action = 'reject' then
    v_label := 'Rifiuto';
    if w.status <> 'review' then return jsonb_build_object('ok', false, 'error', 'invalid_state', 'why', 'Il contenuto non è in revisione.'); end if;
    update public.question_versions set status = 'rejected', reviewer_id = v_uid, review_note = coalesce(v_note, '')
    where env = p_env and question_id = p_qid and v = w.v;

  elsif p_action = 'reopen' then
    v_label := 'Riapertura come bozza';
    if w.status <> 'rejected' then return jsonb_build_object('ok', false, 'error', 'invalid_state', 'why', 'Solo un contenuto rifiutato può essere riaperto.'); end if;
    update public.question_versions set status = 'draft' where env = p_env and question_id = p_qid and v = w.v;

  elsif p_action = 'publish' then
    v_label := 'Pubblicazione';
    if w.status <> 'approved' then return jsonb_build_object('ok', false, 'error', 'invalid_state', 'why', 'Si possono pubblicare soltanto contenuti approvati.'); end if;
    if q.current_version is not null and q.current_version <> w.v then
      update public.question_versions set status = 'superseded'
      where env = p_env and question_id = p_qid and v = q.current_version;
    end if;
    update public.question_versions set status = 'published', published_at = now()
    where env = p_env and question_id = p_qid and v = w.v;
    update public.questions set current_version = w.v where env = p_env and id = p_qid;

  elsif p_action = 'newVersion' then
    v_label := 'Nuova versione in bozza';
    if w.status <> 'published' then return jsonb_build_object('ok', false, 'error', 'invalid_state', 'why', 'Esiste già una versione in lavorazione.'); end if;
    v_new := w.v + 1;
    insert into public.question_versions (env, question_id, v, status, text, options, correct, explanation, subject_id,
        topic_id, difficulty, source, source_url, last_verified, next_review, author_id, change_note)
    values (p_env, p_qid, v_new, 'draft', w.text, w.options, w.correct, w.explanation, w.subject_id,
        w.topic_id, w.difficulty, w.source, w.source_url, w.last_verified, w.next_review, v_uid,
        coalesce(v_note, 'Modifica della versione pubblicata'));
    v_audit_v := v_new;

  elsif p_action = 'suspend' then
    v_label := 'Sospensione dai nuovi quiz';
    if v_note is null then return jsonb_build_object('ok', false, 'error', 'note_required', 'why', 'Indica il motivo della sospensione.'); end if;
    update public.questions set suspended = true, suspend_note = v_note where env = p_env and id = p_qid;

  elsif p_action = 'unsuspend' then
    v_label := 'Revoca della sospensione';
    update public.questions set suspended = false, suspend_note = null where env = p_env and id = p_qid;

  elsif p_action = 'verify' then
    v_label := 'Verifica normativa completata';
    if q.current_version is null then
      return jsonb_build_object('ok', false, 'error', 'no_live', 'why', 'Nessuna versione pubblicata da verificare.');
    end if;
    select round(verify_months * 30.4)::int into v_months from public.editorial_settings where env = p_env;
    update public.question_versions
      set last_verified = current_date, next_review = current_date + coalesce(v_months, 365)
    where env = p_env and question_id = p_qid and v = q.current_version;
    v_audit_v := q.current_version;

  end if;

  perform private.write_audit(p_env, p_qid, v_audit_v, v_label, v_note);
  return jsonb_build_object('ok', true, 'action', p_action, 'v', v_audit_v);
end;
$$;

-- =========================================================
-- update_report(p_id, p_patch) — gestione delle segnalazioni (revisori e amministratori)
-- Campi: status (open | resolved | dismissed), priority (alta | media | bassa), assignee_id (revisore/admin o null).
-- Alla chiusura il segnalante riceve una notifica (se non l'ha disattivata).
-- =========================================================
create or replace function public.update_report(p_id uuid, p_patch jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  r public.reports%rowtype;
  v_status public.report_status_t;
  v_prio public.priority_t;
  v_assignee uuid;
  v_label text := '';
  v_notify boolean;
begin
  perform private.req_role(array['reviewer', 'admin']::public.role_t[]);
  if p_patch is null or jsonb_typeof(p_patch) <> 'object' then raise exception 'Dati non validi' using errcode = '22023'; end if;
  if exists (select 1 from jsonb_object_keys(p_patch) k where k not in ('status', 'priority', 'assignee_id')) then
    raise exception 'Campo non modificabile' using errcode = '22023';
  end if;
  select * into r from public.reports where id = p_id for update;
  if not found then return jsonb_build_object('ok', false, 'error', 'not_found', 'why', 'Segnalazione non trovata.'); end if;

  v_status := r.status; v_prio := r.priority; v_assignee := r.assignee_id;
  if p_patch ? 'status' then v_status := (p_patch ->> 'status')::public.report_status_t; v_label := v_label || 'stato ' || v_status || '; '; end if;
  if p_patch ? 'priority' then v_prio := (p_patch ->> 'priority')::public.priority_t; v_label := v_label || 'priorità ' || v_prio || '; '; end if;
  if p_patch ? 'assignee_id' then
    v_assignee := nullif(p_patch ->> 'assignee_id', '')::uuid;
    if v_assignee is not null and not exists (
        select 1 from public.profiles_user u where u.id = v_assignee and u.role in ('reviewer', 'admin')) then
      raise exception 'L''assegnatario deve essere un revisore o un amministratore' using errcode = '22023';
    end if;
    v_label := v_label || 'assegnazione; ';
  end if;

  update public.reports set status = v_status, priority = v_prio, assignee_id = v_assignee where id = p_id;
  perform private.write_audit(r.env, r.question_id, r.version, 'Segnalazione: ' || rtrim(v_label, '; '), p_id::text);

  if v_status in ('resolved', 'dismissed') and r.status = 'open' and r.reporter_id is not null then
    select coalesce((select up.notif_content from public.user_prefs up where up.user_id = r.reporter_id and up.env = r.env), true)
      into v_notify;
    if v_notify then
      insert into public.notifications (user_id, env, type, title, body)
      values (r.reporter_id, r.env, 'content', 'Segnalazione gestita', 'Il team editoriale ha gestito la tua segnalazione.');
    end if;
  end if;
  return jsonb_build_object('ok', true);
end;
$$;

-- =========================================================
-- decide_duplicate(p_env, p_a, p_b, p_decision, p_note) — revisori e amministratori
-- keep = mantieni entrambe; merge = la domanda b confluisce nella a (mai eliminata: merged_into).
-- Con merge i profili professionali di b passano ad a.
-- =========================================================
create or replace function public.decide_duplicate(
  p_env public.env_t, p_a text, p_b text, p_decision text, p_note text default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  qa public.questions%rowtype;
  qb public.questions%rowtype;
begin
  perform private.req_role(array['reviewer', 'admin']::public.role_t[]);
  if p_decision not in ('keep', 'merge') then raise exception 'Decisione non valida' using errcode = '22023'; end if;
  if p_a is null or p_b is null or p_a = p_b then raise exception 'Servono due domande diverse' using errcode = '22023'; end if;
  select * into qa from public.questions where env = p_env and id = p_a for update;
  if not found then return jsonb_build_object('ok', false, 'error', 'not_found', 'why', 'Domanda non trovata: ' || p_a); end if;
  select * into qb from public.questions where env = p_env and id = p_b for update;
  if not found then return jsonb_build_object('ok', false, 'error', 'not_found', 'why', 'Domanda non trovata: ' || p_b); end if;

  if p_decision = 'merge' then
    if qa.merged_into is not null or qb.merged_into is not null then
      return jsonb_build_object('ok', false, 'error', 'already_merged', 'why', 'Una delle due domande è già stata consolidata.');
    end if;
    update public.questions set merged_into = p_a where env = p_env and id = p_b;
    insert into public.question_profiles (env, question_id, profile_id)
    select env, p_a, profile_id from public.question_profiles where env = p_env and question_id = p_b
    on conflict do nothing;
  end if;

  insert into public.duplicate_decisions (env, question_a, question_b, decision, actor_id, note)
  values (p_env, p_a, p_b, p_decision, auth.uid(), nullif(btrim(coalesce(p_note, '')), ''))
  on conflict (env, question_a, question_b) do update
    set decision = excluded.decision, actor_id = excluded.actor_id, note = excluded.note, at = now();
  perform private.write_audit(p_env, p_a, null,
    case when p_decision = 'merge' then 'Consolidamento: ' || p_b || ' confluita in ' || p_a
         else 'Duplicato: mantenute entrambe (' || p_a || ', ' || p_b || ')' end, p_note);
  return jsonb_build_object('ok', true);
end;
$$;

-- =========================================================
-- import_questions(p_env, p_rows, p_status) — caricamento in blocco (solo amministratori)
-- p_rows: array di {id?, text, options[4], correct 0-3, explanation, subject_id, topic_id, difficulty 1-3,
--                  source, source_url?, last_verified, next_review}
-- p_status: draft | review | published (con published l'amministratore è anche revisore: consentito).
-- Tutto o niente: se anche una riga non è valida non viene inserito nulla e si ricevono gli errori per riga.
-- Gli id già presenti vengono saltati (ripetibile). Massimo 500 righe.
-- =========================================================
create or replace function public.import_questions(p_env public.env_t, p_rows jsonb, p_status text default 'draft')
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_row jsonb;
  v_i int := 0;
  v_errs jsonb := '[]';
  v_bad int := 0;
  v_e jsonb;
  v_id text;
  v_opts text[];
  v_corr int; v_diff int;
  v_lv date; v_nr date;
  v_inserted int := 0;
  v_skipped int := 0;
  v_ids text[] := array[]::text[];
begin
  perform private.req_role(array['admin']::public.role_t[]);
  if p_status not in ('draft', 'review', 'published') then raise exception 'Stato non valido' using errcode = '22023'; end if;
  if p_rows is null or jsonb_typeof(p_rows) <> 'array' or jsonb_array_length(p_rows) = 0 then
    raise exception 'Nessuna riga da importare' using errcode = '22023';
  end if;
  if jsonb_array_length(p_rows) > 500 then raise exception 'Massimo 500 righe per importazione' using errcode = '22023'; end if;

  -- 1) controllo di tutte le righe
  for v_row in select * from jsonb_array_elements(p_rows) loop
    v_i := v_i + 1;
    v_e := '{}';
    begin
      v_opts := case when jsonb_typeof(v_row -> 'options') = 'array'
                     then array(select btrim(o) from jsonb_array_elements_text(v_row -> 'options') o) else null end;
      v_corr := nullif(v_row ->> 'correct', '')::int;
      v_diff := nullif(v_row ->> 'difficulty', '')::int;
      v_lv := nullif(v_row ->> 'last_verified', '')::date;
      v_nr := nullif(v_row ->> 'next_review', '')::date;
      v_e := private.validate_question_fields(p_env, nullif(v_row ->> 'subject_id', ''), nullif(v_row ->> 'topic_id', ''),
        v_row ->> 'text', v_opts, v_corr, v_row ->> 'explanation', v_diff, v_row ->> 'source', v_row ->> 'source_url', v_lv, v_nr);
      if v_diff is not null and v_diff not between 1 and 3 then v_e := v_e || jsonb_build_object('difficulty', 'La difficoltà deve essere 1, 2 o 3.'); end if;
      if nullif(v_row ->> 'subject_id', '') is not null and not exists (
          select 1 from public.subjects s where s.env = p_env and s.id = v_row ->> 'subject_id') then
        v_e := v_e || jsonb_build_object('subject', 'Materia inesistente.');
      end if;
      v_id := nullif(btrim(coalesce(v_row ->> 'id', '')), '');
      if v_id is not null and v_id !~ '^[A-Za-z0-9_-]{1,40}$' then v_e := v_e || jsonb_build_object('id', 'ID non valido (lettere, numeri, - e _).'); end if;
      if v_id is not null and v_id = any (v_ids) then v_e := v_e || jsonb_build_object('id', 'ID ripetuto nel file.'); end if;
      if v_id is not null then v_ids := v_ids || v_id; end if;
    exception when others then
      v_e := v_e || jsonb_build_object('row', 'Riga non leggibile: ' || sqlerrm);
    end;
    if v_e <> '{}'::jsonb then
      v_bad := v_bad + 1;
      if v_bad <= 50 then   -- si elencano le prime 50 righe errate
        v_errs := v_errs || jsonb_build_array(jsonb_build_object('row', v_i, 'errors', v_e));
      end if;
    end if;
  end loop;
  if v_bad > 0 then
    return jsonb_build_object('ok', false, 'error', 'validation', 'bad_rows', v_bad,
      'why', 'Correggi le righe indicate: nulla è stato importato.', 'rows', v_errs);
  end if;

  -- 2) inserimento
  v_i := 0;
  for v_row in select * from jsonb_array_elements(p_rows) loop
    v_i := v_i + 1;
    v_id := coalesce(nullif(btrim(coalesce(v_row ->> 'id', '')), ''), 'r' || substr(md5(random()::text || clock_timestamp()::text || v_i), 1, 8));
    if exists (select 1 from public.questions where env = p_env and id = v_id) then
      v_skipped := v_skipped + 1;
      continue;
    end if;
    insert into public.questions (id, env) values (v_id, p_env);
    insert into public.question_versions (env, question_id, v, status, text, options, correct, explanation, subject_id, topic_id,
        difficulty, source, source_url, last_verified, next_review, author_id, reviewer_id, approved_at, published_at)
    values (p_env, v_id, 1, p_status::public.content_status_t, btrim(v_row ->> 'text'),
        array(select btrim(o) from jsonb_array_elements_text(v_row -> 'options') o),
        (v_row ->> 'correct')::smallint, btrim(coalesce(v_row ->> 'explanation', '')),
        v_row ->> 'subject_id', v_row ->> 'topic_id', (v_row ->> 'difficulty')::smallint,
        btrim(v_row ->> 'source'), nullif(btrim(coalesce(v_row ->> 'source_url', '')), ''),
        (v_row ->> 'last_verified')::date, (v_row ->> 'next_review')::date, v_uid,
        case when p_status = 'published' then v_uid end,
        case when p_status = 'published' then now() end,
        case when p_status = 'published' then now() end);
    if p_status = 'published' then
      update public.questions set current_version = 1 where env = p_env and id = v_id;
    end if;
    v_inserted := v_inserted + 1;
  end loop;

  perform private.write_audit(p_env, 'import', null, 'Importazione di ' || v_inserted || ' domande (' || p_status || ')',
    case when v_skipped > 0 then v_skipped || ' già presenti, saltate' end);
  return jsonb_build_object('ok', true, 'inserted', v_inserted, 'skipped', v_skipped);
end;
$$;

-- =========================================================
-- PERMESSI
-- =========================================================
revoke all on function private.req_role(public.role_t[])                                      from public, anon, authenticated;
revoke all on function private.write_audit(public.env_t, text, int, text, text)               from public, anon, authenticated;
revoke all on function private.validate_question_fields(public.env_t, text, text, text, text[], int, text, int, text, text, date, date)
                                                                                              from public, anon, authenticated;

revoke all on function public.create_question(public.env_t)                                   from public, anon;
revoke all on function public.update_draft(public.env_t, text, jsonb)                         from public, anon;
revoke all on function public.transition(public.env_t, text, text, text)                      from public, anon;
revoke all on function public.update_report(uuid, jsonb)                                      from public, anon;
revoke all on function public.decide_duplicate(public.env_t, text, text, text, text)          from public, anon;
revoke all on function public.import_questions(public.env_t, jsonb, text)                     from public, anon;

grant execute on function public.create_question(public.env_t)                                to authenticated;
grant execute on function public.update_draft(public.env_t, text, jsonb)                      to authenticated;
grant execute on function public.transition(public.env_t, text, text, text)                   to authenticated;
grant execute on function public.update_report(uuid, jsonb)                                   to authenticated;
grant execute on function public.decide_duplicate(public.env_t, text, text, text, text)       to authenticated;
grant execute on function public.import_questions(public.env_t, jsonb, text)                  to authenticated;
