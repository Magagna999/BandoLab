-- BandoLab — schema PostgreSQL (compatibile Supabase)
-- Versione 0.1 · derivato dai modelli di bandolab-core.js
-- Gli ID testuali stabili (es. 's-amm', 'q01') sono mantenuti per compatibilità con il prototipo.

create extension if not exists "pgcrypto";

-- =========================================================
-- ENUM
-- =========================================================
create type env_t            as enum ('demo', 'real');
create type role_t           as enum ('user', 'editor', 'reviewer', 'admin');
create type content_status_t as enum ('draft', 'review', 'changes', 'approved', 'published', 'rejected', 'superseded');
create type quiz_mode_t      as enum ('training', 'exam');
create type material_fmt_t   as enum ('scheda', 'pdf-view', 'pdf-download');
create type attempt_status_t as enum ('completed', 'abandoned');
create type attempt_reason_t as enum ('submitted', 'timeout', 'abandoned');
create type report_status_t  as enum ('open', 'resolved', 'dismissed');
create type priority_t       as enum ('alta', 'media', 'bassa');
create type notif_type_t     as enum ('goal', 'progress', 'content');

-- =========================================================
-- UTENTI E RUOLI
-- =========================================================
create table profiles_user (
  id            uuid primary key references auth.users(id) on delete cascade,
  display_name  text not null check (char_length(display_name) >= 2),
  email         text not null unique,
  role          role_t not null default 'user',
  theme         text not null default 'light' check (theme in ('light', 'dark')),
  created_at    timestamptz not null default now()
);

create table user_prefs (
  user_id        uuid not null references profiles_user(id) on delete cascade,
  env            env_t not null,
  onboarded      boolean not null default false,
  area_id        text,
  profile_ids    text[] not null default '{}',
  per_day        smallint check (per_day between 1 and 500),
  reference_date date,                                   -- data indicativa, non è una candidatura
  quiz_count     smallint not null default 10,
  difficulty     text not null default 'mix' check (difficulty in ('mix', '1', '2', '3')),
  explain        text not null default 'after' check (explain in ('after', 'end')),
  notif_goals    boolean not null default true,
  notif_progress boolean not null default true,
  notif_content  boolean not null default true,
  reduce_motion  boolean not null default false,
  primary key (user_id, env)
);

-- =========================================================
-- TASSONOMIA (per ambiente)
-- =========================================================
create table areas (
  id   text not null, env env_t not null, name text not null,
  primary key (env, id)
);
create table entities (
  id text not null, env env_t not null, name text not null, area_id text not null,
  primary key (env, id),
  foreign key (env, area_id) references areas(env, id)
);
create table subjects (
  id text not null, env env_t not null, name text not null,
  primary key (env, id)
);
create table topics (
  id text not null, env env_t not null, name text not null, subject_id text not null,
  primary key (env, id),
  foreign key (env, subject_id) references subjects(env, id)
);
create table professional_profiles (
  id text not null, env env_t not null, name text not null,
  primary key (env, id)
);
create table profile_entities (
  env env_t not null, profile_id text not null, entity_id text not null,
  primary key (env, profile_id, entity_id),
  foreign key (env, profile_id) references professional_profiles(env, id) on delete cascade,
  foreign key (env, entity_id)  references entities(env, id) on delete cascade
);
create table profile_subjects (
  env env_t not null, profile_id text not null, subject_id text not null,
  primary key (env, profile_id, subject_id),
  foreign key (env, profile_id) references professional_profiles(env, id) on delete cascade,
  foreign key (env, subject_id) references subjects(env, id) on delete cascade
);

-- =========================================================
-- BANCA DOMANDE CON VERSIONI
-- =========================================================
create table questions (
  id               text not null,
  env              env_t not null,
  current_version  int,                       -- versione pubblicata usata dai nuovi quiz
  suspended        boolean not null default false,
  suspend_note     text,
  merged_into      text,                      -- consolidamento duplicati (mai eliminazione)
  created_at       timestamptz not null default now(),
  primary key (env, id),
  check (not suspended or suspend_note is not null)
);

create table question_versions (
  env            env_t not null,
  question_id    text not null,
  v              int not null check (v >= 1),
  status         content_status_t not null default 'draft',
  text           text not null default '',
  options        text[] not null default array['', '', '', ''],
  correct        smallint check (correct between 0 and 3),
  explanation    text not null default '',
  subject_id     text,
  topic_id       text,
  difficulty     smallint check (difficulty between 1 and 3),   -- assegnata manualmente
  source         text not null default '',
  source_url     text,
  last_verified  date,
  next_review    date,
  author_id      uuid not null references profiles_user(id),
  reviewer_id    uuid references profiles_user(id),
  review_note    text,
  change_note    text,
  created_at     timestamptz not null default now(),
  approved_at    timestamptz,
  published_at   timestamptz,
  primary key (env, question_id, v),
  foreign key (env, question_id) references questions(env, id) on delete restrict,
  foreign key (env, subject_id)  references subjects(env, id),
  foreign key (env, topic_id)    references topics(env, id),
  check (array_length(options, 1) = 4),
  check (next_review is null or last_verified is null or next_review > last_verified),
  -- un editor non può approvare un proprio contenuto
  check (reviewer_id is null or reviewer_id <> author_id or status not in ('approved', 'published')),
  -- campi obbligatori per uscire dalla bozza
  check (status in ('draft', 'changes', 'rejected') or (
    char_length(text) >= 10 and correct is not null and subject_id is not null and topic_id is not null
    and difficulty is not null and char_length(source) > 0 and last_verified is not null and next_review is not null))
);

alter table questions
  add constraint questions_current_fk foreign key (env, id, current_version)
  references question_versions(env, question_id, v) deferrable initially deferred;

-- associazioni riutilizzabili (derivabili dalla tassonomia, ma sovrascrivibili)
create table question_profiles (
  env env_t not null, question_id text not null, profile_id text not null,
  primary key (env, question_id, profile_id),
  foreign key (env, question_id) references questions(env, id) on delete cascade,
  foreign key (env, profile_id)  references professional_profiles(env, id) on delete cascade
);

-- =========================================================
-- MATERIALI
-- =========================================================
create table materials (
  id            text not null,
  env           env_t not null,
  title         text not null,
  subject_id    text not null,
  topic_id      text not null,
  format        material_fmt_t not null,
  status        content_status_t not null default 'draft',
  minutes       smallint,
  source        text not null,
  file_path     text,                          -- storage per i PDF
  key_concepts  text[] not null default '{}',
  last_verified date,
  next_review   date,
  author_id     uuid not null references profiles_user(id),
  reviewer_id   uuid references profiles_user(id),
  created_at    timestamptz not null default now(),
  primary key (env, id),
  foreign key (env, subject_id) references subjects(env, id),
  foreign key (env, topic_id)   references topics(env, id),
  check (format = 'scheda' or status <> 'published' or file_path is not null)
);
create table material_sections (
  env env_t not null, material_id text not null, id text not null,
  position smallint not null, title text not null, body text not null,
  primary key (env, material_id, id),
  foreign key (env, material_id) references materials(env, id) on delete cascade
);
create table material_related (
  env env_t not null, material_id text not null, related_id text not null,
  primary key (env, material_id, related_id),
  foreign key (env, material_id) references materials(env, id) on delete cascade,
  foreign key (env, related_id)  references materials(env, id) on delete cascade
);

-- =========================================================
-- QUIZ PREDEFINITI E PERCORSI
-- =========================================================
create table quizzes (
  id            text not null,
  env           env_t not null,
  title         text not null,
  mode          quiz_mode_t not null,
  subject_ids   text[],
  topic_ids     text[],
  question_count smallint not null check (question_count > 0),
  duration_min  smallint check (duration_min > 0),
  status        content_status_t not null default 'draft',
  primary key (env, id),
  check (mode = 'training' or duration_min is not null)
);

create table study_paths (
  id text not null, env env_t not null, title text not null, description text,
  profile_id text, status content_status_t not null default 'draft',
  primary key (env, id)
);
create table study_path_steps (
  env env_t not null, path_id text not null, id text not null, position smallint not null,
  type text not null check (type in ('material', 'quiz', 'exam')),
  title text not null,
  material_id text, quiz_id text, subject_ids text[], topic_ids text[], question_count smallint,
  primary key (env, path_id, id),
  foreign key (env, path_id) references study_paths(env, id) on delete cascade
);
create table user_path_progress (
  user_id uuid not null references profiles_user(id) on delete cascade,
  env env_t not null, path_id text not null,
  step_order text[],
  step_status jsonb not null default '{}',   -- { stepId: 'done' | 'skipped' }
  updated_at timestamptz not null default now(),
  primary key (user_id, env, path_id)
);

-- =========================================================
-- SESSIONI E TENTATIVI
-- =========================================================
-- Sessione attiva: la scadenza è decisa dal server e non può essere estesa dal client.
create table quiz_sessions (
  id           uuid primary key default gen_random_uuid(),
  user_id      uuid not null references profiles_user(id) on delete cascade,
  env          env_t not null,
  mode         quiz_mode_t not null,
  title        text not null,
  quiz_key     text not null,
  items        jsonb not null,                -- [{ qid, v }] versioni fissate all'avvio
  answers      jsonb not null default '{}',
  revealed     jsonb not null default '{}',
  current_idx  smallint not null default 0,
  started_at   timestamptz not null default now(),
  deadline     timestamptz,                   -- solo simulazioni
  path_ref     jsonb,
  last_seen    timestamptz not null default now(),
  check (mode = 'training' or deadline is not null)
);
create unique index one_active_session_per_user on quiz_sessions(user_id, env);

create table session_interruptions (
  id bigserial primary key,
  session_id uuid not null references quiz_sessions(id) on delete cascade,
  at timestamptz not null default now(),
  type text not null
);

create table attempts (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid not null references profiles_user(id) on delete cascade,
  env           env_t not null,
  mode          quiz_mode_t not null,
  title         text not null,
  quiz_key      text not null,
  status        attempt_status_t not null,
  reason        attempt_reason_t not null,
  started_at    timestamptz not null,
  finished_at   timestamptz not null,
  duration_sec  int not null check (duration_sec >= 0),
  c int, e int, o int, n int,
  raw_score     numeric(8,2),
  score         numeric(6,4),                 -- valore non arrotondato
  passed        boolean,
  interruptions jsonb not null default '[]',
  path_ref      jsonb,
  check (status = 'abandoned' or (c + e + o = n))
);
create index attempts_user_idx on attempts(user_id, env, finished_at desc);

create table attempt_items (
  attempt_id   uuid not null references attempts(id) on delete cascade,
  position     smallint not null,
  env          env_t not null,
  question_id  text not null,
  version      int not null,                  -- versione effettivamente usata
  answer       smallint check (answer between 0 and 3),
  is_correct   boolean not null,
  primary key (attempt_id, position),
  foreign key (env, question_id, version) references question_versions(env, question_id, v)
);

-- =========================================================
-- STUDIO, GAMIFICATION, NOTIFICHE
-- =========================================================
create table reading_progress (
  user_id uuid not null references profiles_user(id) on delete cascade,
  env env_t not null, material_id text not null,
  sections_read text[] not null default '{}',
  bookmarks text[] not null default '{}',
  last_section text,
  completed_at timestamptz,                   -- solo dopo azione esplicita dell'utente
  updated_at timestamptz not null default now(),
  primary key (user_id, env, material_id)
);

create table xp_events (
  id bigserial primary key,
  user_id uuid not null references profiles_user(id) on delete cascade,
  env env_t not null,
  amount smallint not null check (amount >= 0),
  reason text not null,
  ref text,                                   -- es. attempt id
  at timestamptz not null default now()
);

create table reviewed_attempts (
  user_id uuid not null references profiles_user(id) on delete cascade,
  attempt_id uuid not null references attempts(id) on delete cascade,
  at timestamptz not null default now(),
  primary key (user_id, attempt_id)
);

create table notifications (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references profiles_user(id) on delete cascade,
  env env_t not null,
  type notif_type_t not null,
  title text not null,
  body text not null,
  read_at timestamptz,
  created_at timestamptz not null default now()
);

-- =========================================================
-- SEGNALAZIONI, DUPLICATI, AUDIT, IMPOSTAZIONI
-- =========================================================
create table reports (
  id uuid primary key default gen_random_uuid(),
  env env_t not null,
  question_id text not null,
  version int not null,
  reporter_id uuid references profiles_user(id) on delete set null,
  reason text not null,
  text text not null check (char_length(text) >= 10),
  status report_status_t not null default 'open',
  priority priority_t not null default 'media',
  assignee_id uuid references profiles_user(id),
  created_at timestamptz not null default now(),
  foreign key (env, question_id, version) references question_versions(env, question_id, v)
);

create table duplicate_decisions (
  env env_t not null, question_a text not null, question_b text not null,
  decision text not null check (decision in ('keep', 'merge')),
  actor_id uuid not null references profiles_user(id),
  note text, at timestamptz not null default now(),
  primary key (env, question_a, question_b)
);

-- log append-only: nessun UPDATE/DELETE consentito (vedi policy)
create table audit_log (
  id bigserial primary key,
  env env_t not null,
  at timestamptz not null default now(),
  actor_id uuid references profiles_user(id) on delete set null,
  target text not null,
  version int,
  action text not null,
  note text
);

create table editorial_settings (
  env env_t primary key,
  require_url boolean not null default true,
  require_explanation boolean not null default true,
  verify_months smallint not null default 12 check (verify_months between 1 and 60)
);

-- =========================================================
-- PUNTEGGIO — stessa regola di BL.computeScore
-- =========================================================
create or replace function compute_score(c int, e int, o int, n int)
returns table(raw numeric, score numeric, passed boolean)
language plpgsql immutable as $$
begin
  if c < 0 or e < 0 or o < 0 or n < 0 then raise exception 'Valori non validi'; end if;
  if c + e + o <> n then raise exception 'C + E + O deve essere uguale a N'; end if;
  if n = 0 then return query select 0::numeric, 0::numeric, false; return; end if;
  raw := c - 0.5 * e - 0.25 * o;
  score := greatest(0, least(30, 30 * raw / n));
  passed := score >= 21;                       -- soglia BandoLab, sul valore non arrotondato
  return next;
end $$;

-- =========================================================
-- VISTE DI SUPPORTO
-- =========================================================
create view live_questions as
select qv.*
from questions q
join question_versions qv on qv.env = q.env and qv.question_id = q.id and qv.v = q.current_version
where qv.status = 'published' and not q.suspended and q.merged_into is null;

create view due_reviews as
select env, question_id as id, 'question' as kind, next_review from live_questions
where next_review <= current_date + 30
union all
select env, id, 'material', next_review from materials
where status = 'published' and next_review <= current_date + 30;

-- =========================================================
-- RUOLI E RLS (Row Level Security)
-- =========================================================
create or replace function current_role_t() returns role_t
language sql stable security definer as $$
  select role from profiles_user where id = auth.uid()
$$;

alter table profiles_user        enable row level security;
alter table user_prefs           enable row level security;
alter table questions            enable row level security;
alter table question_versions    enable row level security;
alter table materials            enable row level security;
alter table quizzes              enable row level security;
alter table quiz_sessions        enable row level security;
alter table attempts             enable row level security;
alter table attempt_items        enable row level security;
alter table reading_progress     enable row level security;
alter table xp_events            enable row level security;
alter table notifications        enable row level security;
alter table reports              enable row level security;
alter table audit_log            enable row level security;

-- Dati personali: ogni utente vede solo i propri
create policy own_profile   on profiles_user    for select using (id = auth.uid() or current_role_t() = 'admin');
create policy own_prefs     on user_prefs       for all    using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy own_sessions  on quiz_sessions    for select using (user_id = auth.uid());
create policy own_attempts  on attempts         for select using (user_id = auth.uid());
create policy own_items     on attempt_items    for select using (exists (select 1 from attempts a where a.id = attempt_id and a.user_id = auth.uid()));
create policy own_reading   on reading_progress for all    using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy own_xp        on xp_events        for select using (user_id = auth.uid());
create policy own_notif     on notifications    for select using (user_id = auth.uid());
create policy own_notif_upd on notifications    for update using (user_id = auth.uid()) with check (user_id = auth.uid());

-- Contenuti: gli utenti leggono solo il pubblicato; lo staff legge tutto
create policy read_published_versions on question_versions for select
  using (status = 'published' or current_role_t() in ('editor', 'reviewer', 'admin'));
create policy read_questions on questions for select using (true);
create policy read_materials on materials for select
  using (status = 'published' or current_role_t() in ('editor', 'reviewer', 'admin'));
create policy read_quizzes on quizzes for select
  using (status = 'published' or current_role_t() in ('editor', 'reviewer', 'admin'));

-- Scrittura bozze: editor e admin, solo su versioni in bozza
create policy write_drafts on question_versions for insert
  with check (current_role_t() in ('editor', 'admin') and status = 'draft' and author_id = auth.uid());
create policy edit_drafts on question_versions for update
  using (status in ('draft', 'changes') and current_role_t() in ('editor', 'admin'));
-- Le transizioni (submit/approve/publish/suspend) passano da funzioni RPC security definer
-- che verificano ruolo, autore ≠ revisore e campi obbligatori, e scrivono in audit_log.

-- Segnalazioni: chiunque autenticato crea; staff gestisce
create policy create_report on reports for insert with check (reporter_id = auth.uid());
create policy staff_reports on reports for select using (reporter_id = auth.uid() or current_role_t() in ('reviewer', 'admin'));
create policy handle_report on reports for update using (current_role_t() in ('reviewer', 'admin'));

-- Audit: solo lettura per lo staff, solo inserimento tramite RPC
create policy read_audit on audit_log for select using (current_role_t() in ('editor', 'reviewer', 'admin'));
