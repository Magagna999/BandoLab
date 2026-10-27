-- BandoLab — patch 03: sposta current_role_t in uno schema non esposto dall'API
-- Le policy RLS continuano a funzionare; la funzione non è più richiamabile da fuori.

create schema if not exists private;
grant usage on schema private to anon, authenticated;

alter function public.current_role_t() set schema private;

revoke execute on function private.current_role_t() from public;
grant  execute on function private.current_role_t() to anon, authenticated;
