-- BandoLab — patch 06: irrobustimento delle policy (revisione 27/10/2026)
-- Da eseguire dopo patch-05.

-- 1) Segnalazioni: chi segnala può creare solo una segnalazione "aperta", senza priorità né assegnatario.
--    Prima poteva inserirne una già "resolved" o con priorità/assegnatario a piacere.
drop policy if exists create_report on reports;
create policy create_report on reports for insert to authenticated
  with check (
    reporter_id = (select auth.uid())
    and status = 'open'
    and priority = 'media'
    and assignee_id is null
  );

-- La gestione resta a revisori e amministratori; valuta il ruolo una sola volta per query.
drop policy if exists handle_report on reports;
create policy handle_report on reports for update to authenticated
  using ((select private.current_role_t()) in ('reviewer', 'admin'))
  with check ((select private.current_role_t()) in ('reviewer', 'admin'));

-- 2) Notifiche: l'utente può solo segnarle come lette, non cambiarne titolo o testo.
revoke update on notifications from anon, authenticated;
grant  update (read_at) on notifications to authenticated;

-- 3) Domande: la nota di sospensione è riservata allo staff, quindi non è più leggibile dagli utenti.
--    Lo staff la leggerà tramite le RPC (da implementare). Le viste esistenti non la usano.
revoke select on questions from anon, authenticated;
grant  select (env, id, current_version, suspended, merged_into, created_at) on questions to anon, authenticated;
