-- BandoLab — patch 02: correzioni Security Advisor
-- Da eseguire dopo patch-01, in una nuova query.

-- Errori probabili: viste che ignorano le regole RLS di chi le interroga
alter view live_questions set (security_invoker = on);
alter view due_reviews    set (security_invoker = on);

-- Warning: funzioni senza search_path fisso
alter function compute_score(int, int, int, int) set search_path = public;
alter function current_role_t() set search_path = public;

-- Warning: la funzione del trigger non deve essere chiamabile dall'esterno
revoke execute on function handle_new_user() from public, anon, authenticated;

-- Warning: estensione nello schema public
create schema if not exists extensions;
alter extension pgcrypto set schema extensions;
