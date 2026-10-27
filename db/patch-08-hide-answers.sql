-- BandoLab — patch 08: le risposte corrette non sono più leggibili dal client
-- Da eseguire dopo patch-07.
--
-- STATO: APPLICATA al database il 27/10/2026, in due migrazioni (patch_08a: viste e permessi;
-- patch_08b: funzioni) con lo stesso SQL di questo file.
--
-- Problema: question_versions era leggibile da qualsiasi utente (anche anonimo) per le domande
-- pubblicate, comprese le colonne "correct" ed "explanation". Chiunque poteva leggere le soluzioni
-- di una simulazione prima di consegnare.
--
-- Soluzione:
--  1. le viste live_questions e due_reviews vengono ricreate senza le due colonne
--     (con security_invoker non potrebbero più funzionare per gli utenti, perché "select qv.*"
--     richiede il permesso su tutte le colonne);
--  2. il permesso di lettura su question_versions diventa per colonna, escludendo correct ed explanation;
--  3. tre funzioni restituiscono le soluzioni solo quando è lecito:
--       get_question_feedback        — allenamento, solo per le domande già "rivelate" nella sessione
--       get_attempt_review           — revisione di un proprio tentativo già consegnato
--       get_question_version_staff   — editor, revisori e amministratori (versione completa)
--
-- Nota per il client: "select *" su question_versions ora fallisce per gli utenti; elencare le colonne.

-- =========================================================
-- 1) VISTE SENZA RISPOSTE
-- =========================================================
drop view if exists public.due_reviews;
drop view if exists public.live_questions;

create view public.live_questions with (security_invoker = on) as
select qv.env, qv.question_id, qv.v, qv.status, qv.text, qv.options,
       qv.subject_id, qv.topic_id, qv.difficulty, qv.source, qv.source_url,
       qv.last_verified, qv.next_review, qv.author_id, qv.reviewer_id,
       qv.review_note, qv.change_note, qv.created_at, qv.approved_at, qv.published_at
from public.questions q
join public.question_versions qv
  on qv.env = q.env and qv.question_id = q.id and qv.v = q.current_version
where qv.status = 'published' and not q.suspended and q.merged_into is null;

create view public.due_reviews with (security_invoker = on) as
select env, question_id as id, 'question'::text as kind, next_review
from public.live_questions
where next_review <= current_date + 30
union all
select env, id, 'material'::text, next_review
from public.materials
where status = 'published' and next_review <= current_date + 30;

revoke all on public.live_questions, public.due_reviews from anon, authenticated;
grant select on public.live_questions, public.due_reviews to anon, authenticated;

-- =========================================================
-- 2) PERMESSI PER COLONNA
-- =========================================================
revoke select on public.question_versions from anon, authenticated;
grant select (env, question_id, v, status, text, options, subject_id, topic_id, difficulty,
              source, source_url, last_verified, next_review, author_id, reviewer_id,
              review_note, change_note, created_at, approved_at, published_at)
  on public.question_versions to anon, authenticated;

-- =========================================================
-- 3) FUNZIONI CHE RESTITUISCONO LE SOLUZIONI
-- =========================================================

-- Allenamento: soluzione e spiegazione di una domanda, solo dopo che il client l'ha segnata
-- come "rivelata" nella sessione (risposta data o richiesta di mostrare la soluzione).
-- Nelle simulazioni non è disponibile: si vede la revisione dopo la consegna.
create or replace function public.get_question_feedback(p_session_id uuid, p_qid text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid     uuid := auth.uid();
  v_sess    public.quiz_sessions%rowtype;
  v_ver     int;
  v_correct smallint;
  v_expl    text;
begin
  if v_uid is null then
    raise exception 'Accesso richiesto' using errcode = '28000';
  end if;

  select * into v_sess from public.quiz_sessions where id = p_session_id and user_id = v_uid;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'session_not_found');
  end if;
  if v_sess.mode <> 'training' then
    return jsonb_build_object('ok', false, 'error', 'not_available');
  end if;

  select (i.value ->> 'v')::int into v_ver
  from jsonb_array_elements(v_sess.items) i
  where i.value ->> 'qid' = p_qid
  limit 1;
  if v_ver is null then
    return jsonb_build_object('ok', false, 'error', 'question_not_in_session');
  end if;
  if coalesce(v_sess.revealed ->> p_qid, 'false') <> 'true' then
    return jsonb_build_object('ok', false, 'error', 'not_revealed');
  end if;

  select qv.correct, qv.explanation into v_correct, v_expl
  from public.question_versions qv
  where qv.env = v_sess.env and qv.question_id = p_qid and qv.v = v_ver;

  return jsonb_build_object('ok', true, 'qid', p_qid, 'v', v_ver,
                            'correct', v_correct, 'explanation', v_expl);
end;
$$;

-- Revisione di un proprio tentativo consegnato: domande, opzioni, risposta data, soluzione e
-- spiegazione, nella versione effettivamente usata (anche se oggi non è più quella pubblicata).
create or replace function public.get_attempt_review(p_attempt_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid   uuid := auth.uid();
  v_items jsonb;
begin
  if v_uid is null then
    raise exception 'Accesso richiesto' using errcode = '28000';
  end if;

  if not exists (select 1 from public.attempts a
                 where a.id = p_attempt_id and a.user_id = v_uid and a.status = 'completed') then
    return jsonb_build_object('ok', false, 'error', 'attempt_not_found');
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
           'pos', ai.position, 'qid', ai.question_id, 'v', ai.version,
           'answer', ai.answer, 'is_correct', ai.is_correct,
           'text', qv.text, 'options', qv.options,
           'correct', qv.correct, 'explanation', qv.explanation,
           'source', qv.source, 'source_url', qv.source_url,
           'subject_id', qv.subject_id, 'topic_id', qv.topic_id, 'difficulty', qv.difficulty)
         order by ai.position), '[]'::jsonb)
    into v_items
  from public.attempt_items ai
  join public.question_versions qv
    on qv.env = ai.env and qv.question_id = ai.question_id and qv.v = ai.version
  where ai.attempt_id = p_attempt_id;

  return jsonb_build_object('ok', true, 'attempt_id', p_attempt_id, 'items', v_items);
end;
$$;

-- Staff editoriale: versione completa di una domanda, comprese soluzione e spiegazione.
create or replace function public.get_question_version_staff(p_env public.env_t, p_qid text, p_v int)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid  uuid := auth.uid();
  v_role public.role_t;
  v_row  jsonb;
begin
  if v_uid is null then
    raise exception 'Accesso richiesto' using errcode = '28000';
  end if;
  v_role := private.current_role_t();
  if v_role is null or v_role not in ('editor', 'reviewer', 'admin') then
    raise exception 'Non autorizzato' using errcode = '42501';
  end if;

  select to_jsonb(qv) into v_row
  from public.question_versions qv
  where qv.env = p_env and qv.question_id = p_qid and qv.v = p_v;
  if v_row is null then
    return jsonb_build_object('ok', false, 'error', 'not_found');
  end if;
  return jsonb_build_object('ok', true, 'version', v_row);
end;
$$;

-- =========================================================
-- PERMESSI SULLE FUNZIONI
-- =========================================================
revoke all on function public.get_question_feedback(uuid, text)                      from public, anon;
revoke all on function public.get_attempt_review(uuid)                               from public, anon;
revoke all on function public.get_question_version_staff(public.env_t, text, int)    from public, anon;

grant execute on function public.get_question_feedback(uuid, text)                   to authenticated;
grant execute on function public.get_attempt_review(uuid)                            to authenticated;
grant execute on function public.get_question_version_staff(public.env_t, text, int) to authenticated;
