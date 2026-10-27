-- BandoLab — patch 09: un amministratore può essere autore e revisore dello stesso contenuto
-- Da eseguire dopo patch-08.
--
-- Prima: il vincolo question_versions_check1 vietava a chiunque di approvare/pubblicare una versione
-- di cui fosse l'autore (reviewer_id <> author_id).
-- Ora: il divieto resta per editor e revisori; vale l'eccezione solo se l'autore ha ruolo 'admin'.
-- Un vincolo CHECK non può leggere altre tabelle, quindi la regola passa a un trigger.
-- STATO: APPLICATA al database il 27/10/2026 (migrazione patch_09_admin_self_review), verificata con prova annullata.

alter table public.question_versions drop constraint if exists question_versions_check1;

create or replace function private.check_self_review() returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.reviewer_id is not null
     and new.reviewer_id = new.author_id
     and new.status in ('approved', 'published')
     and not exists (select 1 from public.profiles_user p where p.id = new.author_id and p.role = 'admin') then
    raise exception 'Solo un amministratore può approvare o pubblicare un contenuto di cui è autore'
      using errcode = '23514';
  end if;
  return new;
end;
$$;

revoke all on function private.check_self_review() from public, anon, authenticated;

drop trigger if exists question_versions_self_review on public.question_versions;
create trigger question_versions_self_review
  before insert or update on public.question_versions
  for each row execute function private.check_self_review();
