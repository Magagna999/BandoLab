-- BandoLab — patch 04: Performance Advisor
-- 1) auth.uid() valutato una sola volta per query: (select auth.uid())
-- 2) niente policy "for all" che si sovrappongono alla policy di lettura

drop policy if exists own_profile on profiles_user;
create policy own_profile on profiles_user for select
  using (id = (select auth.uid()) or (select private.current_role_t()) = 'admin');

drop policy if exists own_prefs on user_prefs;
create policy own_prefs on user_prefs for all
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));

drop policy if exists own_sessions on quiz_sessions;
create policy own_sessions on quiz_sessions for select using (user_id = (select auth.uid()));

drop policy if exists own_attempts on attempts;
create policy own_attempts on attempts for select using (user_id = (select auth.uid()));

drop policy if exists own_items on attempt_items;
create policy own_items on attempt_items for select
  using (exists (select 1 from attempts a where a.id = attempt_id and a.user_id = (select auth.uid())));

drop policy if exists own_reading on reading_progress;
create policy own_reading on reading_progress for all
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));

drop policy if exists own_xp on xp_events;
create policy own_xp on xp_events for select using (user_id = (select auth.uid()));

drop policy if exists own_notif on notifications;
create policy own_notif on notifications for select using (user_id = (select auth.uid()));
drop policy if exists own_notif_upd on notifications;
create policy own_notif_upd on notifications for update
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));

drop policy if exists create_report on reports;
create policy create_report on reports for insert with check (reporter_id = (select auth.uid()));
drop policy if exists staff_reports on reports;
create policy staff_reports on reports for select
  using (reporter_id = (select auth.uid()) or (select private.current_role_t()) in ('reviewer', 'admin'));

drop policy if exists write_drafts on question_versions;
create policy write_drafts on question_versions for insert
  with check ((select private.current_role_t()) in ('editor', 'admin') and status = 'draft' and author_id = (select auth.uid()));

drop policy if exists own_path_progress on user_path_progress;
create policy own_path_progress on user_path_progress for all to authenticated
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));

drop policy if exists own_reviewed on reviewed_attempts;
create policy own_reviewed on reviewed_attempts for all to authenticated
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));

drop policy if exists own_interruptions on session_interruptions;
create policy own_interruptions on session_interruptions for select to authenticated
  using (exists (select 1 from quiz_sessions s where s.id = session_id and s.user_id = (select auth.uid())));

-- Tassonomia e impostazioni: scrittura admin separata per azione (la lettura resta unica)
drop policy if exists admin_areas on areas;
create policy admin_areas_ins on areas for insert to authenticated with check ((select private.current_role_t()) = 'admin');
create policy admin_areas_upd on areas for update to authenticated using ((select private.current_role_t()) = 'admin') with check ((select private.current_role_t()) = 'admin');
create policy admin_areas_del on areas for delete to authenticated using ((select private.current_role_t()) = 'admin');

drop policy if exists admin_entities on entities;
create policy admin_entities_ins on entities for insert to authenticated with check ((select private.current_role_t()) = 'admin');
create policy admin_entities_upd on entities for update to authenticated using ((select private.current_role_t()) = 'admin') with check ((select private.current_role_t()) = 'admin');
create policy admin_entities_del on entities for delete to authenticated using ((select private.current_role_t()) = 'admin');

drop policy if exists admin_subjects on subjects;
create policy admin_subjects_ins on subjects for insert to authenticated with check ((select private.current_role_t()) = 'admin');
create policy admin_subjects_upd on subjects for update to authenticated using ((select private.current_role_t()) = 'admin') with check ((select private.current_role_t()) = 'admin');
create policy admin_subjects_del on subjects for delete to authenticated using ((select private.current_role_t()) = 'admin');

drop policy if exists admin_topics on topics;
create policy admin_topics_ins on topics for insert to authenticated with check ((select private.current_role_t()) = 'admin');
create policy admin_topics_upd on topics for update to authenticated using ((select private.current_role_t()) = 'admin') with check ((select private.current_role_t()) = 'admin');
create policy admin_topics_del on topics for delete to authenticated using ((select private.current_role_t()) = 'admin');

drop policy if exists admin_profiles on professional_profiles;
create policy admin_profiles_ins on professional_profiles for insert to authenticated with check ((select private.current_role_t()) = 'admin');
create policy admin_profiles_upd on professional_profiles for update to authenticated using ((select private.current_role_t()) = 'admin') with check ((select private.current_role_t()) = 'admin');
create policy admin_profiles_del on professional_profiles for delete to authenticated using ((select private.current_role_t()) = 'admin');

drop policy if exists admin_settings on editorial_settings;
create policy admin_settings_ins on editorial_settings for insert to authenticated with check ((select private.current_role_t()) = 'admin');
create policy admin_settings_upd on editorial_settings for update to authenticated using ((select private.current_role_t()) = 'admin') with check ((select private.current_role_t()) = 'admin');
create policy admin_settings_del on editorial_settings for delete to authenticated using ((select private.current_role_t()) = 'admin');
