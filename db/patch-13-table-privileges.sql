-- BandoLab — patch 13: permessi di tabella ridotti al minimo
-- Da eseguire dopo patch-12.
--
-- Prima: anon e authenticated avevano tutti i privilegi su tutte le tabelle (anche TRUNCATE, che la RLS non ferma)
-- e le scritture dirette erano protette soltanto dalle policy.
-- Ora: dopo le patch 07–12 tutte le scritture passano dalle funzioni RPC (security definer, che girano con i diritti
-- del proprietario), quindi i client non hanno più bisogno di INSERT/UPDATE/DELETE sulle tabelle.
--
-- Regole:
--  1. si revoca tutto ad anon e authenticated e si riconcede soltanto il necessario;
--  2. authenticated legge (con le policy RLS che restano) e scrive solo: notifications.read_at, user_prefs,
--     editorial_settings (solo admin, per policy; non c'è ancora una RPC);
--  3. anon legge soltanto i contenuti pubblicati: quiz, materiali (senza autore, revisore, percorso del file) e domande
--     tramite la vista live_questions (senza risposte);
--  4. review_note e change_note delle domande non sono più leggibili con una select: lo staff le ottiene con
--     get_question_version_staff; le viste live_questions e due_reviews vengono ricreate senza queste colonne;
--  5. le tabelle future non ricevono più privilegi automatici (default privileges): ogni tabella nuova richiede
--     grant espliciti.
-- Le funzioni RPC, il ruolo service_role e il proprietario non sono toccati.
-- STATO: da applicare.

-- =========================================================
-- 1) VISTE: senza le note editoriali
-- =========================================================
drop view if exists public.due_reviews;
drop view if exists public.live_questions;

create view public.live_questions with (security_invoker = on) as
select qv.env, qv.question_id, qv.v, qv.status, qv.text, qv.options,
       qv.subject_id, qv.topic_id, qv.difficulty, qv.source, qv.source_url,
       qv.last_verified, qv.next_review, qv.author_id, qv.reviewer_id,
       qv.created_at, qv.approved_at, qv.published_at
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

-- =========================================================
-- 2) AZZERAMENTO (revoca anche i privilegi per colonna)
-- =========================================================
revoke all on all tables in schema public from anon, authenticated;

-- =========================================================
-- 3) AUTHENTICATED: sola lettura (le policy RLS restano in vigore)
-- =========================================================
grant select on
  public.areas, public.attempt_items, public.attempts, public.audit_log, public.duplicate_decisions,
  public.editorial_settings, public.entities, public.material_related, public.material_sections, public.materials,
  public.notifications, public.professional_profiles, public.profile_entities, public.profile_subjects,
  public.profiles_user, public.question_profiles, public.quiz_sessions, public.quizzes, public.reading_progress,
  public.reports, public.reviewed_attempts, public.session_interruptions, public.study_path_steps,
  public.study_paths, public.subjects, public.topics, public.user_path_progress, public.user_prefs,
  public.xp_events, public.live_questions, public.due_reviews
to authenticated;

-- domande: niente risposte, spiegazioni né note (correct, explanation, review_note, change_note)
grant select (env, question_id, v, status, text, options, subject_id, topic_id, difficulty, source, source_url,
              last_verified, next_review, author_id, reviewer_id, created_at, approved_at, published_at)
  on public.question_versions to authenticated;
-- questions: niente suspend_note
grant select (id, env, current_version, suspended, merged_into, created_at) on public.questions to authenticated;

-- =========================================================
-- 4) AUTHENTICATED: le uniche scritture dirette rimaste
-- =========================================================
grant update (read_at) on public.notifications to authenticated;                 -- segna come letta
grant insert, update on public.user_prefs to authenticated;                      -- preferenze (policy: solo le proprie)
grant insert, update, delete on public.editorial_settings to authenticated;      -- policy: solo admin

-- =========================================================
-- 5) ANON: solo contenuti pubblicati
-- =========================================================
grant select (id, env, title, mode, subject_ids, topic_ids, question_count, duration_min, status)
  on public.quizzes to anon;
grant select (id, env, title, subject_id, topic_id, format, status, minutes, source, key_concepts, last_verified, next_review)
  on public.materials to anon;
grant select (id, env, current_version, suspended, merged_into, created_at) on public.questions to anon;
grant select (env, question_id, v, status, text, options, subject_id, topic_id, difficulty, source, source_url,
              last_verified, next_review, author_id, reviewer_id, created_at, approved_at, published_at)
  on public.question_versions to anon;
grant select on public.live_questions, public.due_reviews to anon;

-- =========================================================
-- 6) TABELLE FUTURE: nessun privilegio automatico per i client
-- =========================================================
alter default privileges for role postgres in schema public revoke all on tables from anon, authenticated;
